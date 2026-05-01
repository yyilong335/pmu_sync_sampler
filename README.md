# pmu_sync_sampler

A Linux kernel module + small userspace tools that **synchronously sample
all configured PMU counters at a fixed cycle interval**.

> ⚠️ **Do not insert this module on a shared / production host.** See
> [Status & known issues](#status--known-issues) below — there is a
> latent NMI/spinlock deadlock that is much more likely to bite on
> modern many-core CPUs than it was on the original 2.6.32 / Nehalem
> target. Test inside a throwaway VM first (see [Testing safely](#testing-safely-vm-recommended)).

## Why this exists (vs. `perf`)

`perf record -e a,b,c,d` will round-robin events across the available
counters when there are more events than counters. Reported counts are
*not* synchronized across events — sample N for event A is from a
different RIP/cycle window than sample N for event B.

This driver guarantees that the values reported for `event0..N-1` in one
sample were read on the **same PMI overflow, on the same core, at the
same instant**. That correlation is what the rest of the pipeline
(sender → reader → splitter) relies on.

## How it works

```
                ┌──── /sys/sync_pmu/{period, status, 0..N-1, missed}  (sysfs)
   userspace ───┤
                └──── /dev/pmu_samples  (char device, blocking read)

   ──────────────────────────────────────────── kernel boundary ───
                                             ┌─ pmu_sync_sample_main.c ─┐
                                             │  • sysfs attrs           │
                                             │  • char device           │
   per-CPU buffer ←── full_buffers (linked list, spinlock)
       ▲                                     │  • per-CPU buffer mgmt   │
       │ append on overflow                  │  • status state machine  │
       │                                     └──────────────────────────┘
   ┌───┴───── intel.c ────────┐
   │ NMI handler (PMI):       │
   │   read FIXED_CTR1 (cyc), │
   │   read PMC0..N-1,        │
   │   read pid,              │
   │   reset & re-arm.        │
   └──────────────────────────┘
        ▲
        │ delivered as NMI via local APIC LVTPC = APIC_DM_NMI
        │
   ┌────┴───────── PMU hardware ─────────────┐
   │  FIXED_CTR1 preloaded to                │
   │     0xFFFFFFFFFFFF − period             │
   │  → overflows after `period` cycles      │
   │  → APIC raises PMI on this core         │
   └─────────────────────────────────────────┘
```

### Sampling pipeline (step by step)

1. **Configure**: userspace writes event codes to `/sys/sync_pmu/{0..N-1}`
   and a cycle period to `/sys/sync_pmu/period`, then
   `echo 1 > /sys/sync_pmu/status`.
2. **Arm**: `process_status_update()` calls `on_each_cpu(startCtrs, …)`,
   which on every logical CPU:
   - preloads `MSR_ARCH_PERFMON_FIXED_CTR1` to `0xFFFFFFFFFFFF − period`
     (so it overflows after `period` cycles),
   - writes the per-counter event selectors `MSR_ARCH_PERFMON_EVENTSEL0..N-1`
     with USR | OS | EN bits set,
   - sets `MSR_CORE_PERF_GLOBAL_CTRL` to enable PMC0..N-1 + FIXED_CTR1,
   - programs the local APIC's `LVTPC` to NMI delivery
     (`APIC_DM_NMI`) so the PMI arrives as an NMI.
3. **Overflow → NMI**: after `period` cycles, FIXED_CTR1 overflows, the
   local APIC raises an NMI on the same core, and the NMI handler
   registered via `register_nmi_handler(NMI_LOCAL, …)` runs.
4. **Sample**: handler reads cycles + every PMC + `current->pid`,
   appends a `struct sample` to the per-CPU `struct buffer`, then
   resets & re-arms the counters and unmasks LVTPC for the next PMI.
5. **Hand-off**: when a per-CPU buffer fills (~100 samples), it moves
   from `empty_buffers` to `full_buffers` (spinlock-protected linked
   lists) and `wake_up_all(&read_queue)` wakes any blocked reader.
6. **Drain**: `read(/dev/pmu_samples, buf, BUFFER_SIZE)` blocks on
   `wait_event_interruptible(read_queue, …)`, copies one full buffer
   to userspace (`copy_to_user`), and returns the buffer to
   `empty_buffers`. `/sys/sync_pmu/missed` increments when a PMI
   landed and there was no empty buffer to write into.

### Terminology

| Term | What it is |
|---|---|
| **NMI** (Non-Maskable Interrupt) | x86 vector 2; can't be masked by clearing EFLAGS.IF. Used here for PMI delivery, watchdogs, hardware-error notifications. |
| **PMI** (Performance Monitoring Interrupt) | The interrupt the PMU raises on counter overflow. Not its own delivery mechanism — it travels through whatever the local APIC's `LVTPC` register is programmed to. This driver programs `LVTPC = APIC_DM_NMI`, so **here PMI = an NMI**. |
| **IPI** (Inter-Processor Interrupt) | One core poking another. Used here only by `on_each_cpu(...)` to fan the start/stop calls across every logical CPU. Unrelated to PMI delivery. |

## sysfs interface

`/sys/sync_pmu/` is created by this module in `init_sysfs_entries()`;
it only exists while the module is loaded.

| File | RW | Meaning |
|---|---|---|
| `period` | RW | Cycles between PMIs. Minimum 10,000. |
| `status` | RW | `0` = stop, `1` = start sampling, `2` = print MSR dump to dmesg. |
| `missed` | RW | Count of PMIs that landed when no empty buffer was available. |
| `0..N-1` | RW | Per-counter event selector. Format: `(umask << 8) \| event` (decimal or `0x…`). |

Currently `N = 4` (PMC0..PMC3 + FIXED_CTR1). The pending Subtask 3
expands this to all 8 GP counters + 3 fixed counters available on this
host (Skylake-SP with SMT off).

## Build & run

### Kernel module

Requires kernel headers for the running kernel
(`/lib/modules/$(uname -r)/build` must exist).

```bash
cd module && make            # produces pmu_sync_sample.ko
sudo insmod pmu_sync_sample.ko
ls /sys/sync_pmu/            # → 0 1 2 3 missed period status
ls -l /dev/pmu_samples       # currently NOT auto-created (Subtask 2 will fix)
sudo rmmod pmu_sync_sample
```

Until [Subtask 2](#status--known-issues) is done the char device uses a
hard-coded major (222) and udev does not create the node. To work around
that you must `mknod /dev/pmu_samples c 222 0` after `insmod`.

### Userspace

```bash
make textreader              # local CSV viewer
cd sender && make            # ships samples over TCP (see sender/protocol.txt)
cd reader && make            # parses the wire format into per-PID CSVs
```

Userspace builds with g++ ≥ 4.6 and Boost ≥ 1.46 (range-for + Boost.Foreach).

## Status & known issues

This repository was last known to build cleanly on **Linux 2.6.32 /
Intel Xeon 5550 (Nehalem)**. It is being incrementally upgraded for
**Linux 5.15 LTS / Intel Xeon Gold 6142 (Skylake-SP, SMT off,
8 GP + 3 fixed counters)**. The full plan lives at
`~/.claude/plans/this-is-an-old-glistening-walrus.md`.

### Done so far

- **Build cleanly on 5.15** (verified — `make` produces `.ko` with no warnings).
- **Dropped the ARM/OMAP4 port** (depended on dead `mach-omap2` headers).
- **`module/Makefile.intel` → `module/Makefile`**, dropped the
  `obj-$(CONFIG_X86)` switch (Intel-only now).
- **`intel.c` — replaced the deprecated NMI hook**:
  `register_die_notifier(...)` → `register_nmi_handler(NMI_LOCAL,
  my_nmi_handler, 0, "sync-pmu")`. Handler signature changed to
  `int(unsigned int, struct pt_regs *)` returning `NMI_HANDLED`.
  Dropped `<linux/kdebug.h>`, `<linux/kprobes.h>`. Added extern
  declarations for `reserve_perfctr_nmi` / `reserve_evntsel_nmi` /
  `release_*` (still `EXPORT_SYMBOL`'d on 5.15 but not in any
  installed header).
- **`pmu_sync_sample_main.c`**:
  - `<asm/uaccess.h>` → `<linux/uaccess.h>` (asm path gone since 4.12).
  - `file_operations`: GCC colon-init syntax → C99 designated init,
    added `.owner = THIS_MODULE`.
  - `kobj_type.default_attrs` (deprecated, removed in 6.2+) →
    `default_groups` via `ATTRIBUTE_GROUPS()`.
  - `init_module` / `cleanup_module` → named
    `static int __init pmu_init(void)` /
    `static void __exit pmu_exit(void)` + `module_init` / `module_exit`.

### Not yet done

- **Subtask 2** — switch the char device from `register_chrdev(222, …)`
  to `alloc_chrdev_region` + `cdev_init` + `class_create` +
  `device_create`, so udev creates `/dev/pmu_samples` automatically.
- **Subtask 3** — sample all 11 counters per PMI (8 GP + 3 fixed)
  instead of the current 4 GP + 1 fixed. `MSR_CORE_PERF_GLOBAL_CTRL`
  becomes `0xFF | (7ULL << 32)`, `MSR_CORE_PERF_FIXED_CTR_CTRL`
  becomes `0x3B3` (FIXED1 gets PMI, FIXED0/2 get OS|USR only),
  `struct sample` grows to `gp[8] + fixed[3]`, and `textreader.cpp`
  prints them all.
- **Subtask 4** — paper-style verification at `period = 50000` cycles,
  cross-checking GP[0]≈FIXED[0], GP[1]≈FIXED[1], GP[2]≈FIXED[2].

### ⚠️ Known crash risk — do not load on shared infrastructure

Two design issues from the original code that hurt much more on
modern many-core CPUs:

1. **NMI handler takes a regular `spinlock_t`.** `gatherSample()` runs
   in NMI context but calls `pop_blist()` / `append_blist()`, both of
   which use `spin_lock_irqsave`. NMIs **cannot** be masked by `irqsave`,
   so an NMI can preempt a CPU that's holding the list lock from the
   read path → handler then spins forever waiting for a lock only the
   preempted thread can release → **CPU hard-locks**. With 14 cores
   firing PMIs every ~50 000 cycles (~19 µs) the contention window is
   no longer rare. This needs a redesign (per-CPU lockless rings, or
   moving the buffer hand-off out of NMI context with `irq_work`)
   before the module is safe to enable on a real machine.
2. **`stopAll()` clobbers global PMU state on every CPU at `rmmod`
   time** — it writes `MSR_CORE_PERF_GLOBAL_CTRL = 0` and masks
   `LVTPC` everywhere, even on CPUs we never touched. Anything else
   using the PMU (the kernel's own `perf_events`, monitoring agents,
   `perf top` from another user) loses its counters and PMI delivery
   silently. Should be scoped to only counters we actually own.

Until those are fixed, `insmod` of this module on a shared host can
cascade into a hung box that may need a power-cycle.

## Testing safely (VM recommended)

The easiest reliable way is a KVM guest using your host's CPU model
(so the architectural PMU is exposed). Crash the guest, host stays up.

```bash
# One-time install
sudo apt install qemu-kvm libvirt-daemon-system virtinst \
                 cloud-image-utils virt-manager

# Boot a throwaway Ubuntu 22.04 guest with PMU passthrough
virt-install \
  --name pmu-test --memory 4096 --vcpus 4 \
  --cpu host-passthrough,topology.sockets=1,topology.cores=4,topology.threads=1 \
  --disk size=10 --os-variant ubuntu22.04 \
  --location 'http://archive.ubuntu.com/ubuntu/dists/jammy/main/installer-amd64/' \
  --network user

# Inside the guest:
sudo apt install build-essential linux-headers-$(uname -r) git
git clone <this repo>
cd pmu_sync_sampler/module && make
sudo insmod pmu_sync_sample.ko
# … run tests; if guest hangs:  virsh destroy pmu-test (from host)
```

Notes / caveats:
- KVM exposes architectural perfmon to the guest (`-cpu host` →
  vPMU on). You generally get fewer GP counters in the guest than on
  bare metal, and a few non-architectural events may be missing, but
  the NMI/PMI delivery path is intact, which is exactly what the
  unsafe code paths above exercise.
- Containers (Docker, LXC) **do not** isolate kernel modules — the
  module would load on the host kernel. Don't use them for this.
- The NMI/spinlock deadlock may be timing-sensitive enough that it
  reproduces less reliably under KVM than on bare metal. Use the VM
  to validate cleanliness (`insmod` / `rmmod` round-trip without
  enabling sampling, then enabling sampling at long periods first),
  and only move to bare metal when those are solid.

## Repository layout

```
module/
  pmu_sync_sample_main.c   generic char-dev / sysfs / buffer pipeline
  intel.c                  Intel-specific MSR + NMI handler
  pmu_api.h                arch-abstraction header
  sample_buffer.h          shared kernel↔userspace ABI for samples
  Makefile                 builds against /lib/modules/$(uname -r)/build
sender/                    TCP shipper (see sender/protocol.txt for wire format)
reader/                    parser; splits the stream into per-PID CSVs
textreader.cpp             local CSV viewer that reads /dev/pmu_samples directly
example_run.sh             one-shot driver script (currently still references major 222)
stop.sh                    `echo 0 > /sys/sync_pmu/status`
```

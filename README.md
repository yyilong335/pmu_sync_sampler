# pmu_sync_sampler

A Linux kernel module + small userspace tools that **synchronously sample
all configured PMU counters at a fixed cycle interval**. The current
target is **Linux 5.15 / Intel Xeon Gold 6142 (Skylake-SP, SMT off, 8 GP
+ 3 fixed counters)**, sampling on **CPU 3 only**, with `period =
50,000` cycles between PMIs.

> **Read this first if you're a new Claude / new contributor**:
> [`CLAUDE.md`](CLAUDE.md) has the project's behavioral guidelines and
> a "project context" section that summarizes hardware target, branch,
> file map, and what's done.

## Why this exists (vs. `perf`)

`perf record -e a,b,c,d` round-robins events across counters when
there are more events than counters; reported counts are *not*
synchronized — sample N for event A is from a different RIP/cycle
window than sample N for event B.

This driver guarantees that the values reported for every event in one
sample were read **on the same PMI overflow, on the same core, at the
same instant**. That's the property the rest of the toolchain depends
on.

## Quick start

Run on a target machine (bastion bare metal, or a KVM guest with
`--cpu host-passthrough` for safety):

```bash
# 1. (optional, recommended) Pin frequency, disable turbo/watchdog/ASLR.
sudo ./prepare_for_benchmarking.sh

# 2. Build the module.
cd module && make           # produces pmu_sync_sample.ko
cd ..

# 3. Build userspace.
make textreader             # the local CSV viewer
gcc -O2 -Wall -o microbench_mem microbench_mem.c   # memory-bound demo workload

# 4. Arm the sampler with the events listed in events.conf, period=50,000.
sudo ./start_sampler.sh 50000

# 5. Run a workload on CPU 3 and drain samples concurrently.
sudo ./textreader > /tmp/samples.csv &
taskset -c 3 ./microbench_mem 10 1
sudo bash -c "echo 0 > /sys/sync_pmu/status"
sudo rmmod pmu_sync_sample

# 6. Inspect.
head /tmp/samples.csv
cat /sys/sync_pmu/missed     # 0 if reader kept up
```

## Status

| Subtask | What | Status |
|---|---|---|
| 1 | Modernize for Linux 5.15 (NMI API, sysfs, `module_init`) | ✓ done |
| 2 | udev-managed `/dev/pmu_samples` (kernel-allocated major) | ✓ done |
| 3 | Sample 8 GP + 3 fixed counters per PMI on CPU 3 | ✓ done |
| 4 | Paper-style verification at `period = 50,000` | ✓ done (in VM) |
| 0 | Fix latent NMI/spinlock deadlock via `irq_work` (was the bug that hard-locked the original host) | ✓ done |
| — | x2APIC `LVTPC` programming via `apic_write` (was a latent xAPIC-only assumption) | ✓ done |
| — | Reset PERFCTR / FIXED_CTR0 / FIXED_CTR2 in `startCtrsLocal` (first-sample contamination) | ✓ done |
| — | Configurable GP event set via `events.conf` + `start_sampler.sh` | ✓ done |

Active branch: **`kernel-5.15`**. The `master` branch carries Subtasks 0/1/2
+ pre-existing work but not Subtasks 3/4 / events.conf / fixed-counter
sampling. **Don't push to master without explicit approval.**

### Known issues, not blocking bare-metal validation

- **`stopAll()` clobbers global PMU state on every CPU at `rmmod`**:
  writes `MSR_CORE_PERF_GLOBAL_CTRL = 0` and masks `LVTPC` on every
  CPU. Anything else using the PMU loses its counters. Should be
  scoped to only the counters and CPU we own, but doesn't crash
  anything. Defer.
- **Latent `lbuffer == NULL` recovery hole**: if a reader stalls long
  enough to drain the 8-buffer pool (~10 ms at period=50K), `gatherSample`
  on `b == NULL` only bumps `missed` and doesn't queue
  `irq_work` — buffers freed back into the pool by a later read can't
  get picked up. Tight readers (`textreader`, `sender`) never trigger
  this. One-line fix available; left out of this branch.
- **`sender/`, `reader/` wire format still encodes 6 counters** and
  will silently truncate the 8 GP + 3 fixed sample. `textreader` is the
  reference reader for now; fix `sender/protocol.txt` if you bring TCP
  shipping back online.

## Documentation map

For the deep details:

- **[`CLAUDE.md`](CLAUDE.md)** — behavioral guidelines + project
  context. Read this before doing anything else with the codebase.
- **[`SAMPLING_WORKFLOW.md`](SAMPLING_WORKFLOW.md)** — what happens
  on each PMI: where things run, what `cyc` / `CPU_CLK_CORE` /
  `REF_TSC` measure, why no counter equals `period` exactly.
- **[`VM_TESTING.md`](VM_TESTING.md)** — long-form: how to provision
  a KVM test guest, full test harness, per-subtask verification
  results, tables of stable-counter behavior, recovery procedures,
  Alder Lake addendum.
- **[`event.md`](event.md)** — the event encodings table from the
  user's notes (the source for `events.conf`).

## How it works

```
                ┌──── /sys/sync_pmu/{period, status, 0..7, missed}  (sysfs)
   userspace ───┤
                └──── /dev/pmu_samples  (char device, blocking read)

   ──────────────────────────────────────────── kernel boundary ───
                                             ┌─ pmu_sync_sample_main.c ─┐
                                             │  • sysfs attrs           │
                                             │  • char device           │
   per-CPU buffer ←── full_buffers (linked list, spinlock)
       ▲                                     │  • per-CPU buffer mgmt   │
       │ NMI fills, irq_work hands off       │  • status state machine  │
       │                                     └──────────────────────────┘
   ┌───┴───── intel.c ──────────────┐
   │ NMI handler (PMI):             │
   │   read FIXED_CTR1 (cyc),       │
   │   read PMC0..7,                │
   │   read FIXED_CTR0..2,          │
   │   reset all & re-arm LVTPC.    │
   └────────────────────────────────┘
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

### Sampling pipeline

1. Userspace writes 8 event encodings to `/sys/sync_pmu/0..7`,
   `period` to `/sys/sync_pmu/period`, then `1` to `/sys/sync_pmu/status`.
2. `process_status_update()` calls `smp_call_function_single(CPU=3,
   startCtrs, …)`. `startCtrs` preloads `MSR_ARCH_PERFMON_FIXED_CTR1`
   to overflow-after-period, programs the 8 EVENTSEL MSRs, sets
   `FIXED_CTR_CTRL = 0x3B3` (FIXED1 raises PMI; FIXED0/2 count without
   PMI), enables `GLOBAL_CTRL = 0xFF | (7ULL<<32)`, programs `LVTPC =
   APIC_DM_NMI` via `apic_write`.
3. After `period` cycles, FIXED_CTR1 overflows → APIC raises PMI on
   CPU 3 → NMI handler runs.
4. NMI handler reads cycles + 8 GP + 3 fixed + `current->pid` into the
   per-CPU `lbuffer`. When the buffer fills it stashes it in
   `pending_full`, NULLs `lbuffer`, and queues `irq_work`.
5. `irq_work` callback runs in regular IRQ context, takes the
   `blist.lock` safely, moves the full buffer to `full_buffers`,
   refills `lbuffer` from `empty_buffers`, wakes any reader.
6. `read(/dev/pmu_samples, buf, 4096)` blocks on `wait_event_interruptible`,
   copies one full buffer, returns it to `empty_buffers`. `/sys/sync_pmu/missed`
   counts NMIs that found `lbuffer == NULL`.

### Terminology

| Term | What it is |
|---|---|
| **NMI** | Non-Maskable Interrupt; x86 vector 2; can't be masked by clearing EFLAGS.IF. |
| **PMI** | Performance Monitoring Interrupt; the PMU's overflow signal. Travels through whatever the local APIC's `LVTPC` register is programmed to. We program `LVTPC = APIC_DM_NMI`, so **here PMI = NMI**. |
| **IPI** | Inter-Processor Interrupt. Used here only by `smp_call_function_single` for arm/disarm dispatch. Unrelated to PMI. |

## sysfs interface

`/sys/sync_pmu/` is created on `insmod`, removed on `rmmod`.

| File | RW | Meaning |
|---|---|---|
| `period` | RW | Cycles between PMIs. Minimum 10,000. Always 50,000 in production. |
| `status` | RW | `0` = stop, `1` = start sampling, `2` = print MSR dump to dmesg. |
| `missed` | RW | Count of PMIs that landed when no buffer was available. |
| `0..7` | RW | Per-counter eventsel low 32 bits. Format: `event \| (umask<<8) \| (invert<<23) \| (cmask<<24)`. USR/OS/EN forced by the driver, INT cleared. Decimal or `0x…`. |

## Repository layout

```
README.md, CLAUDE.md, SAMPLING_WORKFLOW.md, VM_TESTING.md, event.md  ─ docs
events.conf                        ─ GP event set (read by start_sampler.sh)
start_sampler.sh                   ─ insmod, set period, write events, status=1
example_run.sh, stop.sh            ─ legacy run scripts (master-era; not on hot path)
prepare_for_benchmarking.sh        ─ pin freq, disable turbo/watchdog/ASLR
microbench.c                       ─ ALU-bound workload pinned to CPU 3
microbench_mem.c                   ─ memory-bound workload (16 MB pointer chase) pinned to CPU 3
textreader.cpp                     ─ reads /dev/pmu_samples, prints CSV (or replays from file via argv[1])
exercise1.cpp, hello.cpp           ─ legacy test programs from the original repo
module/
  pmu_sync_sample_main.c           ─ char-dev / sysfs / buffer pipeline / irq_work
  intel.c                          ─ Intel-specific MSR + NMI handler
  pmu_api.h                        ─ arch-abstraction header (PMU_TARGET_CPU=3 here)
  sample_buffer.h                  ─ kernel↔userspace ABI for samples (60 bytes packed)
  Makefile                         ─ builds against /lib/modules/$(uname -r)/build
sender/                            ─ TCP shipper (legacy; wire format predates 8+3)
reader/                            ─ TCP parser (legacy; mirror of sender)
```

## Hardware portability

The current code assumes:

- **Intel architectural PMU v3+** (Skylake-SP and onward; the 8 GP +
  3 fixed counter assumption needs a CPUID 0xA check on other CPUs).
- **x2APIC mode** — handled (`apic_write` dispatches via `apic->write`,
  works in both xAPIC and x2APIC).
- **Linux 5.15** — `class_create(THIS_MODULE, …)` signature; on 6.4+
  the `THIS_MODULE` argument was removed.
- `PMU_TARGET_CPU = 3` ([`module/pmu_api.h`](module/pmu_api.h)) — the
  one place to change for a different target core.

For Alder Lake (hybrid P/E) testing notes, see VM_TESTING.md
"Appendix: testing on Ubuntu 24.04 / kernel 6.x / Alder Lake".

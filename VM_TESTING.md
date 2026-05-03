# pmu_sync_sampler — kernel-5.15 modernization plan

## What we're building

The original module (last touched on Linux 2.6.32 / Nehalem) samples Intel PMU
counters synchronously — every PMI reads the same counters at the same instant
on the same core. The goal is to bring it back to life on Linux 5.15 / Xeon
Gold 6142 (Skylake-SP, SMT off) and reach the paper's verification target:
**11 counters (8 GP + 3 fixed) sampled every 50,000 cycles on a single
production core (CPU 3)**, while a `taskset -c 3 ./prog` workload runs on it.

All kernel work happens inside a throwaway KVM guest with full PMU
passthrough. A deadlock in the module hangs only the guest, recoverable in
seconds via `virsh snapshot-revert`. This document is the live status of
that work — read top-to-bottom for the big picture, jump to a specific
subtask section for details.

## Subtasks at a glance

| # | Subtask | Status | Commit |
|---|---|---|---|
| 1 | Build & load on Linux 5.15 (kernel-API modernization) | ✓ done | [`39deb74`](../../commit/39deb74) |
| 2 | udev-managed `/dev/pmu_samples` (drop hardcoded major 222) | ✓ done | [`7a59465`](../../commit/7a59465) |
| — | x2APIC fix: `apic_write` for LVTPC programming *(pre-existing bug)* | ✓ done | [`e33ca6d`](../../commit/e33ca6d) |
| 0 | NMI/spinlock deadlock fix via `irq_work`, scoped to CPU 3 | ✓ done | [`c2eb4b6`](../../commit/c2eb4b6) → [`e965a5b`](../../commit/e965a5b) |
| 3 | Expand to 8 GP + 3 fixed counters (CPU 3 only) | ✓ done | — |
| 4 | Paper-style verification at period=50,000 (CPU 3 only) | ✓ done | — |

Numbering follows the README's original plan; **Subtask 0** is the
NMI/spinlock fix the README flagged as a prerequisite but did not design.
The order of execution is 2 → 0 → 3 → 4 (deliberately
risk-ascending — Subtask 2 doesn't enable sampling, Subtask 0 makes
sampling safe to enable, Subtasks 3/4 expand and validate it).

## Where to test, which version to use

- **Repository branch:** `kernel-5.15`. Latest commit `e965a5b` (or
  whichever is the head when you `git fetch`).
- **Guest VM:** Ubuntu 22.04 cloud image, 4 vCPU, 4 GB RAM,
  `--cpu host-passthrough`. The guest sees the host's full architectural
  PMU (8 GP + 3 fixed, 48-bit) — same as bare-metal bastion.
- **Sync workflow:** edit on bastion, commit, push to
  `origin/kernel-5.15`, `git pull` on the guest. The guest is a real
  `git clone` of `kernel-5.15` (no more `scp`-driven drift).
- **What to run for a smoke test:**
  ```bash
  cd ~/pmu_sync_sampler/module && make
  sudo insmod pmu_sync_sample.ko
  ls /sys/sync_pmu/                         # 0..3 missed period status
  ls -l /dev/pmu_samples                    # major != 222
  sudo rmmod pmu_sync_sample
  ```
  Then for sampling: see "Test harness" below.

### GP event selection — `events.conf`

The 8 GP counters are programmed from [`events.conf`](events.conf), one
non-comment line per slot, format `<NAME> <EVENTSEL_LOW32>`. The
encoding is the low 32 bits of `MSR_PERFEVTSEL` — i.e. `event(0..7) |
umask(8..15) | edge(18) | anythread(21) | invert(23) | cmask(24..31)`.
USR/OS/EN are forced by the driver and `INT` is forced off (only
FIXED1 raises PMI). Slots beyond the last entry are zeroed (counter
is enabled but `EVENT=0` is "no event"). The 3 fixed counters are
always-on (INST_RETIRED.ANY, CPU_CLK_UNHALTED.CORE,
CPU_CLK_UNHALTED.REF_TSC) and not user-configurable.

Current set (Skylake-SP, from [`event.md`](event.md)):

| Slot | Name | Encoding | Event |
|---|---|---|---|
| 0 | STALL_ISSUE     | 0x0180010E | UOPS_ISSUED.STALL_CYCLES (cmask=1, invert=1) |
| 1 | STALL_RETIRE    | 0x018002C2 | UOPS_RETIRED.STALL_CYCLES (cmask=1, invert=1) |
| 2 | LOAD            | 0x81D0     | MEM_INST_RETIRED.ALL_LOADS |
| 3 | STORE           | 0x82D0     | MEM_INST_RETIRED.ALL_STORES |
| 4 | BRANCH          | 0x00C4     | BR_INST_RETIRED.ALL_BRANCHES |
| 5 | L1D_REPLACEMENT | 0x0151     | L1D.REPLACEMENT |
| 6 | L1I_MISS        | 0x0283     | ICACHE_64B.IFTAG_MISS |
| 7 | LLC_REFERENCE   | 0x4F2E     | LONGEST_LAT_CACHE.REFERENCE |

CMask + Invert are required for the stall events; the driver's
`pmn_config` macro now passes through bits 0..15 (event+umask),
18 (edge), 19 (pin), 21 (anythread), 23 (invert), 24..31 (cmask),
and forces USR/OS/EN.

Edit `events.conf` to change the set; [`start_sampler.sh`](start_sampler.sh)
loads the module, sets `period`, writes each slot, and starts sampling.

### Load + Store vs LLC_REFERENCE on a memory-bound workload

[`microbench_mem.c`](microbench_mem.c) builds a 16 MB pointer-chase
chain (256 K nodes, Fisher–Yates shuffled, 1 cache line per node) so
each step touches a fresh line — > L2 (1 MB), < LLC (22 MB). At
period=100,000 cycles, with the first 1024 samples (init + shuffle
phase) trimmed:

| Mode | LOAD | STORE | LLC_REF | (L+S)/LLC | LOAD/LLC |
|---|---|---|---|---|---|
| `do_stores=1` (load + store same line) | 1,270 | 1,151 | 996 | **2.43** | 1.27 |
| `do_stores=0` (load only) | 1,241 | 228 | 959 | **1.53** | 1.29 |

**Load + Store does not equal LLC_REFERENCE** for either mode. The
ratio in the mixed mode (~2.4) is the expected behavior: a pointer
chase to a cold line generates one demand fetch (1 LLC reference),
the line is now hot in L1, so the immediately-following store to the
same line hits L1 and produces 0 additional LLC refs. Net per
iteration: 1 load + 1 store = 1 LLC ref → ratio 2:1.

For `do_stores=0`, only the loads remain. `LOAD/LLC ≈ 1.29` says
~77 % of retired loads go all the way to LLC; the remaining ~23 % are
absorbed somewhere — most plausibly Skylake-SP's L2 spatial / HW
prefetcher learning the fixed permutation after a few cycles. Loop
overhead loads (stack/return) are negligible at -O2 with `register`
declarations.

The cleanest "Load + Store = LLC_REFERENCE" pattern would require a
workload where every memory instruction hits a *different* cold line
— e.g. streaming reads at stride > line through a buffer > L2 with
HW prefetchers disabled. The pointer chase as written conflates each
load with its own paired store, which doubles the ratio.

Stalls in this workload are extreme as expected:
`STALL_ISSUE/cyc ≈ 0.96`, `STALL_RETIRE/cyc ≈ 0.95` — pointer-chase is
~95 % stall-bound on KVM-passthrough Skylake.

---

## Subtask details

### Subtask 1 — kernel-API modernization (done)

Replaced 2.6.32-era APIs that were deprecated or removed by 5.15:
`register_die_notifier` → `register_nmi_handler(NMI_LOCAL, …)`,
`<asm/uaccess.h>` → `<linux/uaccess.h>`, `kobj_type.default_attrs` →
`default_groups` via `ATTRIBUTE_GROUPS()`, named
`pmu_init`/`pmu_exit` + `module_init`/`module_exit`. The ARM/OMAP4
port (now-dead `mach-omap2` headers) was dropped. See
[README.md](README.md) "Done so far" section for the full list. No
behavior change; module builds clean, loads, and unloads.

### Subtask 2 — udev-managed char device (done)

Replaced `register_chrdev(222, "pmu_samples", &my_fops)` with
`alloc_chrdev_region` + `cdev_init`/`cdev_add` +
`class_create("pmu_samples")` + `device_create(...)`. udev now creates
`/dev/pmu_samples` on insmod (kernel-allocated major) and removes it on
rmmod. The matching `mknod /dev/pmu_samples c 222 0` block in
[`example_run.sh`](example_run.sh) was deleted.

### x2APIC LVTPC fix (done — discovered while testing Subtask 0)

The original code programmed the local APIC's `LVTPC` register with
`native_apic_mem_write(APIC_LVTPC, APIC_DM_NMI)`. That writes to the
xAPIC MMIO window (`0xFEE00xxx`). **Modern KVM and modern bare-metal
Skylake-SP both default to x2APIC, where MMIO APIC access is silently
no-op'd** — the PMI fires on FIXED_CTR1 overflow but never reaches the
NMI vector. First arming-the-handler test in the guest exposed this:
`Interrupts taken: 0`, `GLOBAL_STATUS` bit 33 set (overflow latched)
but no NMI in `/proc/interrupts`. Three call sites in
[`module/intel.c`](module/intel.c) switched to `apic_write(...)`, which
dispatches via `apic->write` and works in both modes.

This is also the most likely cause of the original bastion hard-lock —
on xAPIC the MMIO write happened to land on the actual APIC register
(by coincidence of identity-mapping), so the original 2.6.32 code
"worked"; on x2APIC the write goes nowhere and any subsequent code that
assumes NMIs are firing wedges the kernel.

### Subtask 0 — NMI/spinlock deadlock fix (done)

**Root cause** (pre-existing). `gatherSample()` ran in NMI context but
called `pop_blist`/`append_blist`, which take a regular `spinlock_t`
via `spin_lock_irqsave`. NMIs are not masked by `irqsave` (they're the
*Non*-Maskable Interrupt — that's a hardware property), so an NMI
delivered while `my_read` held the lock would spin forever in the
handler waiting for the very thread it preempted to release the lock.

**Fix** (this branch). `gatherSample()` is now lock-free in NMI
context: it writes one sample to the per-CPU `lbuffer`, and when that
buffer fills it stashes the buffer in a per-CPU `pending_full` slot,
NULLs `lbuffer`, and calls `irq_work_queue()`. The `irq_work` callback
runs in normal IRQ context (where `spin_lock_irqsave` is correct) and
does the actual `pop_blist`/`append_blist` and `wake_up_all`. If a
later NMI arrives before the irq_work refills `lbuffer`, the sample is
dropped (`missed++`) — the same semantics as the existing `missed`
counter. `startCtrs` pre-fills `lbuffer` so the very first NMI doesn't
auto-miss; `pmu_exit` calls `irq_work_sync` per-CPU before draining
state.

**CPU 3 scoping.** Production workload is `taskset -c 3 ./prog`, so we
only need samples from CPU 3. `process_status_update` and `stopAll`
dispatch via `smp_call_function_single(PMU_TARGET_CPU, ...)` (defined in
[`module/pmu_api.h`](module/pmu_api.h), default 3); the NMI handler
returns `NMI_DONE` on any other CPU so unrelated NMIs (watchdog/kgdb)
still propagate. To retarget to a different core, change `PMU_TARGET_CPU`
in `pmu_api.h` and rebuild — nothing else needs to move.

**Verified** at the paper cadence (period=50,000) on CPU 3 with the
microbench providing real load and `dd` reading samples concurrently —
no hang, no oops, decoded samples look right (`cycles≈period`,
INST_RETIRED counts plausible). Test results in "Test harness" below.

**Out of scope (not blocking this user's workflow):** all-CPU sampling
at period=50,000 + concurrent `dd` deadlocked all 4 vCPUs in earlier
testing. Most likely the four `irq_work` callbacks contend on the
`read_queue` wait-queue lock via `wake_up_all`. Not pursued.

### Subtask 3 — counter expansion to 8 GP + 3 fixed (done)

Goal: sample all 11 counters synchronously on every PMI on CPU 3, not
just 4 GP + 1 fixed.

**Files to touch:**

- [`module/sample_buffer.h`](module/sample_buffer.h): grow `struct sample`
  to `cycles + pid + gp[8] + fixed[3]` (40 → 60 bytes; `BUFFER_ENTRIES`
  recomputes from `(BUFFER_SIZE - 12) / sizeof(struct sample)` to ~68).
- [`module/intel.c`](module/intel.c):
  - Bump `num_ctrs` to 8.
  - `MSR_CORE_PERF_GLOBAL_CTRL` ← `0xFF | (7ULL << 32)` (PMC0..7 +
    FIXED0..2 enabled).
  - `MSR_CORE_PERF_FIXED_CTR_CTRL` ← `0x3B3` (FIXED0 OS|USR=3, FIXED1
    OS|USR|PMI=0xB, FIXED2 OS|USR=3).
  - Add `read_fixed(unsigned i)` returning `MSR_ARCH_PERFMON_FIXED_CTR0+i`.
  - Widen the overflow-clear mask in `my_nmi_handler`.
- [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c):
  - Add sysfs attrs `4`..`7` (existing has `0`..`3`).
  - `gatherSample()`: read 8 GP into `s->gp[]`, 3 fixed into `s->fixed[]`.
  - `startCtrs()` builds `cfgs[0..7]` from the 8 sysfs attrs.
- [`textreader.cpp`](textreader.cpp): print all 11 counters per row.

**Verified** with the microbench + dd harness at period=100,000 on
CPU 3: 10 buffers (40,960 bytes) read cleanly, 680 samples decoded,
all 11 counters present per sample, `gp[7]` (INST_RETIRED.PREC_DIST)
matched `fixed[0]` (INST_RETIRED.ANY) within ~0.02 % per sample —
which incidentally surfaced the Skylake gotcha that
INST_RETIRED.ANY at umask 0x00 only counts on FIXED0, not GP.

**Pre-existing bug fixed along the way:**
`sizeof(struct sample)` would have padded to 64 (8-byte alignment of
`unsigned long cycles`), making `sizeof(struct buffer) = 4048 ≠
BUFFER_SIZE = 4096`. With `dd bs=4096 iflag=fullblock`, dd's second
read would have `count=48 < BUFFER_SIZE` and trip my_read's EINVAL
guard. Fixed by `__attribute__((packed))` on `struct sample` so the
size stays 60 and the buffer remains exactly 4096 bytes — same exact-fit
property the original 4 GP + 1 fixed layout had.

Also fixed a pre-existing missing `<unistd.h>` include in
`textreader.cpp` (referenced `readlink` without it).

### Subtask 4 — paper-style verification at period=50,000 (done)

Configure these 8 architectural events on CPU 3 (encodings stable
across all Intel generations from Skylake-SP through Alder Lake):

| Idx | Event:Umask | Meaning | Cross-check |
|---|---|---|---|
| 0 | `0xC0:0x01` | INST_RETIRED.PREC_DIST | vs FIXED0 (INST_RETIRED.ANY) |
| 1 | `0x3C:0x00` | CPU_CLK_UNHALTED.THREAD_P | vs `s->cycles` |
| 2 | `0x3C:0x01` | CPU_CLK_UNHALTED.REF_XCLK (~100 MHz bus) | — (FIXED2 is REF_TSC, different clock) |
| 3 | `0xC4:0x00` | BR_INST_RETIRED.ALL | — |
| 4 | `0xC5:0x00` | BR_MISP_RETIRED.ALL | rate `gp[4]/gp[3]` |
| 5 | `0x2E:0x4F` | LONGEST_LAT_CACHE.REFERENCE | — |
| 6 | `0x2E:0x41` | LONGEST_LAT_CACHE.MISS | rate `gp[6]/gp[5]` |
| 7 | `0xC0:0x00` | INST_RETIRED.ANY (FIXED0-only; reads as 0 on GP) | unused (kept as a "Skylake quirk" canary) |

**Skylake gotcha confirmed in Subtask 3 testing:** INST_RETIRED.ANY
(`0xC0:0x00`) only increments on FIXED0 — it reads as 0 on a GP counter.
For the GP-vs-FIXED0 cross-check use INST_RETIRED.PREC_DIST (`0xC0:0x01`)
in slot 0; in the Subtask 3 verification the two matched within 0.02 %
(`gp[7]=77617`, `fixed[0]=77633` per sample).

**Cycle-counter cross-check methodology:** `s->fixed[1]` is the raw
FIXED_CTR1 remainder *post*-overflow (`read_ccnt()` itself); the
per-period delta lives in `s->cycles = read_ccnt() + period`. Compare
`gp[1]` (PMC reset every NMI) against `s->cycles`, not against
`s->fixed[1]`.

Userspace writes `(umask << 8) | event` to `/sys/sync_pmu/0..7` (the
module already masks `0xFFFF` and OR-s in USR/OS/EN bits).

**Verified** at period=50,000 on CPU 3 with the microbench (6 s) and
`dd` reading 30 buffers (123 KB, ~2,040 samples decoded), repeated
**5 times back-to-back** to check stability. Per-run:

| run | n | cyc_mean | cyc_stdev | gp[1]/cyc | br% | llc% |
|---|---|---|---|---|---|---|
| 1 | 2039 | 62,460 | 450 | 1.0014 | 0.47 | 4.71 |
| 2 | 2039 | 63,021 | 601 | 1.0015 | 0.52 | 4.13 |
| 3 | 2039 | 63,182 | 458 | 1.0016 | 0.48 | 5.18 |
| 4 | 2038 | 63,088 | 532 | 1.0016 | 0.51 | 3.76 |
| 5 | 2039 | 63,145 | 413 | 1.0015 | 0.47 | 6.20 |

Run-to-run stability:

| Metric | Mean | Stdev | Spread |
|---|---|---|---|
| `cyc_mean` (cycles per sample) | 62,979 | 296 | 722 |
| `gp[1]/cyc` (CLK_CORE vs `s->cycles`) | **1.0015** | **0.0001** | 0.0002 |
| Branch mispredict rate | 0.49 % | 0.024 % | 0.054 % |
| LLC miss rate | 4.80 % | 0.96 % | 2.45 % |

The `gp[1]/cyc` mean ratio holds at 1.0015 with **stdev 0.0001 across
runs** — i.e. the GP counter and the FIXED1-derived `s->cycles` value
agree on the same cycle count, every sample, every run, to within
0.01 %. That's the paper's "synchronous sampling" claim, validated.
**Subtask 4 done.**

### Two characteristics worth understanding before running on bare metal

**1. cycle inflation in the VM is purely KVM PMI overhead** —
**not** turbo. Period sweep with host turbo disabled
([`prepare_for_benchmarking.sh`](prepare_for_benchmarking.sh) run on
the host beforehand, `cpu MHz: 2600.000` confirmed), microbench on
CPU 3, default `events.conf`, 3 runs per period:

| period   | cyc_mean | overhead    | cross-run stdev | fix1 (post-handler) |
|----------|----------|-------------|-----------------|----------------------|
| 50,000   | 62,434   | **+12,434** | 35              | ~17,500 |
| 100,000  | 112,347  | **+12,347** | 67              | ~17,400 |
| 500,000  | 512,403  | **+12,403** | 46              | ~17,400 |
| 1,000,000| 1,012,413| **+12,413** | 38              | ~17,500 |

The overhead is **constant ~12,400 cycles across two orders of
magnitude of period**. That can only be virtualization cost (PMI
exit-to-KVM + re-inject + handler entry on the guest); turbo cannot
produce a constant absolute offset, only a multiplicative factor.
Also note: even with turbo on or off the inflation was the same
(~12K cycles), confirming turbo is not the dominant factor on this
host's KVM. **On bare metal** with sub-microsecond PMI delivery,
expect `cyc ≈ period` to within a few hundred cycles.

`fix1` (`s->fixed[1]`, raw FIXED_CTR1 read after the 8 GP-counter
`rdmsrl`s) sits at ~17,400 — that's the further "in-handler" cycles
spent reading 8 GP MSRs in NMI context. Also a fixed VM cost.

In-run stdev is ~500 cycles; cross-run stdev of the means is now
**35–67 cycles** at all periods — extremely stable.

**2. PMC0/PREC_DIST flakiness from earlier runs is gone** with the
new event set in `events.conf`. The original Subtask 4 set put
`INST_RETIRED.PREC_DIST` (`0xC0:0x01`) on PMC0, which was
intermittently zero on KVM (Skylake/KVM PEBS-counter arbitration).
The current 5-event set (loads/stores/branches/L1D-miss/L1I-miss)
uses no PEBS-precise events on PMC0 and reads stable values across
all runs and all periods (gp[0] stdev ~10 across runs at any period).

### Buffer-pool throughput note

`/sys/sync_pmu/missed` sat near 120,000 of ~120,000 NMIs across runs.
The 8-buffer pool can't keep up with the 50K-cycle PMI rate when the
reader is `dd count=30`. The captured samples are correct, just
sparse. To capture more, raise the pool size in `pmu_init` (currently
8 buffers preallocated) or use [textreader](textreader.cpp) running
continuously.

---

## Setup recipe — VM from scratch

This is the one-time path to get a working KVM guest. Skip to "Test
harness" if your guest is already built.

### 1. Host preparation (once per host)

```bash
# Confirm KVM is usable
grep -Ec '(vmx|svm)' /proc/cpuinfo     # > 0
ls /dev/kvm                            # exists
id | grep -E 'kvm|libvirt'             # both groups (ask sysadmins on shared host)

# Install libvirt + tooling
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
                    virtinst cloud-image-utils virt-manager
```

If `virt-install` later prints `KVM acceleration not available, using 'qemu'`,
you've fallen back to TCG software emulation — **the guest's PMU won't be
real** and any test result is meaningless. Almost always missing `kvm` group;
fix that first.

### 2. Provision the guest (cloud-image flow)

The README's old `--location http://archive.ubuntu.com/...installer-amd64/`
URL no longer has bootable kernel/initrd files — Ubuntu's server installer
is Subiquity now. Use a cloud image instead:

```bash
VMDIR=/var/tmp/kbh8sa-pmu-vm           # local disk; libvirt-qemu can't read NFS homes
mkdir -p $VMDIR && chgrp kvm $VMDIR && chmod 750 $VMDIR
cd $VMDIR

# Cloud image + cloud-init seed
wget -O jammy-cloudimg.qcow2 \
  https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
qemu-img resize jammy-cloudimg.qcow2 +13G

cat > user-data <<'EOF'
#cloud-config
hostname: pmu-test
users:
  - name: ubuntu
    plain_text_passwd: ubuntu
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
ssh_pwauth: True
package_update: true
packages:
  - build-essential
  - linux-headers-generic
  - git
  - libboost-dev
  - openssh-server
EOF
echo "instance-id: pmu-test-1" > meta-data
cloud-localds seed.iso user-data meta-data

virt-install \
  --connect qemu:///system \
  --name pmu-test --memory 4096 --vcpus 4 \
  --cpu host-passthrough,topology.sockets=1,topology.cores=4,topology.threads=1 \
  --disk path=$VMDIR/jammy-cloudimg.qcow2,format=qcow2,bus=virtio \
  --disk path=$VMDIR/seed.iso,device=cdrom \
  --import --os-variant ubuntu22.04 \
  --network network=default,model=virtio \
  --graphics none --noautoconsole

# Find guest IP
virsh -c qemu:///system domifaddr pmu-test
ssh ubuntu@<ip>        # password: ubuntu
```

Inside the guest, confirm PMU passthrough:

```bash
sudo dmesg | grep -i 'perf\|pmu' | head
sudo apt install -y cpuid msr-tools
cpuid -1 -l 0xa -r     # EDX low 5 bits = #fixed counters; expect 3
```

### 3. Get the source into the guest

```bash
git clone -b kernel-5.15 \
  https://github.com/yyilong335/pmu_sync_sampler.git ~/pmu_sync_sampler
cd ~/pmu_sync_sampler/module && make
gcc -O2 -Wall -o ../microbench ../microbench.c
```

### 4. Snapshot a clean state

From the **host**:

```bash
virsh -c qemu:///system shutdown pmu-test
virsh -c qemu:///system snapshot-create-as pmu-test clean-build \
    "Toolchain installed, repo cloned, module built"
virsh -c qemu:///system start pmu-test
```

Recovery from this snapshot any time the guest hangs:

```bash
virsh -c qemu:///system destroy pmu-test
virsh -c qemu:///system snapshot-revert pmu-test clean-build
virsh -c qemu:///system start pmu-test
```

---

## Test harness

Two userspace pieces work together with the module:

- [`microbench.c`](microbench.c) — pinned to CPU 3, runs a tight ALU loop
  for N seconds (default 10). Provides a deterministic workload so
  `FIXED_CTR1` actually ticks and the PMI rate approaches its rated
  cadence.
- `dd if=/dev/pmu_samples ...` (or
  [`textreader.cpp`](textreader.cpp)) — drains `full_buffers` from
  userspace so the buffer pool doesn't saturate.

Standard run (current — uses [`start_sampler.sh`](start_sampler.sh)
and [`events.conf`](events.conf)):

```bash
cd ~/pmu_sync_sampler
sudo ./start_sampler.sh 50000                  # default events.conf
sudo dd if=/dev/pmu_samples of=/tmp/samples.bin \
    bs=4096 iflag=fullblock count=64 status=none &
taskset -c 3 ./microbench &                    # workload on CPU 3
wait %1
sudo bash -c "echo 0 > /sys/sync_pmu/status"
cat /sys/sync_pmu/missed
sudo rmmod pmu_sync_sample

# Decode (textreader takes a binary file path as argv[1])
./textreader /tmp/samples.bin > /tmp/samples.csv
```

Each CSV row is:
`pid, core, cyc, gp[0..7], fixed[0..2], cmdline, executable`. With
the default `events.conf` that's
`pid, core, cyc, L1D_LOAD, L1D_STORE, BR_INST_ALL, L1D_READ_MISS, L1I_MISS, 0, 0, 0, INST_RETIRED.ANY, CPU_CLK_UNHALTED.CORE, CPU_CLK_UNHALTED.REF_TSC, ...`.

### Single-CPU verification results (Subtask 0)

| Test | Period | Workload | NMIs on CPU 3 | Captured | `missed` | dd reads |
|---|---|---|---|---|---|---|
| A | 100,000 | microbench, no dd | 100,712 | 816 = 8 buf × 102 | 99,896 | n/a |
| B | 100,000 | microbench + dd 10 buf | 120,383 | 1,836 | 118,547 | OK (40 KB) |
| C | 50,000 (paper) | microbench + dd 20 buf | 174,171 | 2,856 | 171,315 | OK (80 KB) |

In Test A the captured count exactly matches `8 × BUFFER_ENTRIES` —
without a reader, `empty_buffers` drains, every subsequent NMI bumps
`missed`. Correct behavior.

Decoded Test C samples: `core=3`, `num_samples=102`,
`pid` = microbench, `cycles ≈ 51,000 ≈ period`, four GP counters all
showing matching INST_RETIRED.ANY values.

### Snapshots in libvirt

- `clean-build` — toolchain installed, repo built, no insmod yet.
- `post-subtask2` — Subtask 2 verified.

---

## Recovery procedures

| Symptom | Action |
|---|---|
| Guest unresponsive, SSH dead | `virsh destroy pmu-test` from host |
| Suspect kernel oops captured | `virsh console pmu-test` to read serial dmesg, scp out, then destroy |
| Need to retry from scratch | `virsh snapshot-revert pmu-test <snap>` |
| Module load failed cleanly (no hang) | `dmesg \| tail -50`, fix, `make`, re-insmod — no VM reset needed |

Persist `dmesg` after every test run via `scp` so a guest revert
doesn't lose them.

## Out of scope (deferred or won't-fix here)

- **All-CPU sampling.** Production target is single-CPU; the all-CPU dd
  deadlock isn't blocking and isn't pursued.
- **`stopAll()` clobbers global PMU state on every CPU at `rmmod`.**
  Doesn't cause hangs; just steals counters from other PMU users.
  Should be scoped to only counters we own, but later.
- **`sender/`, `reader/` wire format still encodes 6 counters.** Will
  silently truncate after Subtask 3 widens `struct sample`. Fix
  alongside Subtask 4 if needed; for now `textreader.cpp` is the
  reference reader.

---

## Appendix: testing on Ubuntu 24.04 / kernel 6.x / Alder Lake

Viable interim if `bastion` is unavailable, with caveats.

**Hybrid PMU.** P-cores expose 8 GP + 3 fixed counters; E-cores expose
6 GP + 3 fixed and use a different event encoding. Pin all vCPUs to
P-cores so the guest sees a homogeneous PMU:

```bash
cat /sys/devices/cpu_core/cpus     # P-core CPUs (kernel 6.x)
cat /sys/devices/cpu_atom/cpus     # E-core CPUs

virsh -c qemu:///system vcpupin pmu-test 0 0
virsh -c qemu:///system vcpupin pmu-test 1 2
virsh -c qemu:///system vcpupin pmu-test 2 4
virsh -c qemu:///system vcpupin pmu-test 3 6
```

**Kernel 6.x API drift.** Watch for `class_create()` losing the
`THIS_MODULE` argument in 6.4 — the Subtask 2 code uses the 5.15
signature `class_create(THIS_MODULE, "pmu_samples")` which won't compile
on 6.4+. Use `class_create("pmu_samples")` instead.

**Event encodings** are architectural — the Subtask 4 table works on
Alder Lake P-core unchanged. Just record which CPU each Stage 5 run
was on; steady-state numbers will differ between Skylake-SP and Alder
Lake.

In the cloud-init flow, set `DIST=noble` and `--os-variant ubuntu24.04`.

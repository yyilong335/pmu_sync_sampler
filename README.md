# pmu_sync_sampler

A Linux kernel module + small userspace tools that **synchronously sample
all configured PMU counters at a fixed cycle interval**. The current
target is **Linux 5.15 / Intel Xeon Gold 6142 (Skylake-SP, SMT off, 8 GP + 3 fixed counters)**, sampling on **CPU 3 only**, with `period = 50,000` cycles between PMIs.

> **Read this first if you're a new Claude / new contributor**:
> [`CLAUDE.md`](CLAUDE.md) has the project's behavioral guidelines and
> a "project context" section that summarizes hardware target, branch,
> file map, and what's done.

## Branches: original vs. modernized

| Branch | What's on it |
|---|---|
| **`master`** | The **original** code (John Demme, 2.6.32-era) — last touched on Linux 2.6.32 / Intel Xeon 5550 (Nehalem). Used `register_die_notifier` for NMI, hardcoded char-device major 222, sampled 4 GP + 1 fixed counter, ARM/OMAP4 port still present. **Frozen reference**; don't add commits here without explicit approval. |
| **`kernel-5.15`** | The **modernized** version this README describes. Linux 5.15, Skylake-SP, 8 GP + 3 fixed, irq_work-safe NMI, x2APIC LVTPC, udev-managed device, configurable events via `events.conf`. All current work goes here. |

Concretely, `kernel-5.15` adds on top of `master`:

| What changed | Where |
|---|---|
| NMI hook: `register_die_notifier` → `register_nmi_handler(NMI_LOCAL, …)` (Linux 4.x+ API) | [`module/intel.c`](module/intel.c) |
| ARM/OMAP4 port dropped (dead `mach-omap2` headers) — Intel-only now | `module/arm.c` removed; `Makefile.intel` → `Makefile` |
| Char device: `register_chrdev(222, …)` → `alloc_chrdev_region` + `cdev_init` + `class_create` + `device_create`. udev creates `/dev/pmu_samples` with a kernel-allocated major. | [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c) |
| **NMI/spinlock deadlock fix** (the original bug that hard-locked the host on modern many-core CPUs): NMI no longer takes `spin_lock_irqsave`; buffer hand-off deferred to `irq_work` running in normal IRQ context. | [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c) |
| **x2APIC `LVTPC`**: `native_apic_mem_write` → `apic_write` (the `_mem` variant silently no-ops under x2APIC, which is the default on modern KVM and Skylake-SP — the reason the first VM test reported `Interrupts taken: 0`). | [`module/intel.c`](module/intel.c) |
| Sample 8 GP + 3 fixed counters per PMI (was 4 + 1). `MSR_CORE_PERF_GLOBAL_CTRL = 0xFF \| (7ULL<<32)`, `FIXED_CTR_CTRL = 0x3B3`, `struct sample` widened to `gp[8] + fixed[3]` and `__attribute__((packed))` so `sizeof(struct buffer) = BUFFER_SIZE` exactly. | [`module/intel.c`](module/intel.c), [`module/sample_buffer.h`](module/sample_buffer.h), [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c) |
| **CPU-3-only target**: `PMU_TARGET_CPU = 3`; arm/disarm via `smp_call_function_single` (was `on_each_cpu`). NMI handler returns `NMI_DONE` on every other CPU. | [`module/pmu_api.h`](module/pmu_api.h), [`module/intel.c`](module/intel.c), [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c) |
| **First-sample contamination fix**: `startCtrsLocal` now clears PERFCTR0..7, FIXED_CTR0, FIXED_CTR2 before re-enabling `GLOBAL_CTRL`, symmetric with the NMI handler's reset. Caught by per-sample sanity check (`STALL > cyc`). | [`module/intel.c`](module/intel.c) |
| Wider eventsel encoding: `pmn_config` accepts CMask, Invert, edge bits (was masked to low 16). USR/OS/EN forced; INT cleared. | [`module/intel.c`](module/intel.c) |
| **`lbuffer == NULL` recovery**: NMI's miss path now also queues `irq_work` so buffers returned to `empty_buffers` while `lbuffer` was NULL get picked up promptly. Otherwise a brief reader stall (>10 ms) could leave the sampler stuck even after the reader catches up. | [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c) |
| **sender/reader updated to 8 GP + 3 fixed**: anonymous union exposes `gp[8] + fixed[3]` and `counters[11]` over the same memory; sender/reader use the flat `counters[]` view (same convention as master's `counters[6]`, just widened). Two pre-existing missing `<unistd.h>` includes added so `sender/` builds on modern GCC. | [`module/sample_buffer.h`](module/sample_buffer.h), [`sender/`](sender/), [`reader/`](reader/) |
| Userspace tooling added: [`events.conf`](events.conf) (8-slot event config), [`start_sampler.sh`](start_sampler.sh) (load + arm + write events), [`microbench_mem.c`](benchmarks/microbench_mem.c) (memory-bound demo workload), [`prepare_for_benchmarking.sh`](prepare_for_benchmarking.sh) (turbo/watchdog/ASLR off). [`textreader`](textreader.cpp) now accepts a binary file path or `-` for stdin. | repo root |
| Docs added: this README, [`CLAUDE.md`](CLAUDE.md) project-context section, [`SAMPLING_WORKFLOW.md`](SAMPLING_WORKFLOW.md), [`VM_TESTING.md`](VM_TESTING.md), [`event.md`](event.md). | repo root |

Subtask-level history is in [`VM_TESTING.md`](VM_TESTING.md).
Counter-semantics and variance analysis are in
[`SAMPLING_WORKFLOW.md`](SAMPLING_WORKFLOW.md).

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
gcc -O2 -Wall -o benchmarks/microbench_mem benchmarks/microbench_mem.c   # memory-bound demo workload

# 4. Arm the sampler with the events listed in events.conf, period=50,000.
sudo ./start_sampler.sh 50000

# 5. Run a workload on CPU 3 and drain samples concurrently.
sudo ./textreader > /tmp/samples.csv &
taskset -c 3 ./benchmarks/microbench_mem 10 1
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
| 4 | Paper-style verification at `period = 50,000` | ✓ done (KVM + Alder Lake bare metal + Skylake-SP bare metal) |
| 0 | Fix latent NMI/spinlock deadlock via `irq_work` (was the bug that hard-locked the original host) | ✓ done |
| — | x2APIC `LVTPC` programming via `apic_write` (was a latent xAPIC-only assumption) | ✓ done |
| — | Reset PERFCTR / FIXED_CTR0 / FIXED_CTR2 in `startCtrsLocal` (first-sample contamination) | ✓ done |
| — | Configurable GP event set via `events.conf` + `start_sampler.sh` | ✓ done |
| — | Bare-metal validation on Alder Lake (`adl` branch) | ✓ done |
| — | Bare-metal validation on Skylake-SP / bastion (`skl` branch) | ✓ done (2026-05-11) |

**Branches**: `master` (frozen reference), `kernel-5.15` (common ancestor
for the per-uarch ports), `adl` (Alder Lake i5-1240P, `PMU_TARGET_CPU=2`),
`skl` (Skylake-SP / bastion, `PMU_TARGET_CPU=3`). Driver code is identical
across `kernel-5.15` / `adl` / `skl`; only HW-specific values differ.
**Don't push to `master` without explicit approval.**

### Where we are (2026-05-11)

The sampler works correctly on bare-metal Skylake-SP at the paper's
period of 50,000 cycles. Two smoke runs at that period — a memory-walk
bench and a tight ALU bench — produced 134k + 424k samples each, with
`missed=0`, no oops/WARN, and clean rmmod. The driver's `irq_work` fix
is now exercised on a 16-core bare-metal host without deadlocking. See
[`ONBOARDING.md`](ONBOARDING.md) for the per-PMI overhead, IPC reference
numbers, and the bastion-specific gotchas (stale `.ko` vermagic, Intel
VTune driver auto-load, running KVM guests reserving PMC0).

### Open questions / next steps

These are the things we want to refine before declaring the sampler
"production ready" for real workload measurement:

- **Per-PMI overhead is ~2,000 cycles on Skylake-SP, not the ≤500 we
  projected.** Measured `cyc` mean is ~52,100 at period=50,000.
  Investigate where the time goes — PMI delivery hardware latency, NMI
  handler prologue, the LVTPC re-arm, MSR-read serialization. Compare to
  Alder Lake's ~1,000 cycles to see what's uarch-inherent vs. fixable.
- **Stability characterization.** We have one run per bench right now.
  Quantify within-run `cyc` variance (p1/p50/p99 spread) and between-run
  drift (5+ back-to-back invocations). Currently only the bisected `cyc`
  mean is reported.
- **CSV header row.** `textreader` emits raw rows with no header.
  Adding one (`pid,core,cyc,c0,c1,...,c10,cmdline,exe`) would make
  downstream analysis less fragile. Trade-off: deviates from master's
  format — gate behind a `--header` flag or env var to keep the default
  matching master.
- ~~**Bastion VTune-driver auto-unload.**~~ Done: `prepare_for_benchmarking.sh`
  now `rmmod`s `socwatch2_16`, `vtsspp`, `sep5`/`sep5_59`, `pax` (in stack
  order, idempotent) so one `sudo ./prepare_for_benchmarking.sh` per
  session is enough. The auto-load via systemd at boot still happens —
  if anyone else on bastion needs VTune, masking the systemd unit is the
  alternative, but for now we just unload at session prep time.
- **skl vs adl IPC analysis.** `microbench_ipc` reaches 5.155 IPC on
  Alder Lake P-core (Golden Cove, 6-wide retire) but only 2.530 on
  Skylake-SP (4-wide retire). Worth a side-by-side: same bench, same
  build, both branches' CSVs in `results/microbench/{adl,skl}/`,
  comparison written up so we can rule out a sampler regression vs.
  pure uarch effect. Currently the adl CSVs are not in this repo at all.
- **SPEC CPU sampling** (user will add commands). Real-workload
  validation — pick a SPEC binary, sample it via the harness, cross-check
  counter sums against `perf stat` to demonstrate parity with the
  industry-standard tool.

### Known issues, not blocking ongoing work

- **`stopAll()` clobbers global PMU state on every CPU at `rmmod`**:
  writes `MSR_CORE_PERF_GLOBAL_CTRL = 0` and masks `LVTPC` on every
  CPU. Anything else using the PMU loses its counters. Should be
  scoped to only the counters and CPU we own, but doesn't crash
  anything. Defer.
- **VTune drivers stalled `insmod` for ~90 s on bastion** when loaded
  (Intel's `pax` PMU arbiter intercepts `reserve_perfctr_nmi`). Now
  guarded by a precheck in `skl_smoke.sh`, but the underlying conflict
  is intrinsic — both drivers want the same MSRs.
- **Stale `.ko` from a different kernel version** silently loads on
  Ubuntu (`MODULE_VERMAGIC_MODVERSIONS`) but corrupts kernel state
  invisibly, eventually triggering BMC hard-reset. Discovered the hard
  way on bastion. Documented in ONBOARDING.md preflight; consider
  adding a vermagic-vs-`uname -r` guard to the smoke script.

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
benchmarks/                        ─ workloads pinned to CPU 3 (microbench, microbench_mem, microbench_alu)
results/                           ─ sample CSVs + summaries from verification runs (gitignored)
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

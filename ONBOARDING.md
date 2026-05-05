# pmu_sync_sampler — onboarding

This repo is a Linux 5.15 / Skylake-SP port of a 2.6.32-era synchronous PMU
sampler. **Read [`CLAUDE.md`](CLAUDE.md) first** — it is the authoritative
project guide. This file captures session-level context Claude Code on a
fresh machine wouldn't otherwise have.

## Current branch + status

- Active branch: **`kernel-5.15`** (do not push to `master`).
- All five subtasks done: 5.15 modernization, udev char-dev, 8 GP + 3 fixed
  counters, paper-style verification at period=50,000, NMI/spinlock
  deadlock fix via `irq_work`.
- Plus latent bugs fixed during VM testing: x2APIC `LVTPC` via `apic_write`,
  first-sample contamination via missing counter resets, sample-struct
  alignment via `__attribute__((packed))`.
- Branch typically a few commits ahead of origin. Run `git fetch origin &&
  git status -sb` before claiming a delta — don't trust stale state.

## Repo layout (after recent reorg)

```
benchmarks/    microbench.c, microbench_mem.c, microbench_alu.c
results/       samples_*.csv + samples_*_summary*.txt (gitignored)
module/        kernel module (pmu_sync_sample.ko)
sender/        legacy TCP shipper (compiles, not in active workflow)
reader/        legacy TCP consumer (mirror of sender)
textreader.cpp local CSV reader for /dev/pmu_samples — the active tool
start_sampler.sh   insmod + period + events.conf + status=1
prepare_for_benchmarking.sh  pin freq, disable turbo/watchdog/ASLR
```

Legacy root-level programs (`hello.cpp`, `exercise1.cpp`) are unused but
kept to minimize diff vs master.

## Verified workload IPC reference

At period=50,000 on the dev VM (KVM, host-passthrough):

| workload                         | mean cyc | IPC   | STALL_RETIRE/cyc | L1D_REPL/period |
|----------------------------------|----------|-------|-------------------|------------------|
| `microbench_mem` (random walk)   | 62,937   | 0.08  | 0.92              | 1,211            |
| `microbench_alu` (8 indep. adds) | 62,458   | 1.07  | 0.47              | 68               |

`cyc - period ≈ 12,500` cycles is KVM PMI delivery overhead (bare metal:
~200–500). Per-run mean cyc CV across 5 back-to-back runs is 0.05% — runs
are highly repeatable. See `results/samples_*_summary.txt` for the full
tables (gitignored, regenerate locally).

## Test harness (per-machine, not in git)

- VM staging on the dev machine: `/var/tmp/$USER-pmu-vm/` (libvirt config,
  cloud-init seed, SSH keys, `thorough_verify.sh`).
- A fresh machine has none of this. Either follow [`VM_TESTING.md`](VM_TESTING.md)
  "Setup recipe — VM from scratch", or skip to bare metal — the unsafe
  paths that originally hard-locked bastion are all fixed now.
- Outputs from `thorough_verify.sh` land in `results/` after `scp` from
  guest to host.

## Known issues, deferred (not blocking)

- **`lbuffer == NULL` recovery hole**: if a reader stalls long enough to
  drain the 8-buffer pool, `gatherSample` on `b == NULL` only bumps
  `missed`; subsequent buffer returns can't get picked up until something
  else queues `irq_work`. **Fixed** in commit `4737270` — the NMI's NULL
  path now also calls `irq_work_queue`. (Listed here so future sessions
  don't try to "fix" it again.)
- **`stopAll()` clobbers global PMU state on every CPU at `rmmod`**:
  doesn't crash, just steals counters from any other PMU user. Defer.
- **`sender/reader/` wire format previously encoded only 6 counters** —
  fixed in `4737270` (now uses `NUM_GP_COUNTERS + NUM_FIXED_COUNTERS = 11`).

## Match-master rule (load-bearing)

The user has explicitly required: **kernel-5.15 logic must match master's**;
minimize diff; don't refactor for "cleanliness." Strict-necessity exceptions
only: kernel API drift, latent HW bugs, user-asked features, correctness
fixes. Bypassing master patterns (e.g. using `dd` instead of `sender`,
splitting flat arrays into anonymous unions, helper macros for inlined
literals, argv extensions to userspace tools that had none) is a violation.
A previous audit reverted three such divergences in commit `74e3c4c`.

## NMI handler invariants (do not change without explicit ask)

- MSR ordering in [`module/intel.c`](module/intel.c) — `OVF_CTRL` clear,
  `gatherSample`, FIXED_CTR1 reset, GP/FIXED resets, LVTPC re-arm. The
  reorder-for-variance experiment was already done; it didn't help and
  was reverted.
- `gatherSample` read order in [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c)
  — `read_ccnt`, GP loop, fixed loop. Same reasoning.
- Counters reset at handler **exit**, not entry. So each sample's GP
  counters span `previous_handler_exit → current_handler_MSR_read` =
  workload period + handler prologue overhead. The IPC numbers above
  confirm this is correct (memory-bound shows low IPC, compute-bound
  shows high IPC).

## Workflow expectation

The user prefers action over planning, concise text output, honest
disagreement when their hypothesis is wrong, and no churn. Don't change
code that doesn't help.

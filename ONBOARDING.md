# pmu_sync_sampler — onboarding

This repo is a Linux 5.15 / Skylake-SP port of a 2.6.32-era synchronous PMU
sampler. **Read [`CLAUDE.md`](CLAUDE.md) first** — it is the authoritative
project guide. This file captures session-level context Claude Code on a
fresh machine wouldn't otherwise have.

## Branches

```
master ──► kernel-5.15 ──► adl  (Alder Lake i5-1240P, CPU 2 — validated bare metal)
                       └─► skl  (Skylake-SP / Xeon Gold 6142 — bastion target)
```

- **`master`** — frozen reference (original 2.6.32-era code). Do not push.
- **`kernel-5.15`** — Linux 5.15 / Skylake-SP modernization + the irq_work,
  apic_write, packed-struct, and first-sample bug fixes. All five subtasks
  done; verified in KVM. Common ancestor for the per-uarch ports below.
- **`adl`** — Alder Lake i5-1240P port: `PMU_TARGET_CPU=2`, hybrid-CPU notes
  in `pmu_api.h`. Validated bare metal end-to-end (commits `2a1ef2b`,
  `1221642`).
- **`skl`** — Skylake-SP / bastion port: `PMU_TARGET_CPU=3`, full 7-event
  `events.conf`, `num_ctrs=8`. Adds `microbench_ipc.c` + `skl_smoke.sh` +
  the no-watcher CLAUDE.md note inherited from `adl`. **Validated bare
  metal on bastion** (2026-05-11): two clean smoke runs at period=50,000,
  `missed=0`, no oops/WARN, 134k + 424k sample CSVs landed in `results/`.

Run `git fetch origin && git status -sb` before claiming a delta — don't
trust stale state.

## What's verified, what isn't

- **Driver correctness**: kernel-5.15 in KVM ✓, adl bare metal ✓, skl bare
  metal ✓ (bastion, 2026-05-11). The driver code itself is the same on adl
  and skl; only `PMU_TARGET_CPU`, `num_ctrs`, `GLOBAL_CTRL` enable mask,
  and the `events.conf` set differ.
- **Bug fixes** (NMI/spinlock deadlock via `irq_work`, x2APIC `apic_write`,
  `__attribute__((packed))` sample, `startCtrsLocal` first-sample reset,
  lbuffer-NULL recovery): all in kernel-5.15, inherited unchanged by adl
  and skl.
- **Userspace tooling**: textreader and the four benchmarks
  (microbench, microbench_alu, microbench_mem, microbench_ipc) build
  with stock `gcc -O2 -Wall` on Linux 5.15.

## Repo layout

```
benchmarks/                microbench.c, microbench_alu.c, microbench_mem.c,
                           microbench_ipc.c (high-IPC, watcher-free)
results/                   *.csv + *_summary*.txt + *.log + *.err (gitignored)
module/                    kernel module sources (pmu_sync_sample.ko)
sender/                    legacy TCP shipper (compiles, not in active workflow)
reader/                    legacy TCP consumer (mirror of sender)
textreader.cpp             local CSV reader for /dev/pmu_samples — the active tool
events.conf                7-event GP slot configuration (Skylake-SP encodings)
start_sampler.sh           insmod + period + events.conf + status=1 (legacy)
prepare_for_benchmarking.sh   pin freq, disable turbo/SMT/watchdog/ASLR
adl_smoke.sh / skl_smoke.sh   one-shot smoke harness on each branch
```

Legacy root-level programs (`hello.cpp`, `exercise1.cpp`) are unused but
kept to minimize diff vs master.

## Verified workload IPC reference

| branch | uarch | env | bench | mean cyc | IPC | notes |
|---|---|---|---|---:|---:|---|
| kernel-5.15 | Skylake-SP | KVM (host-pt) | `microbench_mem` | 62,937 | 0.08 | memory-bound, real |
| kernel-5.15 | Skylake-SP | KVM (host-pt) | `microbench_alu` | 62,458 | 1.07 | **broken bench** (see below) |
| adl | Alder Lake P | bare metal | `microbench_alu` | 51,005 | 1.50 | broken; KVM tax removed |
| adl | Alder Lake P | bare metal | `microbench_ipc` | 50,943 | **5.155** | clean watcher-free bench |
| skl | Skylake-SP | bare metal | `microbench_alu` | 52,055 | 1.239 | bastion 2026-05-11, broken bench |
| skl | Skylake-SP | bare metal | `microbench_ipc` | 52,143 | **2.530** | bastion 2026-05-11, clean bench |

`cyc - period` is the per-PMI handler-entry latency:
- KVM (host-passthrough): ~12,500 cycles. VMEXIT → KVM PMI inject → VMENTER.
- Alder Lake bare metal: ~1,000 cycles. Hardware NMI gate + a few rdmsrl.
- Skylake-SP bare metal (measured on bastion): ~2,055 cycles. Higher than
  the earlier ≤500-cycle projection — Skylake-SP's NMI delivery path is
  longer than Golden Cove's, but still ~6× cheaper than KVM and far below
  the 50,000-cycle sample period.

Skylake-SP IPC ceiling for `microbench_ipc` lands at **~2.5** because the
uarch retires 4-wide and the asm loop is 8 adds + 3 loop-overhead instructions
≈ 10 inst over 4 cycles. Golden Cove's 6-wide retire is why adl reaches 5.155.
This is a uarch fact, not a sampler issue.

## The `microbench_alu` story (load-bearing for any future bench work)

`microbench_alu.c` looks like an 8-independent-add ALU kernel but `gcc -O2`
strength-reduces the inner 1M-iter loop into a closed-form `a_i += K_i * 1M`
(disassembly confirms — there is no inner loop in the binary). The hot loop
becomes the *outer* loop, dominated by `clock_gettime` (VDSO) plus FP
elapsed-time arithmetic. So both the VM number (1.07) and the bare-metal
number (1.50) are measuring `clock_gettime` throughput, not ALU throughput.

The watcher effect is the general lesson: **microbenchmarks observed by an
external sampler must not contain their own measurement infrastructure in
the timed kernel**. No `clock_gettime`, no `printf`, no FP elapsed-time
math, no syscalls. Use `asm volatile` to prevent compiler folding; iter
count from `argv[1]`; emit accumulator digest only after the loop.
[`benchmarks/microbench_ipc.c`](benchmarks/microbench_ipc.c) is the
canonical example. See the "Microbenchmarks: no watcher in the timed loop"
section of `CLAUDE.md` for the full rule. This rule is also persisted in
account-level memory, so future sessions on any project will respect it.

## Test harness on bastion (skl branch)

### Preflight gotchas

**Stale `.ko` after switching branches / kernel updates.** This caused
every hard-reset on bastion before 2026-05-11. The `.ko` on disk is the
only thing `insmod` cares about — branch state and source files don't
matter at load time. If the `.ko` was built against a different kernel
version than the running one, stock Ubuntu loads it anyway (it has
`MODULE_VERMAGIC_MODVERSIONS`), but internal kernel structure offsets are
wrong and the kernel silently corrupts state until the BMC watchdog
hard-resets the box minutes later. **Always rebuild after**:
- `git checkout` to a different branch (esp. one with a different commit
  history of `module/*.c`).
- A kernel upgrade on the host (`uname -r` changes).

Verify before `insmod`:
```bash
uname -r                                          # running kernel
modinfo module/pmu_sync_sample.ko | grep vermagic # built-against kernel
# They must match.
```
The fix is `cd module && make clean && make`.

**Intel VTune drivers reserve PMC0 at boot.** On bastion, `pax`,
`sep5_59`, `vtsspp`, and `socwatch2_16` auto-load via systemd at ~127s
of boot. `pax` is a PMU arbiter that intercepts `reserve_perfctr_nmi`
and stalls our `insmod` for ~90 seconds before returning `EBUSY`. Plus
they hold the PMU counters themselves. Unload before each session:
```bash
sudo rmmod socwatch2_16 vtsspp sep5 pax
```

**Running KVM guests reserve PMC0 via vPMU passthrough.** If `virsh list`
shows any running guest with `--cpu host-passthrough`, that guest holds
the host's PMC0. `skl_smoke.sh` now precheck-errors on this.

**`prepare_for_benchmarking.sh`'s `kernel.nmi_watchdog=0`** is now
persisted to `/etc/sysctl.conf` (was non-persistent before 2026-05-11).
On the previous boot's behavior: the NMI watchdog reserves PMC0 and
`insmod` fails with `EBUSY`. Run `prepare_for_benchmarking.sh` once per
session; the persistence handles future reboots.

### One-shot smoke run

```bash
# bastion side, one-time setup per session
git fetch && git checkout skl
cd module && make && cd ..
make textreader
gcc -O2 -Wall -o benchmarks/microbench_alu benchmarks/microbench_alu.c
gcc -O2 -Wall -o benchmarks/microbench_ipc benchmarks/microbench_ipc.c
sudo ./prepare_for_benchmarking.sh   # also un-stops watchdog after reboot

# 1) the broken-by-design bench, just to A/B against the existing kernel-5.15 VM number
sudo bash skl_smoke.sh 2>&1 | tee results/skl_microbench_alu.log

# 2) the high-IPC bench, the actual measurement we care about
sudo BENCH=./benchmarks/microbench_ipc BENCH_ARGS=5000000000 \
     bash skl_smoke.sh 2>&1 | tee results/skl_microbench_ipc.log
```

### What success looks like

| signal | healthy value |
|---|---|
| dmesg | `Configuring PMU on core 3`, no oops/WARN, clean `rmmod` |
| `missed` | 0, or low single digits |
| csv lines | tens to hundreds of thousands depending on bench runtime |
| `<bench_name>` rows | > 99 % of total (workload pid attribution) |
| `cyc` mean | 50,000 + ~2,000 (measured Skylake-SP bare-metal entry latency) |
| `c0..c6` (7 GP slots) | non-zero per `events.conf` mapping |
| `c7` (8th GP slot) | 0 (events.conf has 7 entries) |
| IPC line for `microbench_ipc` | ~2.5 (Skylake-SP 4-wide retire ceiling for this bench) |
| IPC line for `microbench_alu` | ~1.0–1.5 (broken; use only as A/B against VM 1.07) |

### Smoke-script invariant the kernel state machine forces on us

`echo 0 > /sys/sync_pmu/status` calls `stopAll()` which sets `shutdown=2`.
After that, any `read(/dev/pmu_samples)` returns 0 immediately (EOF).
**Don't write 0 to status before launching textreader** — textreader will
see EOF and exit. Fresh `insmod` already starts in the stopped state with
`shutdown=0`, so the redundant `echo 0` is not just harmless, it's
actively breaking. The current `skl_smoke.sh` skips it; future scripts
must too.

## Known issues, deferred (not blocking bastion validation)

- **`stopAll()` clobbers global PMU state on every CPU at `rmmod`**:
  writes `MSR_CORE_PERF_GLOBAL_CTRL = 0` and masks `LVTPC` system-wide.
  Doesn't crash; just steals counters from any other PMU user. Defer.
- **NMI watchdog reboot persistence** — see "Preflight gotcha" above.
  Cosmetic until you forget once.
- **lbuffer == NULL recovery hole** — fixed in `4737270` (kernel-5.15);
  listed only so future sessions don't "fix" it again.
- **`sender/reader/` wire format previously encoded 6 counters** — fixed
  in `4737270` (now uses `NUM_GP_COUNTERS + NUM_FIXED_COUNTERS = 11`).

## Match-master rule (load-bearing for kernel-5.15)

The user has explicitly required: **kernel-5.15 logic must match master's**;
minimize diff; don't refactor for "cleanliness." Strict-necessity exceptions
only: kernel API drift, latent HW bugs, user-asked features, correctness
fixes. A previous audit reverted three such divergences in commit `74e3c4c`.

The per-uarch branches (`adl`, `skl`) inherit this — their delta vs
kernel-5.15 should be HW-specific values + tooling additions only, never
core-driver refactors. Verify with `git diff kernel-5.15 -- module/` —
should be near-empty.

## NMI handler invariants (do not change without explicit ask)

- MSR ordering in [`module/intel.c`](module/intel.c) — `OVF_CTRL` clear,
  `gatherSample`, FIXED_CTR1 reset, GP/FIXED resets, LVTPC re-arm. The
  reorder-for-variance experiment was already done; it didn't help and
  was reverted.
- `gatherSample` read order in [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c)
  — `read_ccnt`, GP loop, fixed loop. Same reasoning.
- Counters reset at handler **exit**, not entry. Each sample's GP counters
  span `previous_handler_exit → current_handler_MSR_read` = workload
  period + handler prologue overhead. The IPC numbers in the table above
  confirm this is correct (memory-bound shows low IPC, compute-bound
  shows high IPC, watcher-free bench reaches near-architectural ceiling).

## Workflow expectation

The user prefers action over planning, concise text output, honest
disagreement when their hypothesis is wrong, and no churn. Don't change
code that doesn't help. Validate-then-commit: make changes, ask the user
to run a smoke test, only commit after the run is clean.

## Status as of 2026-05-11

**Bastion bare-metal validation complete.** Driver loads, arms, samples
at period=50,000, and unloads cleanly. Both smoke runs (`microbench_alu`
and `microbench_ipc`) finish with `missed=0` and no oops/WARN. Per-PMI
overhead is ~2,000 cycles (4% of period) — comparable to adl, ~6×
cheaper than KVM. Sampler attribution is 99.86%+ for the workload PID.

CSVs are committed to `results/skl_microbench_alu.{csv,log}` and
`results/skl_microbench_ipc.{csv,log}` ... actually no, `results/*.csv`
is gitignored. Re-generate locally with the smoke commands above.

### Next experiments

- Drive `microbench_ipc` toward the architectural ceiling with an
  unrolled / AVX2 / wider-asm body — the current ~2.5 IPC is loop-overhead
  bound on Skylake-SP, not sampler-bound. Worth confirming we can hit
  closer to 4 IPC (4-wide retire) with a tighter kernel.
- Real workload sampling on bastion: pick a target program (e.g. SPEC
  CPU, a database hot loop) and verify the counter mix matches `perf
  stat` independently. Demonstrates the sampler at its intended use.
- Persist the VTune-driver-unload step. They auto-load via systemd at
  every boot; either mask the service or add the rmmod to
  `prepare_for_benchmarking.sh`.

### Deferred (still not blocking)

The "Known issues, deferred" section above stands. None of them block
ongoing measurements on bastion.

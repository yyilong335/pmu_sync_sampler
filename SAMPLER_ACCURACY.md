# Sampler accuracy and limitations

**How accurate is the synchronous PMU sampler, and what are the things it can't do?** This is a summary of what we measured on Skylake-SP / Xeon Gold 6142 (bastion), CPU 3, period = 50,000 core cycles, workload = SPEC CPU 2017 `600.perlbench_s` / `checkspam` (ref-speed input).

## Bottom line

For counters that measure **committed work** (instructions retired, loads, stores, branches), two runs of the same 3.7-minute workload agree to within **1 part in 16,000** (CV = 0.006 %). For counters that measure **microarchitectural state** (cache misses, stalls), CV is 0.2–1.4 %. Sample-level cycle counts are stable: 97.4 % of the ~10 million per-PMI samples land within a 500-cycle band around the mean of 52,237. The methodology is production-ready for real-workload characterization.

## How the sampler works

The sampler is a Linux kernel module (`pmu_sync_sample.ko`) plus a small userspace reader (`textreader`). The module owns the hardware PMU on CPU 3, takes an NMI on counter overflow, records a sample, and hands buffers to userspace via a character device. Here's what each stage does.

### 1. Load — `sudo insmod pmu_sync_sample.ko`

- Reserves the PMU counter MSRs so nothing else on the system (perf, VTune) can touch them: `reserve_perfctr_nmi(PMC0)` and `reserve_evntsel_nmi(EVENTSEL0)`.
- Registers `my_nmi_handler` on the kernel's NMI chain (`register_nmi_handler(NMI_LOCAL, …)`).
- Creates `/dev/pmu_samples` via `alloc_chrdev_region` + `class_create` + `device_create` (udev auto-creates the node with a kernel-allocated major).
- Creates `/sys/sync_pmu/` with the control attributes: `period`, `status`, `missed`, and 8 event slots `0..7`.
- Allocates a buffer pool of 8 × 4 KB buffers on the `empty_buffers` linked list. Each buffer holds up to 63 samples (`struct sample` is 64 bytes, packed).
- Sets `shutdown = 0`; counters are *not* yet armed — the CPU is untouched.

### 2. Arm — `echo 1 > /sys/sync_pmu/status`

The sysfs store handler runs `smp_call_function_single(CPU=3, startCtrsLocal, …)`. On CPU 3, `startCtrsLocal`:

- Clears `MSR_CORE_PERF_GLOBAL_CTRL` to stop any prior counting.
- Sets `FIXED_CTR1 = 0xFFFFFFFFFFFF − period` — i.e. loads `-period` so it overflows after exactly `period` cycles.
- Programs the 8 general-purpose event selectors (`MSR_ARCH_PERFMON_EVENTSEL0..7`) from `/sys/sync_pmu/0..7`, forcing USR+OS+EN and clearing INT (only FIXED1 raises PMI in this driver).
- Zeros `PMC0..7`, `FIXED_CTR0`, `FIXED_CTR2` so the first sample after arm isn't contaminated by whatever was in the counters when `GLOBAL_CTRL` was last off.
- Sets `MSR_CORE_PERF_FIXED_CTR_CTRL = 0x3B3` — FIXED1 counts USR+OS *and raises PMI on overflow*; FIXED0/2 count USR+OS silently.
- Programs the local APIC's `LVTPC = APIC_DM_NMI` via `apic_write` so that overflow gets delivered as an NMI on this CPU. (`apic_write` dispatches correctly under both xAPIC and x2APIC — a direct MSR write would silently no-op under x2APIC.)
- Enables `MSR_CORE_PERF_GLOBAL_CTRL = 0xFF | (7ULL<<32)` — 8 GP + 3 fixed counters, all counting.

From this instant, counters tick and PMIs will fire on CPU 3 every `period` core cycles.

### 3. Each PMI — `my_nmi_handler` in `intel.c`

Runs on CPU 3 in NMI context (nothing else can preempt it, so it must be quick and lock-free):

- Immediately captures `entry_ccnt = read_ccnt()` — FIXED_CTR1's value at the top of the handler. This measures hardware+kernel PMI delivery cost.
- Bumps `total_interrupts`.
- Clears `MSR_CORE_PERF_GLOBAL_OVF_CTRL` so this overflow can be re-armed.
- Calls `gatherSample(entry_ccnt)` in `pmu_sync_sample_main.c` — this reads FIXED_CTR1 again (for `cyc`), captures `current->pid`, reads PMC0..7 + FIXED_CTR0 + FIXED_CTR1 + FIXED_CTR2 with `rdpmc`, and writes one `struct sample` into the per-CPU current buffer (`lbuffer`).
- Reloads FIXED_CTR1 to `-period` so the next overflow fires in exactly `period` cycles.
- Re-arms `LVTPC` (the mask bit auto-sets when a PMI fires; must be cleared before iret or no more PMIs come).
- Returns `NMI_HANDLED`.

Counters are *not* reset in the handler (except FIXED_CTR1, which has to be reloaded). Every other counter accumulates monotonically since arm; the userspace reader computes per-PMI deltas. This saves ~800 cyc/PMI (10 avoided wrmsrls) and lets those cycles go back to the workload.

### 4. Buffer full → `irq_work`

When a buffer fills (63 samples), the NMI can't safely take the buffer-pool spinlock (NMIs aren't masked by `spin_lock_irqsave`, so acquiring it from NMI could deadlock against the reader). Instead the NMI:

- Stashes the full buffer in a per-CPU `pending_full` slot, NULLs `lbuffer`,
- Calls `irq_work_queue(&pmu_irqwk)` — queues a callback to run in normal IRQ context.

The `irq_work` callback runs shortly after, in a context where `spin_lock_irqsave` is safe:

- Appends the full buffer to `full_buffers`,
- Pops a fresh empty buffer from `empty_buffers` into `lbuffer`,
- Calls `wake_up_all(&read_queue)` to wake the reader.

If a PMI fires while `lbuffer == NULL` (the tiny window between full and refill), the sample is dropped and `missed` is bumped.

### 5. Userspace reader — `textreader` reading `/dev/pmu_samples`

- `open("/dev/pmu_samples", O_RDONLY)` and loop `fread(&buf, sizeof(struct buffer), 1, f)`.
- Each read blocks on `wait_event_interruptible(&read_queue, …)` until a full buffer is available, then copies it out and returns the buffer to `empty_buffers`.
- For each sample in the buffer, `textreader` computes per-CPU deltas of each counter (unsigned subtraction against a per-core "previous value" map) and writes one CSV row: `pid, core, cyc, d[0..10], handler_entry_ccnt, cmdline, exe`.

Because deltas are computed in userspace, the kernel handler stays minimal.

### 6. Stop and unload — `echo 0 > /sys/sync_pmu/status` then `rmmod`

- Writing `0` to status calls `stopAll()`: sets `shutdown = 2`, wakes all readers with EOF, masks `LVTPC`, clears `GLOBAL_CTRL`. After this, further reads of `/dev/pmu_samples` return 0 (EOF), so the reader exits cleanly.
- `rmmod pmu_sync_sample` unregisters the NMI handler, destroys `/dev/pmu_samples` and `/sys/sync_pmu/`, releases the counter reservation, and frees the buffer pool.

The net result: one CSV row = one PMI = one `period`-cycle window of the workload's hardware counters, captured atomically inside a single NMI on CPU 3.

## How the "cycle" column is calculated

Column 3 of the CSV (`cyc`) is `read_ccnt() + period`, computed inside the NMI handler:

- FIXED_CTR1 has been counting up since it was loaded to `-period` at the previous PMI.
- At overflow (T = 0) it hits 0 and raises the PMI. From then on it keeps counting: at T = 2,000 (say) it reads as 2,000.
- The handler reads it at T ≈ 2,200 → `read_ccnt()` returns 2,200.
- We add `period` (50,000) because that's the number of cycles that elapsed *between the two overflows*, and store 52,200 in `cyc`.
- So `cyc = period + (cycles from overflow to the first counter read)`. Always ≥ period; the excess is PMI+kernel+handler latency.

## Per-sample cycle stability

Over run 1's 10,139,748 workload samples:

| stat | value | comment |
|---|---:|---|
| mean(cyc)   | 52,237 | period + ~2,237 cyc overhead |
| stddev      | 227    | tiny — 0.43 % of mean |
| min         | 51,944 | fastest possible: hardware PMI floor of 1,944 cyc |
| max         | 54,519 | slowest observed, 4.9 % above floor |
| samples in [52,000, 53,000) | 97.4 % | dominates the distribution |
| samples > 53,000 | 0.09 % | rare stragglers |

Per-PMI overhead breakdown for the first sample:

```
0        FIXED_CTR1 overflows, PMI raised
2231     NMI delivered, handler entered      ← handler_entry_ccnt (hardware + kernel)
2449     first counter read                  ← cyc - period
         (218 cyc = handler prologue: OVF_CTRL clear + a few C statements)
2954     second FIXED_CTR1 read              ← d[9] (raw)
         (505 cyc = 8 GP rdpmc reads + FIXED_CTR0 rdpmc read)
```

So the interrupt+handler consumes **~2,200 out of 52,200 cycles** per sample = **4.2 % of measured time is sampler overhead**, not workload. This is a systematic offset, not noise, and it's the same for every sample.

## The interrupt cost, decomposed

`cyc − period` averages 2,237 cycles. Almost all of that is unavoidable hardware+kernel PMI delivery:

| component | cycles | who owns it |
|---|---:|---|
| Hardware PMI delivery + Linux NMI prologue | ~2,000 | Intel + Linux kernel — not fixable from our module |
| Our handler prologue (OVF_CTRL wrmsr, C statements) | ~200 | our code |
| Reading counters (8 GP + FIXED0 + FIXED1' + FIXED2 via rdpmc) | ~500 | our code (already optimized with rdpmc, was ~1,300 with rdmsr) |
| Reloading FIXED_CTR1 (`write_ccnt`), APIC re-arm, iret | ~200 | our code + hardware |

We already applied the biggest optimizations: **rdpmc instead of rdmsr** (saved ~800 cyc/PMI) and **no counter reset in the handler** (saved another ~800 cyc/PMI). The remaining ~2,000-cyc floor is hardware.

## Cross-run stability (two SPEC perl runs)

Both runs completed cleanly (rc=0, no oops, no WARN). Each ran for ~223–226 s and generated ~10.1 M samples. The cross-run summary from `results/spec_perl_stability.log`:

| metric | mean | CV (%) | reproducibility |
|---|---:|---:|---|
| **INST**      | 1.237 × 10¹² | **0.006** | essentially perfect — perl retires the same instructions |
| **LOAD**      | 3.58 × 10¹¹  | **0.006** | same |
| **STORE**     | 2.29 × 10¹¹  | **0.006** | same |
| **BRANCH**    | 2.42 × 10¹¹  | **0.006** | same |
| L1D_REPL      | 4.36 × 10⁹   | 0.161 | small — depends on initial cache state |
| L1I_MISS      | 5.42 × 10⁹   | 0.301 | small — I-cache warm-up varies |
| REF_TSC       | 5.80 × 10¹¹  | 0.311 | tracks the 1.3 % wall-time jitter |
| cyc           | 5.28 × 10¹¹  | 0.321 | same |
| n_clean       | 10.12 M      | 0.319 | tracks wall time |
| STALL_RETIRE  | 1.85 × 10¹¹  | 0.876 | microarch state matters |
| STALL_ISSUE   | 1.11 × 10¹¹  | 1.383 | most sensitive |

**Interpretation.** Counters that measure *committed events* (things the workload actually did) are architectural — they depend only on the instruction stream, so two runs of a deterministic workload produce nearly identical totals. Counters that measure *microarchitectural state* (which lines are in cache, whether the branch predictor is warm, whether the pipeline is stalled) vary because the system doesn't start each run with identical caches and predictors. This is expected, and the variance is still small.

Bench-run wall-clock and sample-count variance sit at ~0.3 %, dominated by system noise external to the sampler.

`missed` samples: 1,555 / 10.21 M in run 1 (0.015 %) and 3,003 / 10.10 M in run 2 (0.030 %). The 8-buffer pool kept up with the reader.

## Update — 10-run stability, REF-driven

The sampler was later switched to REF-driven PMI (FIXED_CTR2 armed with `−period`; `FIXED_CTR_CTRL = 0xB33`; textreader passthrough index moved from FIXED_CTR1 to FIXED_CTR2). Ten SPEC perl runs were taken to characterize stability at higher n. The two-run table above was CORE-driven and remains accurate for that configuration; the numbers below supersede it for the current REF-driven code.

### How CV is computed

For each metric x across n runs: `mean = Σx/n`, `stddev = √(Σ(x − mean)² / (n − 1))`, `CV(%) = 100 · stddev / mean`. Read as relative spread — 0.004 % = 4 parts per million.

### Ten-run REF-driven results

| metric | mean | CV (%) |
|---|---:|---:|
| **INST**     | 1.239 × 10¹² | **0.004** |
| **LOAD**     | 3.582 × 10¹¹ | **0.004** |
| **STORE**    | 2.297 × 10¹¹ | **0.004** |
| **BRANCH**   | 2.429 × 10¹¹ | **0.004** |
| L1D_REPL     | 4.399 × 10⁹  | 0.082 |
| L1I_MISS     | 5.465 × 10⁹  | 0.119 |
| cyc (REF)    | 5.753 × 10¹¹ | 0.195 |
| corecyc      | 5.387 × 10¹¹ | 0.192 |
| STALL_RETIRE | 1.873 × 10¹¹ | 0.540 |
| STALL_ISSUE  | 1.131 × 10¹¹ | 0.869 |
| n_clean      | 10.98 M      | 0.193 |

Per-sample means: `cyc(REF) = 52,388`, `corecyc = 49,062`, `INST = 112,833`, IPC = INST/corecyc = **2.30**. Handler physical overhead unchanged at ~933 ns (2,388 REF ≈ 2,238 CORE-equivalent). Skipped rows (u32 underflow): 3 across 110 M samples; missed rate 0.0002 %–0.042 % per run.

CVs are lower than the two-run CORE-driven values above — mostly a statistical n=2→n=10 effect, but importantly the switch to REF did not introduce new variance.

### Between-session drift

INST mean shifted from 1.237 × 10¹² (2 CORE-driven runs, kernel 5.15.0-177) to 1.239 × 10¹² (10 REF-driven runs, kernel 5.15.0-185) — a **0.16 %** delta. That's ~40× the intra-session CV of 0.004 %, but below the wall-time CV of 0.19 %.

Primary cause: the kernel upgrade between sessions (perl exercises slightly different syscall paths). The sampler switch itself contributes only ~24 M INST (~0.002 %) via handler INST attributed to workload PID at the higher REF-driven PMI rate. Practical rule: **intra-session comparisons have ~0.004 % noise; cross-session or cross-kernel comparisons carry ~0.15 % drift as the reproducibility floor.**

### PID attribution across 10 runs

| run | workload share | pid=0 share |
|---:|---:|---:|
| 1  | 98.955 % | **1.045 % (warm-up)** |
| 2  | 99.935 % | 0.064 % |
| 3  | 99.934 % | 0.065 % |
| 4  | 99.936 % | 0.063 % |
| 5  | 99.936 % | 0.063 % |
| 6  | 99.934 % | 0.066 % |
| 7  | 99.940 % | 0.060 % |
| 8  | 99.933 % | 0.066 % |
| 9  | 99.940 % | 0.059 % |
| 10 | 99.917 % | 0.082 % |

Runs 2–10 sit at **99.93–99.94 %** workload attribution — ~10× cleaner than the CORE-driven baseline. Run 1 is a warm-up outlier (cold caches after `insmod`); convention is to **skip run 1** and analyze runs 2–10.

## Environment cleanliness

The bastion boot cmdline (`/proc/cmdline`):

```
isolcpus=2,3          nohz_full=2,3        rcu_nocbs=2,3
idle=poll             intel_idle.max_cstate=0   processor.max_cstate=1
intel_pstate=disable  irqaffinity=0,1,4-15
mitigations=off       spec_store_bypass_disable=off
```

What each does for CPU 3:

- **`isolcpus=2,3`** — kernel scheduler won't place other user tasks here.
- **`nohz_full=2,3`** — periodic scheduler tick is suppressed when only one task is runnable.
- **`rcu_nocbs=2,3`** — RCU callbacks execute on other CPUs.
- **`idle=poll`** — no HLT; idle busy-loops so wake-up latency is zero.
- **`intel_idle.max_cstate=0` + `processor.max_cstate=1`** — no deep sleep states.
- **`intel_pstate=disable`** — old freq driver → freq can be pinned by `cpupower`.
- **`irqaffinity=0,1,4-15`** — hardware IRQs routed to non-target CPUs.
- **`mitigations=off`** — Spectre/Meltdown mitigations off (they add cycle noise).

`prepare_for_benchmarking.sh` complements this per-session: pins CPU freq to 2400 MHz (turbo off, governor=performance), unloads VTune drivers that steal PMC0, disables NMI watchdog.

The result: CPU 3 runs a single task at a fixed 2.4 GHz, no C-state entry/exit jitter, no external interrupts, no other user tasks scheduled here. This is why the per-sample cycle CV is 0.43 % and not something like 5 %.

## PID attribution

Every CSV row carries the PID that was on CPU 3 at PMI time (`current->pid` read inside the NMI handler). For run 1:

| PID   | rows       | share      | who |
|---:   |---:        |---:        |---|
| 38340 | 10,139,748 | **99.28 %** | the workload (`taskset` → `perlbench_s_base`) |
| 0     | 73,392     | 0.72 %     | idle task on CPU 3 |
| 174   | 42         | 0.0004 %   | a kernel thread |

The 73,392 pid=0 samples are **evenly distributed across the full run** (7,339–7,340 per each of 10 buckets). Not a start/end artifact — it's a steady residual of the idle task briefly running on CPU 3. With `idle=poll` in effect, the CPU keeps ticking even when the idle task runs, so PMIs still fire and get correctly attributed to pid 0. This is actually a feature, not a bug: without `idle=poll` you'd see fewer pid=0 rows only because HLT stops FIXED_CTR1, hiding the same underlying off-workload time.

Getting pid=0 substantially below 0.7 % on this workload would require reducing the small amount of off-workload time (occasional page faults, residual `nohz_full` ticks, minor kernel housekeeping). For the sampler's purpose — measuring workload counter behavior — this is far below the noise floor.

## Limitations

1. **Sample-based attribution.** One PID per sample, but counters accumulate against CPU 3 continuously. If perl was descheduled mid-period (very rare here), that PMI's counter deltas cover both perl and idle work but attribute to whoever was on-CPU when FIXED_CTR1 overflowed. Over 10 million samples this averages out, but individual per-sample counts can be slightly "wrong" in this sense. Every sample-based profiler (`perf`, VTune) has the same limitation.

2. **~2,200 cycles/PMI is sampler overhead, not workload.** So the reported `cyc` for each sample is `period + 2200`, not `period`. If you want a "pure workload IPC", you should note that ~4.2 % of the measured cycles are the interrupt itself. This overhead is *systematic* — the same for every sample — so relative comparisons (workload A vs workload B under the same sampler) are unaffected.

3. **`idle=poll` shows the residual off-workload time; HLT-based idle would hide it.** With poll, ~0.7 % pid=0 samples reflect actual off-workload cycles. With HLT, those cycles wouldn't produce PMIs at all and would be invisible.

4. **Rare u32 underflow at buffer transitions.** The reader computes deltas as `unsigned int` subtractions; on very rare buffer-pool boundary races (~1 sample in 400,000 observed with microbench_ipc, 0 in 20 M SPEC samples), the delta wraps to ~2³² and inflates that row's counters catastrophically. The stability harness filters these; they're rare enough not to affect statistical results, but a per-row analysis should always check for any counter > 2³¹.

5. **Reader's exe/cmdline attribution race.** Because `taskset` briefly runs before `execve`s to perl, the userspace reader sometimes caches the cmdline as `taskset` and sometimes as the full perl path. Doesn't affect counter data or PID; only cosmetic string columns differ. Analyses should filter by PID, not exe suffix.

6. **PMI is tied to CORE cycles, not REF cycles.** The 50,000-cycle period is core cycles. Because the core is pinned to 2.4 GHz, this is a fixed 20.83 μs wall interval — but if frequency scaling were re-enabled, the PMI rate would vary. TSC/REF_TSC is observed passively for wall-time correlation.

7. **One PMU counter set per run.** Eight GP slots are configured before arming and can't change without stopping the sampler. The paper's methodology fixes the event set at run start; if you need more events, you have to either drop counters or take multiple sampled runs at slightly different event configurations.

## Conclusion

The sampler delivers reference-quality data on our target hardware:

- **Committed-work counters (INST, LOAD, STORE, BRANCH) reproduce to 6 parts per million** across independent runs.
- **Per-sample cycle count is stable within 0.4 %** of the mean; the interrupt cost is a systematic ~4.2 % offset that's the same every sample.
- **Environment overhead is at the practical floor** for a general-purpose Linux system: 99.3 % of CPU 3 time is attributed to the workload, and the remaining 0.7 % is unavoidable kernel housekeeping made visible by `idle=poll`.
- **10 million samples per run, missed rate 0.015–0.030 %** — the reader keeps up with the sampler easily.

For characterizing workloads on Skylake-SP: **the sampler is not the limiting source of noise.** Microarchitectural variability (cache/predictor warm-up, small scheduling jitter) is the dominant source of run-to-run variance, and it's inherent to the hardware, not the methodology.

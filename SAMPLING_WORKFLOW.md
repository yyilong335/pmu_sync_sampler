# Sampling workflow — what happens around each PMI

Companion to [VM_TESTING.md](VM_TESTING.md). This doc answers
"where does the kernel module run, when do counters tick, and
what do `cyc` / `CPU_CLK_CORE` / `REF_TSC` actually measure" — and
identifies why no counter we read can equal `period` exactly.

## Where things run

- **Workload**: `taskset -c 3 ./benchmarks/microbench_mem` runs entirely on
  CPU 3 in user mode (Ring 3).
- **Kernel module**: only programs PMU MSRs on CPU 3
  (`smp_call_function_single(PMU_TARGET_CPU, …)` for arm/disarm).
  We register a single per-CPU NMI handler that returns
  `NMI_DONE` immediately on every other CPU.
- **NMI handler**: runs on whichever CPU got the PMI. We program
  `FIXED_CTR1` only on CPU 3, so only CPU 3's `LVTPC` ever fires
  the PMI, so the NMI handler always runs on CPU 3.

So: workload, sampler, and NMI all share CPU 3. The PMU only
counts CPU 3 events. There is no cross-core leakage.

## Does the handler add to the PMU counters? Yes, a small amount

GP slots are programmed with `USR=1, OS=1, EN=1` (forced by
[`pmn_config`](module/intel.c)), so every event the handler causes
is counted alongside the workload. Concretely:

- INST, LOAD, STORE, BRANCH: in the VM the handler executes
  ~30 instructions per period (mostly `rdmsrl` + bookkeeping);
  on bare metal ~10. Out of ~12,000 instructions per period this
  is < 0.3 % — ignorable.
- STALL_ISSUE / STALL_RETIRE: the handler is *mostly* stall
  cycles waiting on `rdmsrl` to return. In the VM it adds ~12 K
  stall cycles to the ~54 K we see per sample — visible but
  bounded. On bare metal it adds ~500.
- L1D_REPLACEMENT / L1I_MISS: handler code touches a few cache
  lines but it's the same lines every PMI, so they're hot in L1
  after the first few samples. Negligible contribution.

The workload is **paused** while the handler runs (NMI is
non-reentrant on x86). They are interleaved in time, never
concurrent. But the *counters keep ticking* through the handler —
that's the entire source of overcounting.

## Sequencing of one PMI (matches the original repository)

```
   ─── handler N exits ───┐                                   ┌─── handler N+1 starts
                          ▼                                   ▼
        … ┐ wrmsrl resets ┐ apic_write LVTPC ┐ IRET ╞═══════════════════════════════╡ vmexit ┐ kvm ┐ vmenter ┐ NMI gate ┐ do_nmi ┐ my_nmi_handler ┐ wrmsrl OVF_CTRL ┐ gatherSample ┐ ...
                                            │      │ ←── 50,000 unhalted core ──→ │
                                            │      │       cycles of period       │
                                            │      │       (workload running)     │
                                            │   counter values from here on are accumulated for sample N+1
                                                  ▲
                                                  └─ FIXED_CTR1 overflows here
                                                     → physical PMI raised
```

The NMI handler shape is taken verbatim from the original repo's
flow (just extended for the new fixed-counter sampling and the
NMI-safety irq_work refactor). We tried moving the
`wrmsrl(GLOBAL_OVF_CTRL)` out of the read-side path — the mean
dropped by ~1.2 K cycles but **per-sample variance was unchanged**,
so we kept the original ordering.

## What `cyc`, `CPU_CLK_CORE`, and `REF_TSC` actually measure

These three fields are **different MSRs read at different times**.
They are *not* equal — not in the VM, not on bare metal:

| Field | Hardware source | Reset point | Read point | What its value means |
|---|---|---|---|---|
| `cyc` (= `read_ccnt() + period`) | FIXED_CTR1 | `(overflow − period)` at end of handler N | **first** counter read in handler N+1 | `period + handler-entry-latency` |
| `CPU_CLK_CORE` (= `s->fixed[1]`) | FIXED_CTR1 (same MSR!) | same reset | **after** 8 GP `rdmsrl`s | "raw FIXED_CTR1" = handler-entry-latency + GP-read time |
| `REF_TSC` (= `s->fixed[2]`) | FIXED_CTR2 | `0` at end of handler N | **last** read in handler N+1 | handler-N tail + period + entire handler-N+1 prologue + 11 `rdmsrl`s |

So if `cyc ≈ 63,000`, `CPU_CLK_CORE ≈ 18,000`, `REF_TSC ≈ 69,000` —
they're all consistent: `cyc - period = 13,037` is the FIXED_CTR1
raw value at the *first* read, `CPU_CLK_CORE = 18,144` is the
*same MSR* re-read after 8 GP reads (so it's larger by the GP-read
time), and `REF_TSC` includes the entire period plus everything
the handler did up to the very last MSR read.

## And `cyc` is *not* 50,000 when the interrupt fires

The interrupt fires at the moment FIXED_CTR1 overflows; at that
exact instant raw FIXED_CTR1 = 0 and `cyc` doesn't exist (we
haven't run any code yet). `cyc` is computed *inside* the handler
after some entry latency:

```
cyc = read_ccnt() + period
    = handler-entry-latency-in-cycles + period
    ≈ 13,000 + 50,000  (in VM)
    ≈ 63,000
```

The "rule" is "fire the interrupt every 50,000 unhalted core
cycles," which is the period programmed into FIXED_CTR1's reset
offset. Everything we *read in software* comes after that, so
every cycle field is ≥ 50,000.

## Where the variance of `cyc` (and the rest) comes from

`cyc - period = read_ccnt()` = raw FIXED_CTR1 at the moment of
the first read = **the time from "PMI fires" to "first counter
read."** Every cycle of that path has its own jitter:

| Source | Magnitude (VM) | Variance contribution |
|---|---|---|
| **VMEXIT → KVM PMI inject → VMENTER** | ~6,000–9,000 | **~500–700 (dominant)** |
| NMI gate prologue + Linux `do_nmi` dispatch | ~700 | ~50 |
| smp_processor_id check + total_interrupts++ | ~50 | ~5 |
| `wrmsrl(GLOBAL_OVF_CTRL)` before gatherSample | ~500–2,000 | ~100–300 |
| gatherSample call setup, per_cpu access | ~300 | ~30 |
| → here `read_ccnt()` records the value into `cyc` | | |
| Eight `read_pmn(0..7)` (`rdmsrl`) | ~5,000 | ~100–200 |
| `read_fixed(0..2)` (`rdmsrl`) | ~1,500 | ~50–100 |
| → here `read_fixed(2)` records the value into `REF_TSC` | | |

`cyc` stdev ≈ 700, `REF_TSC` stdev ≈ 800 — REF is slightly noisier
because more `rdmsrl`s precede it. Both are dominated by the same
~500-cycle KVM PMI delivery jitter.

The dominant variance source — the VMEXIT/VMENTER round-trip — is
hypervisor code. **There is nothing the guest module can do to
shrink it.** That ~500-cycle stdev is the floor in the VM.

## What *would* show 50,000?

Nothing we can read from a counter ever shows exactly `period`,
because all reads happen after the overflow + handler entry. To
genuinely report "50,000 between PMIs" we would have to measure
the **inter-PMI interval** in software, by recording the TSC at
each handler entry and emitting the delta:

```
T_n      = TSC at handler N entry
T_(n+1)  = TSC at handler N+1 entry
delta    = T_(n+1) − T_n
         = period + (entry_latency_(n+1) − entry_latency_n)
         ≈ period   (the latency-difference is small if the path
                     is consistent, but it's not zero — the
                     variance is √2 × the per-sample entry jitter)
```

That requires per-CPU state (a `prev_tsc` we keep across samples)
and a new sample field — i.e. it changes the data shape. We
deliberately did not do this in this branch. **The simplest
honest answer is**: `period` itself is the 50,000. Hardware fires
the interrupt every 50,000 unhalted core cycles by construction,
and that's enforced by the FIXED_CTR1 reset offset. Counter
values reported in the sample are *always* "what the period plus
the handler latency looked like," not the period in isolation.

If you want to verify hardware really is firing every 50 K
cycles, the cleanest check is `total_interrupts` over a known
wall-clock window — if `total_interrupts × period` matches the
elapsed unhalted CPU time on CPU 3 (≈ wall time × 2.6 GHz on
this host), the rule is being honored.

### What stable looks like, by counter

| Field | VM mean (period=50K) | VM stdev | Bare-metal projection (turbo off) |
|---|---|---|---|
| `cyc` | ~63,000 | ~700 | ~50,200 ± ~50 |
| `CPU_CLK_CORE` (FIXED1 read late) | ~18,100 | ~700 | ~600 (cycles-since-overflow at the late read point) |
| `REF_TSC` (FIXED2 read last) | ~69,200 | ~800 | ~50,200 ± ~50 |

On bare metal there is no VMEXIT and the entire variance budget
is the hardware NMI gate (~50 cycles) plus a few `rdmsrl` (a few
cycles each). Expected `cyc` and `REF_TSC` stdev: tens of cycles,
with mean within ~500 of `period`. The bare-metal migration is
where "ref-cycle ≈ 50,000" becomes physically true.

## Summary for the bare-metal migration

- The kernel module's behavior on CPU 3 is the same with or
  without a hypervisor — same MSR programming, same NMI handler,
  same ordering as the original repository.
- Per-sample sanity checks all hold (STALL ≤ cyc, LOAD+STORE+
  BRANCH ≤ INST, GP7 = 0, etc.) — see VM_TESTING for the audit.
- Mean values for cycle-tied counters in the VM are inflated by
  the ~13 K-cycle KVM PMI overhead. On bare metal, expect them
  to collapse close to `period`.
- Per-sample variance in the VM is ~700 cycles for cycle
  counters, dominated by VMEXIT timing. Bare metal: ~50.

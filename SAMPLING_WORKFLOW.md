# Sampling workflow — what happens around each PMI

Companion to [VM_TESTING.md](VM_TESTING.md). This doc answers
"where does the kernel module run, when do counters tick, and
what do `cyc` / `CPU_CLK_CORE` / `REF_TSC` actually measure" — and
identifies the small piece of overcounting baked into the design.

## Where things run

- **Workload**: `taskset -c 3 ./microbench_mem` runs entirely on
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
  cycles waiting on `rdmsrl` to return. In the VM it adds ~12K
  stall cycles to the ~54K we see per sample — visible but
  bounded. On bare metal it adds ~500.
- L1D_REPLACEMENT / L1I_MISS: handler code touches a few
  cache lines but it's the same lines every PMI, so they're
  hot in L1 after the first few samples. Negligible
  contribution.

The workload is **paused** while the handler runs (NMI is
non-reentrant on x86). They are interleaved in time, never
concurrent. But the *counters keep ticking* through the handler —
that's the entire source of overcounting.

## Sequencing of one PMI

```
   ─── handler N exits ───┐                                   ┌─── handler N+1 starts
                          ▼                                   ▼
        … ┐ wrmsrl reset ┐ apic_write LVTPC ┐ IRET ╞═══════════════════════════════╡ vmexit ┐ kvm ┐ vmenter ┐ NMI gate ┐ do_nmi ┐ my_nmi_handler ┐ gatherSample ┐ ...
                                            │      │ ←── 50,000 unhalted core ──→ │
                                            │      │       cycles of period       │
                                            │      │       (workload running)     │
                                            │   counter values from here on are accumulated for sample N+1
                                                  ▲
                                                  └─ FIXED_CTR1 overflows here
                                                     → physical PMI raised
```

By hardware construction, the time from "FIXED_CTR1 reset" in
handler N to "FIXED_CTR1 overflow" is *exactly* `period = 50,000`
unhalted core cycles. The interrupt fires at the moment of
overflow. After that, the handler runs with some entry latency
before any counter is read.

## What `cyc`, `CPU_CLK_CORE`, and `REF_TSC` actually measure

These three fields are **different MSRs read at different times**.
They are *not* equal — not in the VM, not on bare metal:

| Field | Hardware source | Reset point | Read point | What its value means |
|---|---|---|---|---|
| `cyc` (= `read_ccnt() + period`) | FIXED_CTR1 | `(overflow − period)` at end of handler N | **first** counter read in handler N+1 | period + handler entry latency |
| `CPU_CLK_CORE` (= `s->fixed[1]`) | FIXED_CTR1 (same MSR!) | same reset | **after** 8 GP `rdmsrl`s | "raw FIXED_CTR1" = handler entry latency + GP-read time |
| `REF_TSC` (= `s->fixed[2]`) | FIXED_CTR2 | `0` at end of handler N | **last** read in handler N+1 | handler-N tail + period + entire handler-N+1 prologue + 11 `rdmsrl`s |

So if `cyc ≈ 62,000`, `CPU_CLK_CORE ≈ 17,000`, `REF_TSC ≈ 68,000` —
they're all consistent: `cyc - period = 12,031` is the FIXED_CTR1
raw value at the *first* read, `CPU_CLK_CORE = 17,122` is the
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

## Where the variance of REF_TSC comes from

`REF_TSC = handler-N tail + period + handler-N+1 entry path up to
read_fixed(2)`. The period contributes **zero** variance (by
hardware construction). Everything else does:

| Source | Magnitude (VM) | Variance contribution |
|---|---|---|
| Handler N tail (after FIXED_CTR2 reset) | ~few hundred cycles | ~50 |
| **VMEXIT → KVM PMI inject → VMENTER on PMI delivery** | ~6,000–9,000 | **~500–700 (dominant)** |
| NMI gate prologue + Linux `do_nmi` dispatch | ~700 | ~50 |
| Our handler prologue (incl. any in-handler `wrmsrl`) | ~500–2,000 | ~100–300 |
| 8 `read_pmn` + `read_fixed(0/1)` ahead of `read_fixed(2)` | ~5,000 | ~100–200 |

**The VMEXIT/VMENTER path is the dominant source.** It's
hypervisor code we cannot influence from the guest. That ~500-cycle
stdev is the floor.

### What we changed to reduce the variance / mean

There was a `wrmsrl(MSR_CORE_PERF_GLOBAL_OVF_CTRL, ...)` *before*
`gatherSample()` that cleared the overflow flags. Per Intel's
PMI flow, the flag clear only needs to happen before LVTPC is
re-armed, not before reading counters. Moving it past the reads
removes one variable-cost wrmsrl from the path leading to
`read_fixed(2)`. Measured impact (5 runs, 21,751 samples each,
period=50,000):

| Field | Before (wrmsrl before reads) | After (wrmsrl after reads) | Δ |
|---|---|---|---|
| `cyc` mean | 63,081 | 62,031 | **−1,050** |
| `cyc` stdev | 667 | 685 | ≈0 |
| `CPU_CLK_CORE` mean | 18,219 | 17,122 | **−1,097** |
| `CPU_CLK_CORE` stdev | 693 | 710 | ≈0 |
| `REF_TSC` mean | 69,286 | 68,024 | **−1,262** |
| `REF_TSC` stdev | 777 | 785 | ≈0 |

The means dropped by ~1.2 K cycles (the `wrmsrl(OVF_CTRL)` cost
itself), bringing every cycle field a little closer to `period`.
**Variance is unchanged**, confirming our model: in the VM, the
variance floor is KVM's PMI delivery jitter, not the handler's
internal ordering.

We tried earlier reordering `gatherSample` to read fixed counters
before GP counters (read REF_TSC 8 MSRs earlier). Same result:
mean shifts but variance is unchanged. We left the read order
matching the original gatherSample shape — it's not the lever
that controls variance.

### What stable looks like, by counter

| Field | VM mean | VM stdev | Bare-metal projection (turbo off, prep script applied) |
|---|---|---|---|
| `cyc` | ~62,000 | ~700 | ~50,200 ± 50 |
| `CPU_CLK_CORE` (FIXED1 read late) | ~17,100 | ~700 | ~600 (period-only delta from FIXED1 reset) |
| `REF_TSC` (FIXED2 read last) | ~68,000 | ~800 | ~50,200 ± 50 |

For "is the sampler firing every 50,000 cycles?" the cleanest
answer is `cyc - period` — the *raw* `read_ccnt()` value, which is
the cycles between FIXED_CTR1 overflow and the very first counter
read of the handler. In the VM that's stably ~12,000 (= the KVM
PMI delivery cost). On bare metal it becomes ~200–500.

### Why the variance can't be reduced further inside the module

The smallest variance you could achieve, even with the most
aggressive in-handler reordering, would be the per-sample VMEXIT
jitter alone — about ±500 cycles in the VM. That's already what
we observe. Anything further would require either:

- the host hypervisor to respond to PMI more deterministically
  (out of scope; KVM's PMI path is what it is), or
- skipping the VM entirely.

On bare metal there is no VMEXIT and the entire variance budget
is the hardware NMI gate (~50 cycles) plus a few `rdmsrl` (a few
cycles each). Expected REF_TSC stdev: tens of cycles, with mean
within ~500 of the period.

## Summary for the bare-metal migration

- The kernel module's behavior on CPU 3 is the same with or
  without a hypervisor — same MSR programming, same NMI handler.
- Per-sample sanity checks all hold (STALL ≤ cyc, LOAD+STORE+
  BRANCH ≤ INST, GP7 = 0, etc.) — see VM_TESTING for the audit.
- Mean values for cycle-tied counters in VM are inflated by the
  ~12 K cycle KVM PMI overhead. On bare metal, expect them to
  collapse to ~50,200 ± small.
- Per-sample variance in VM is ~700 cycles for cycle counters,
  dominated by VMEXIT timing. Bare metal: ~50.

# Sampling workflow — what happens around each PMI

Companion to [VM_TESTING.md](VM_TESTING.md). This doc answers "where
does the kernel module run, when do counters tick, and what do
`cyc` / `CPU_CLK_CORE` / `REF_TSC` actually measure" — and
identifies the small piece of overcounting baked into the design.

## Where things run

- **Workload**: `taskset -c 3 ./microbench_mem` runs entirely on
  CPU 3 in user mode (Ring 3).
- **Kernel module**: only programs PMU MSRs on CPU 3
  (`smp_call_function_single(PMU_TARGET_CPU, …)` for arm/disarm),
  and registers a *single* per-CPU NMI handler. The NMI handler
  returns `NMI_DONE` immediately on any other CPU, so only CPU 3
  ever does PMU work.
- **NMI handler**: runs on whichever CPU got the PMI. We program
  `FIXED_CTR1` only on CPU 3, so only CPU 3's `LVTPC` ever fires
  the PMI, so the NMI handler always runs on CPU 3.

So: workload, sampler, and NMI all share CPU 3. The PMU only
counts CPU 3 events. There is no cross-core leakage.

## What the counters are configured to count

Slot configuration ([events.conf](events.conf)) writes
`USR=1, OS=1, EN=1` (forced by [pmn_config](module/intel.c)). So
every GP counter counts events that occur in **both user mode and
kernel mode** while CPU 3 is unhalted. The fixed counters are
similarly OS+USR (`FIXED_CTR_CTRL = 0x3B3`).

Two consequences:

1. While the workload runs, every retired load/store/branch the
   workload performs is counted ✓.
2. **While the NMI handler runs, every load/store/branch the
   handler performs is *also* counted.** The handler is just code
   running on CPU 3 — the PMU doesn't know whose code it is.

## Sequencing of one PMI

```
   ─── handler N exits ───┐                                   ┌─── handler N+1 starts
                          ▼                                   ▼
        … ┐ wrmsrl ┐ wrmsrl ┐ apic_write ┐ IRET ╞═══════════════════════════════╡ vmexit ┐ kvm ┐ vmenter ┐ NMI gate ┐ do_nmi ┐ my_nmi_handler ┐ wrmsrl ┐ gatherSample ┐ ...
          │ reset  │ reset  │            │      │ ←── ~50,000 unhalted core ──→ │
          │ FIXED1 │ FIXED2 │            │      │       cycles of period         │
          │        │ to 0   │            │      │       (workload running)       │
          │   counter values from here on are accumulated for sample N+1
                                                  ▲
                                                  └─ FIXED_CTR1 overflows here
                                                     → physical PMI raised
```

Counters tick continuously the whole time except during the
narrow window between the resets and the next overflow. Concretely:

- `FIXED_CTR1` (cycles) is reset to `(0xFFFFFFFFFFFF − period)` at
  the end of handler N. From there it counts every unhalted core
  cycle until it overflows at exactly `0` — that's the next PMI.
  By construction, the elapsed unhalted core cycles between
  successive PMIs is *exactly* `period = 50,000`.
- `FIXED_CTR0` (instructions), `FIXED_CTR2` (REF_TSC), and
  `PERFCTR0..7` (GP) are all reset to `0` at the end of handler N.
  They start counting from 0 *before* the next period begins (i.e.
  during handler N's tail) and continue counting throughout
  the period and into handler N+1, until each one is read.

## Does the handler add to the counters? Yes, a small amount

While handler N+1 is running, all enabled counters are still
counting. Anything the handler does (MSR reads, register pushes,
branches, etc.) gets folded into sample N+1's counter values.

Concretely, sample N+1's `LOAD` count includes:
- ≈ 50,000 cycles of workload execution: ~thousands of loads
- handler N's tail (a few wrmsrls + apic_write): a handful of loads
- handler N+1's prologue + the `rdmsrl`s before LOAD is read:
  ~10–20 loads in kernel context

In the VM, the handler is ~12,000 cycles long but executes only
~30 instructions (most of those cycles are the CPU stalled waiting
on `rdmsrl`/VMEXITs). So handler-attributable instruction events
are `O(30)` out of ~12,000 retired in a 50,000-cycle period —
under 0.3 %. On bare metal the handler is ~500 cycles total,
~10–15 instructions, ~0.1 % of the period — also negligible.

The exception is `STALL_ISSUE` / `STALL_RETIRE`: the handler's
many `rdmsrl`s are themselves stall cycles. Of the ~13K cycles
the handler spends in the period window (period + entry latency),
nearly all of those are stalls, contributing ~13K to the stall
count of every sample. That's why we see `STALL_ISSUE/cyc ≈ 0.85`
even for a chase loop that's already ~95 % stall-bound — the
handler's own stalls dominate the remainder.

We don't subtract this out. It would require either a control-only
sampling pass or per-CPU instrumentation of the handler itself —
either way significantly more code, and the overcounting is
small enough on bare metal to ignore.

## Is the workload running while the NMI handler runs?

**No.** The CPU executes one stream at a time. When the PMI
arrives, the CPU saves the current context, jumps to the NMI gate,
and runs the handler. The workload is paused during this time. NMI
is non-reentrant on x86 — once one is being serviced, the CPU
masks further NMIs until `IRET` is executed.

So there is no concurrent workload-vs-handler running. There IS,
however, the fact that the counters keep ticking through the
handler — that's the overcounting source.

## `cyc` vs `CPU_CLK_CORE` vs `REF_TSC`

All three measure cycles, but at different read points:

| Field | What it is | Where we read it | Driven by |
|---|---|---|---|
| `s->cycles` (`cyc`) | Computed: `read_ccnt() + period` | First counter read in the handler | FIXED_CTR1 |
| `s->fixed[1]` (`CPU_CLK_CORE`) | Same MSR (FIXED_CTR1) read again, later | After GP reads (in current code) | FIXED_CTR1 |
| `s->fixed[2]` (`REF_TSC`) | TSC ticks since last reset | Read in `read_fixed(2)` | FIXED_CTR2 |

**`cyc`** is anchored to the overflow itself. `read_ccnt()` returns
"core cycles since `FIXED_CTR1` overflowed" — i.e. handler entry
latency expressed in cycles. We add `period` so the field reads
"approximate elapsed cycles between successive PMIs." It always
satisfies `cyc ≥ period` by construction.

**`CPU_CLK_CORE`** is the SAME hardware counter as `cyc`, just
read a few hundred cycles later in the handler. It's always
≥ `cyc - period`, and it's always a *bit* larger than `cyc - period`
because of the extra MSR reads between the two reads.

**`REF_TSC`** is a different counter — it ticks at TSC rate (= core
base frequency on Skylake, regardless of P-state). With turbo off,
core rate = TSC rate, so on bare metal `REF_TSC ≈ FIXED_CTR1` (in
unhalted cycles). In a KVM guest, however, **TSC ticks during the
VMEXIT/VMENTER round-trip even though `FIXED_CTR1` does not** —
the guest's CORE counter is paused while the hypervisor is
running, but the guest's TSC counter is just `host_TSC + offset`,
so it advances continuously. That's why we see
`REF_TSC > CPU_CLK_CORE > cyc` in the VM, with the gap
`REF_TSC - cyc` being the wall-clock VMEXIT/VMENTER cost in TSC
ticks.

On bare metal: no VMEXIT, so `REF_TSC ≈ cyc ≈ period + small
handler latency`. With period=50,000 and a ~500-cycle handler,
expect all three fields to report ~50,500 — to within tens of
cycles.

## Why does REF_TSC vary per-sample (range ~9,000 in the VM)?

In the VM, the dominant source is **KVM PMI-delivery jitter**: each
PMI is delivered via VMEXIT → KVM injection → VMENTER, and that
round-trip takes a variable number of host cycles depending on
host scheduling, TLB/cache state, what other vCPUs are doing, etc.
Per-PMI variance of ~500–1,000 cycles is normal and bounded only
by the hypervisor's behavior — there's nothing the guest module
can do about it.

We tried reordering `gatherSample` to read the fixed counters
*before* the GP counters (theory: REF_TSC read 8 MSR-loads earlier
→ less accumulated jitter). Measured outcome:

| Read order | REF_TSC per-sample stdev | mean | range |
|---|---|---|---|
| Original (REF read 11th in handler) | 777 | 69,286 | 9,152 |
| Reordered (REF read 3rd in handler) | 769 | 64,569 | 8,840 |

Per-sample variance is essentially the same (within sample-size
noise) — the VMEXIT jitter dominates regardless of where in the
handler we read. The reorder *does* lower the mean by ~5 K
(closer to `period`), but the user's primary ask is stability,
not absolute offset. We **kept the original order** to stay as
close to the upstream gatherSample as possible. On bare metal:
no VMEXIT, no KVM injection — REF_TSC variance drops to tens of
cycles regardless of read order, and mean lands at
`period + handler-entry-cycles ≈ 50,200`.

### What stable looks like, by counter

| Field | Cross-run mean (VM) | Per-sample stdev (VM) | Bare-metal projection |
|---|---|---|---|
| `cyc` (`read_ccnt()` + period) | ~63,000 | ~700 | ~50,200 ± 50 |
| `CPU_CLK_CORE` (FIXED1 read late) | ~18,100 | ~700 | ~600 (period-only delta) |
| `REF_TSC` (FIXED2 read last) | ~69,200 | ~770 | ~50,200 ± 50 |

For "is the sampler firing every 50,000 cycles?" the cleanest
answer is `cyc - period` (the *raw* `read_ccnt()` value): it's
the cycles between FIXED1 overflow and the very first counter
read of the handler, with the smallest possible MSR-read pile-up
in front of it. In the VM that's stably ~13,000 (= the KVM PMI
delivery cost). On bare metal that becomes ~200–500.

# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

# Project context: pmu_sync_sampler

A Linux kernel module for synchronous PMU sampling. Read [`README.md`](README.md) for the architecture, quick-start, and file map; [`ONBOARDING.md`](ONBOARDING.md) for cross-machine session handoff (recent commit history, verified IPC baselines, deferred known issues). This section is the minimum a new agent needs to make correct decisions about *which* changes to attempt.

## Hardware and target configuration

- **Production target**: bastion bare metal — Linux 5.15 / Intel Xeon Gold 6142 (Skylake-SP, SMT off, 8 GP + 3 fixed PMU counters).
- **CPU**: only CPU 3. The module fires PMIs only on CPU 3 (`PMU_TARGET_CPU` in [`module/pmu_api.h`](module/pmu_api.h)). The user's workload is `taskset -c 3 ./prog`. Don't make this multi-CPU without an explicit ask — the all-CPU code path was removed for a reason (deadlock under contention).
- **Period**: always **50,000** core cycles. Don't sweep periods. Don't propose 1M as a "safety ramp." Test directly at 50,000.
- **Test surface**: a KVM guest with `--cpu host-passthrough` for safety. Bare-metal validation is the next step the user is preparing for.

## Branches

- **`kernel-5.15`** is the active branch. All current work goes here.
- **`master`** carries Subtasks 0/1/2 + the original code. The user has said "I should not have committed anything in the master branch — please just keep it original." **Do not push to master without explicit approval.**
- The branch is normally a few commits ahead of origin. Run `git fetch origin && git status` before claiming a delta — don't trust stale state from earlier in a conversation.

## Subtask status (all done)

1. Linux 5.15 modernization (NMI API, sysfs, `module_init`).
2. udev-managed `/dev/pmu_samples`.
3. Sample 8 GP + 3 fixed counters per PMI.
4. Paper-style verification at period=50,000.
0. NMI/spinlock deadlock fix via `irq_work` (this was the bug that originally hard-locked bastion).

Plus latent bugs found and fixed during VM testing: x2APIC `LVTPC` programming via `apic_write`, first-sample contamination via missing counter resets in `startCtrsLocal`, sample-struct alignment via `__attribute__((packed))`.

## What NOT to change without an explicit ask

- **NMI-handler MSR ordering in [`module/intel.c`](module/intel.c)** must match the original repo. We tried reordering for variance reduction; it didn't help and was reverted. The handler shape — `OVF_CTRL` clear, `gatherSample`, FIXED_CTR1 reset, GP/FIXED resets, LVTPC re-arm — is fixed.
- **`gatherSample` read order in [`module/pmu_sync_sample_main.c`](module/pmu_sync_sample_main.c)** — `read_ccnt`, then GP loop, then fixed loop. Same reasoning.
- **Buffer pool size, sample struct layout, sysfs interface, char-device behavior** — stable, downstream tools depend on them.

## Known issues, not blocking bare-metal validation

- **Latent `lbuffer == NULL` recovery hole**: if a reader stalls long enough to drain the 8-buffer pool (~10 ms at period=50,000), `gatherSample` on `b == NULL` only bumps `missed` and doesn't queue `irq_work`; buffers freed back to the pool by a subsequent read can't get picked up until something else queues `irq_work`. Tight readers (`textreader`, `sender`) never trigger this. One-line fix exists; intentionally left out to keep the diff minimal.
- **`stopAll()` clobbers global PMU state on every CPU at `rmmod`**: writes `MSR_CORE_PERF_GLOBAL_CTRL = 0` and masks `LVTPC` system-wide. Doesn't crash; just steals counters from any other PMU user. Defer.
- **`sender/` and `reader/` wire formats encode 6 counters**, will silently truncate the 8 GP + 3 fixed sample. `textreader` is the reference reader.

## Variance / counter semantics (so you don't re-derive these)

- `cyc = read_ccnt() + period`. `read_ccnt()` is FIXED_CTR1's raw value at the *first* counter read in the handler — i.e. cycles since FIXED_CTR1's overflow = handler entry latency. So `cyc ≥ period` always, with `cyc - period ≈ 13,000` in VM (KVM PMI delivery cost) and ≈ 200–500 on bare metal.
- `s->fixed[1]` (CPU_CLK_CORE) is the *same MSR* as `cyc - period`, just read later in the handler. It will be ~5,000 cycles larger than `cyc - period` because of intervening GP `rdmsrl`s.
- `s->fixed[2]` (REF_TSC) is FIXED_CTR2 = TSC ticks. Reset to 0 in the previous handler. Spans the full handler-N tail + period + handler-N+1 prologue. In the VM it includes VMEXIT TSC time that CORE doesn't, so REF_TSC > CPU_CLK_CORE. On bare metal the two converge.
- Per-sample variance in the VM is dominated by KVM's PMI delivery jitter (~500-cycle floor). Nothing inside the module can shrink it. On bare metal: tens of cycles. Don't propose in-handler reorders to "improve variance" — that experiment was already done and disproved.
- See [`SAMPLING_WORKFLOW.md`](SAMPLING_WORKFLOW.md) for the full analysis.

## Style and conventions

- Kernel C: tabs, `if (x) {` on the same line, snake_case names. Match what's in `intel.c` / `pmu_sync_sample_main.c`.
- Comments only when WHY is non-obvious (hardware quirks, KVM artifacts, hidden constraints). The packed-struct comment in [`module/sample_buffer.h`](module/sample_buffer.h) is a model.
- The user is an Intel-PMU researcher, not a kernel hacker. Frame explanations in terms of MSRs and counter semantics, not in terms of generic kernel internals.

## Test infrastructure (per-machine, not in git)

The VM testing artifacts on the original development machine live in `/var/tmp/$USER-pmu-vm/` (libvirt staging, cloud-init seed, SSH keys). On a fresh machine these don't exist — set up a new VM following [`VM_TESTING.md`](VM_TESTING.md) "Setup recipe — VM from scratch", or skip straight to bare metal now that the unsafe paths are fixed.

Local-only artifacts that aren't in git (gitignored):
- `results/*.csv`, `results/*.txt` — verification CSV dumps and summaries
- `preflight.log`, `preflight_dmesg.txt` — most-recent preflight stress-test output
- `benchmarks/microbench`, `benchmarks/microbench_mem`, `benchmarks/microbench_alu`, `textreader` (binaries)
- `plans/` (local working notes)

## Workflow expectation

The user prefers:
- **Action over planning** in auto mode (Bash, Edit, etc. directly).
- **Concise text output**: brief progress updates, results, decisions.
- **Honest disagreement** when their hypothesis is wrong (e.g. "REF_TSC should be 50,000" — explain that no counter we read can equal `period` exactly).
- **No churn**: don't change code that doesn't help. The /simplify review showed several "could refactor" findings we deliberately skipped because they preserve original-repo structure.

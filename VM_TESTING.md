# VM-based execution plan for Subtasks 0 / 2 / 3 / 4

## Why this document exists

The first attempt to run this module on the modern host (Linux 5.15, Xeon Gold
6142, SMT off) hard-locked the machine. The latent NMI/spinlock deadlock
documented in [README.md](README.md#-known-crash-risk--do-not-load-on-shared-infrastructure)
is consistent with that crash. From here, all kernel work happens inside a
throwaway KVM guest so a deadlock costs only `virsh destroy`, not a
power-cycle.

This plan covers VM provisioning and a staged, risk-ascending execution of the
four kernel-side subtasks. Code-level diffs for Subtasks 2 / 3 / 4 are sketched
in the README's "Status & known issues" section; this doc adds **Subtask 0**
(the NMI/spinlock fix) which the README flags as a prerequisite to safe use
but does not design.

Two decisions captured up front:
1. Fix the NMI/spinlock deadlock as **Subtask 0** before running Subtask 4 at
   the paper's 50,000-cycle period. Doing it inside the VM is safe and is also
   the prerequisite to ever returning to bare metal.
2. Get the source into the guest by `git clone` from inside the guest
   (no virtfs / 9p share).

---

## Execution status

What has actually been done / what's outstanding, kept current as work
proceeds. This section is the source of truth on progress; the rest of the
document is the recipe.

| Stage | What | State |
|---|---|---|
| Phase A–D | Host prep, VM provisioning, snapshot of clean built guest | ✓ done |
| Stage 1 | Smoke insmod / rmmod, no sampling | ✓ done |
| Stage 2 / Subtask 2 | udev cdev replaces hardcoded major 222 | ✓ done, committed |
| Pre-existing bug | `native_apic_mem_write` silently no-ops under x2APIC; PMI never reached the NMI vector. Three call sites in `module/intel.c` switched to mode-agnostic `apic_write()`. | ✓ patched in working tree |
| Stage 3 / Subtask 0 | irq_work-based NMI safety: NMI handler is now lock-free; buffer hand-off and `wake_up_all` deferred to per-CPU `irq_work` callback | code written; **insmod, status transitions, and short bursts of sampling at periods 10ms → 50µs are all clean (no oops, `missed=0`, no lockup), but a sustained `dd` read on `/dev/pmu_samples` while sampling at period=50000 deadlocked all 4 vCPUs.** Snapshot revert recovered. Root cause unidentified. |
| Stage 4 / Subtask 3 | Expand to 8 GP + 3 fixed counters | not started |
| Stage 5 / Subtask 4 | 50 000-cycle paper verification | not started |

**Snapshots in libvirt:**
- `clean-build` — toolchain installed, repo built, no insmod yet.
- `post-subtask2` — Subtask 2 verified.
*(`post-subtask0` is intentionally not yet created — gated on resolving the
read-path hang.)*

**Open follow-ups:**
1. Diagnose the `dd`-induced lockup in Subtask 0. Working hypotheses:
   (a) `irq_work_queue` from NMI is racing with `my_read`'s
   `wait_event_interruptible` re-evaluation; (b) under high PMI rate, LVTPC
   re-arm via `apic_write` in `my_nmi_handler` causes the next overflow's
   pending PMI to fire before the handler fully returns, starving `irq_work`
   delivery; (c) `wake_up_all` from `irq_work` callback contends with
   `my_read`'s wait-queue lock in a way that traps under load. Next step:
   instrument `pmu_irq_work_fn` with `printk_once` per CPU and re-run with
   period=1 ms (1000 PMI/s) and `dd` reading; that should stay below the
   pile-up rate while still exercising the read path.
2. The `stopAll()` global-PMU clobber (README issue #2) — out of scope until
   the read-path hang is resolved.

---

## Phase A — Host preparation (one-time)

Goal: confirm the host can run a KVM guest with PMU passthrough, install the
libvirt stack.

```bash
# Verify CPU virtualization extensions
grep -Ec '(vmx|svm)' /proc/cpuinfo     # > 0 expected
lsmod | grep -E '^kvm'                 # kvm_intel or kvm_amd loaded
ls /dev/kvm                            # exists

# Confirm host is not itself a VM, or that nested virt is enabled
systemd-detect-virt                    # 'none' on bare metal
cat /sys/module/kvm_intel/parameters/nested 2>/dev/null   # Y if nested

# Install libvirt + tooling
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
                    virtinst cloud-image-utils virt-manager bridge-utils
sudo usermod -aG libvirt,kvm $USER
# log out/back in for group membership to apply
id | grep -E 'kvm|libvirt'             # both present
python3 -c "open('/dev/kvm','rb').close()" && echo "kvm readable"
virsh -c qemu:///system list --all     # libvirtd reachable
```

**Common gotcha — KVM acceleration silently unavailable.** If `virt-install`
prints `WARNING  KVM acceleration not available, using 'qemu'`, you've fallen
back to TCG software emulation. **TCG does not faithfully model the
architectural PMU MSRs this module reads — your VM testing is meaningless
in that mode.** Almost always caused by missing `kvm` group membership; fix
that first.

## Phase B — Provision the guest (cloud-image + cloud-init)

Goal: a 4-vCPU Ubuntu guest with `host-passthrough` so the architectural PMU
is exposed.

> The legacy `--location http://archive.ubuntu.com/ubuntu/dists/jammy/main/installer-amd64/`
> path no longer has a bootable kernel/initrd — Ubuntu's server installer is
> Subiquity now. Use the cloud image flow below instead.

```bash
mkdir -p ~/vm && cd ~/vm

# 1. Download the cloud image (jammy = 22.04, noble = 24.04)
DIST=jammy   # or noble
wget -O ${DIST}-cloudimg.qcow2 \
  https://cloud-images.ubuntu.com/${DIST}/current/${DIST}-server-cloudimg-amd64.img
qemu-img resize ${DIST}-cloudimg.qcow2 +13G

# 2. Build a cloud-init seed: user, SSH password, packages
cat > user-data <<'EOF'
#cloud-config
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

# 3. Launch via libvirt system mode (NAT bridge → routable from host)
virt-install \
  --connect qemu:///system \
  --name pmu-test --memory 4096 --vcpus 4 \
  --cpu host-passthrough,topology.sockets=1,topology.cores=4,topology.threads=1 \
  --disk path=$HOME/vm/${DIST}-cloudimg.qcow2,format=qcow2,bus=virtio \
  --disk path=$HOME/vm/seed.iso,device=cdrom \
  --import --os-variant ubuntu22.04 \
  --network network=default,model=virtio \
  --graphics none --noautoconsole

# 4. Find the guest IP and SSH in
virsh -c qemu:///system domifaddr pmu-test     # wait ~30s for cloud-init
ssh ubuntu@<ip>                                 # password: ubuntu
```

Inside the guest, confirm the PMU was passed through:

```bash
dmesg | grep -i 'perf\|pmu' | head -20
# Expect: "Performance Events: ..., N GP, 3 fixed"
```

**Tolerance:** KVM frequently exposes only 4 GP counters to the guest even on
a host with 8. That's enough to validate the code path; final 8-counter
validation can wait for bare metal once Subtask 0 has made bare metal safe.

## Phase C — Guest toolchain & source

```bash
# (cloud-init already installed build-essential, linux-headers-generic, git, libboost-dev)
git clone https://github.com/yyilong335/pmu_sync_sampler.git ~/pmu_sync_sampler
cd ~/pmu_sync_sampler/module
make                                   # produces pmu_sync_sample.ko
```

## Phase D — Snapshot the clean guest

Cheap rollback point. Create after Phase C, before any `insmod`.

```bash
# On the host
virsh -c qemu:///system shutdown pmu-test
virsh -c qemu:///system snapshot-create-as pmu-test clean-build \
    "Toolchain installed, repo cloned, module built, no insmod yet"
virsh -c qemu:///system start pmu-test
```

Recovery procedure (host) any time the guest hangs:

```bash
virsh -c qemu:///system destroy pmu-test                     # force off
virsh -c qemu:///system snapshot-revert pmu-test clean-build
virsh -c qemu:///system start pmu-test
```

---

## Stage 1 — Smoke-test the existing module (no sampling)

Goal: confirm Subtask 1's modernization works inside the guest before
touching anything.

```bash
# In guest
sudo insmod ~/pmu_sync_sampler/module/pmu_sync_sample.ko
dmesg | tail -20                       # init banner
ls /sys/sync_pmu/                      # 0 1 2 3 missed period status
sudo rmmod pmu_sync_sample
dmesg | tail -5                        # clean exit
```

**Do not** write `1` to `/sys/sync_pmu/status` yet — that arms the buggy NMI
path.

If Stage 1 fails to build/load, the issue is in already-merged Subtask 1 code
and must be fixed before continuing. On kernels ≥ 6.2 you should still be
fine here (Subtask 1 already migrated `default_attrs` → `default_groups`).

## Stage 2 — Subtask 2: udev-managed char device

Goal: replace `register_chrdev(222, ...)` with `alloc_chrdev_region` + `cdev`
+ `class`/`device` so udev creates `/dev/pmu_samples` automatically.

Risk: very low — affects init/exit paths only, sampling is never enabled in
this stage.

Critical files:
- [module/pmu_sync_sample_main.c:395](module/pmu_sync_sample_main.c#L395) — `register_chrdev` call site
- [module/pmu_sync_sample_main.c:419](module/pmu_sync_sample_main.c#L419) — `unregister_chrdev` call site
- [example_run.sh:14](example_run.sh#L14) — remove the `mknod /dev/pmu_samples c 222 0` line

```c
// Sketch — kernel 5.15 form. See "Kernel-version notes" below for 6.4+.
static dev_t   pmu_dev;
static struct cdev   pmu_cdev;
static struct class *pmu_class;

alloc_chrdev_region(&pmu_dev, 0, 1, "pmu_samples");
cdev_init(&pmu_cdev, &my_fops);
cdev_add(&pmu_cdev, pmu_dev, 1);
pmu_class = class_create(THIS_MODULE, "pmu_samples");   // 5.15 signature
device_create(pmu_class, NULL, pmu_dev, NULL, "pmu_samples");
```

Verify in guest:

```bash
cd ~/pmu_sync_sampler/module && make && sudo insmod pmu_sync_sample.ko
ls -l /dev/pmu_samples                 # exists, kernel-allocated major (not 222)
sudo rmmod pmu_sync_sample
ls -l /dev/pmu_samples                 # gone
sudo insmod pmu_sync_sample.ko && sudo rmmod pmu_sync_sample   # round-trip
```

Commit + push from the guest, refresh snapshot to `post-subtask2`.

## Stage 3 — Subtask 0 (new): fix the NMI/spinlock deadlock

Goal: stop the NMI handler from taking a regular spinlock that the read path
also holds. Without this, Stage 5 (period=50000) is expected to deadlock.

**Root cause** (verified in the code):
- NMI path: [module/intel.c:70](module/intel.c#L70) → `gatherSample()` at
  [module/pmu_sync_sample_main.c:209-238](module/pmu_sync_sample_main.c#L209-L238)
  → `pop_blist`/`append_blist` (lines 216, 234) which `spin_lock_irqsave` on
  the `blist.lock` at
  [module/pmu_sync_sample_main.c:23-27](module/pmu_sync_sample_main.c#L23-L27).
- Read path: `my_read()` (lines 116–147) acquires the same locks at lines 130
  and 144.
- `irqsave` does **not** mask NMIs. An NMI delivered while the read path
  holds the lock will spin forever in `pop_blist`.

**Approach: defer the buffer hand-off out of NMI context using `irq_work`.**
Smallest change that closes the race; keeps the existing list/buffer logic
untouched.

1. **NMI handler stays minimal.** Writes one `struct sample` into the
   per-CPU "current buffer" (no list lock — the per-CPU current pointer is
   owned by the CPU). Only consults the lock-protected blists when the
   current buffer is full.
2. **When the per-CPU buffer fills**, the NMI handler:
   - Flips a per-CPU `needs_swap` flag.
   - Calls `irq_work_queue(this_cpu_ptr(&pmu_irqwk))`.
   - Returns. Subsequent NMIs that fire before the irq_work runs see
     `needs_swap` already set and increment `missed` (mirrors existing
     semantics).
3. **The irq_work callback** runs in normal IRQ context, so
   `spin_lock_irqsave` is safe. It:
   - `pop_blist(&empty_buffers)` to grab a new empty.
   - Swaps the per-CPU current pointer.
   - `append_blist(&full_buffers, old_full)`.
   - Clears `needs_swap`.
   - `wake_up_all(&read_queue)`.

Files to touch (small, surgical):
- [module/pmu_sync_sample_main.c](module/pmu_sync_sample_main.c): add
  `<linux/irq_work.h>`, define a per-CPU `struct irq_work pmu_irqwk` and the
  callback. Move `pop_blist`/`append_blist`/`wake_up_all` out of
  `gatherSample()` into the callback.
- [module/intel.c](module/intel.c): no signature change for the NMI handler;
  `my_nmi_handler` still calls `gatherSample()`, which is now lock-free.

### Pre-existing bug surfaced during Subtask 0 testing — x2APIC LVTPC

The original code programs the local APIC's `LVTPC` register with
`native_apic_mem_write(APIC_LVTPC, APIC_DM_NMI)`. That writes through the
xAPIC MMIO window (`0xFEE00xxx`). **Modern KVM and modern bare-metal
Skylake-SP both default to x2APIC, where MMIO APIC access is silently
no-op'd — the PMI is generated by FIXED_CTR1 overflow but never reaches the
NMI vector.** First testing of Subtask 0 in the guest exposed this:
`Interrupts taken: 0`, `GLOBAL_STATUS` bit 33 set (overflow latched), but no
NMIs in `/proc/interrupts`.

Fix: replace all three call sites with `apic_write(...)` (the mode-agnostic
dispatcher that does the right thing on xAPIC and x2APIC alike).

This is also almost certainly the original cause of the bastion crash — on
xAPIC hardware the MMIO write happened to land on the actual APIC register
(by coincidence of identity-mapping), so the original 2.6.32 code "worked";
on x2APIC the write goes nowhere, leaving counters running with no PMI
delivery, and any subsequent module behaviour that assumes the NMI is firing
(such as the existing buffer hand-off via `wake_up_all` from inside
`gatherSample`) ends up confusing the kernel.

### Verification (in guest)

What actually passed in testing:

```bash
sudo insmod ~/pmu_sync_sampler/module/pmu_sync_sample.ko
for i in 0 1 2 3; do echo $((0xC0)) | sudo tee /sys/sync_pmu/$i; done
# Period escalation: 10ms, 1ms, 0.1ms, 50µs (paper cadence)
for p in 10000000 1000000 100000 50000; do
  echo $p | sudo tee /sys/sync_pmu/period
  echo 1 | sudo tee /sys/sync_pmu/status
  sleep 5
  echo 0 | sudo tee /sys/sync_pmu/status
  cat /sys/sync_pmu/missed
  grep NMI /proc/interrupts
done
sudo dmesg | grep -iE 'oops|deadlock|warn' || echo "clean"
sudo rmmod pmu_sync_sample
```

All four periods passed: `missed=0` throughout, NMI counter incremented in
`/proc/interrupts`, no oops/warn/bug, `Interrupts taken` non-zero at exit.

**Open follow-up — the dd hang.** When userspace actively reads
`/dev/pmu_samples` while sampling at period=50000, all 4 vCPUs lock at 100%
and SSH dies. Recovery via snapshot revert worked. Not yet diagnosed.
**Until this is fixed, do NOT proceed to Stage 4 / 5 in this VM.** The
`post-subtask0` snapshot will not be created until this passes.

### Out of scope for this subtask
The second README issue (`stopAll()` clobbers global PMU state on every CPU
at `rmmod`) — doesn't cause hangs, just steals counters from other PMU
users. Defer.

## Stage 4 — Subtask 3: expand to 8 GP + 3 fixed counters

Goal: sample all 11 counters per PMI (was 4 GP + 1 fixed).

Risk: medium. Bigger code surface, but Subtask 0 is now in place so a
runaway NMI can no longer wedge the kernel.

Critical files:
- [module/sample_buffer.h:10-14](module/sample_buffer.h#L10-L14) — grow
  `struct sample` to `gp[8] + fixed[3]`.
- [module/intel.c:18](module/intel.c#L18),
  [module/intel.c:117-125](module/intel.c#L117-L125),
  [module/intel.c:73-75](module/intel.c#L73-L75) — bump `num_ctrs`, MSR masks,
  per-counter loops; add `read_fixed()`.
- [module/pmu_sync_sample_main.c:178-200,229-231,306-314](module/pmu_sync_sample_main.c#L178-L200)
  — extend sysfs attrs `0..7`, update `gatherSample()` reads, update
  `myattr_attrs[]`.
- [textreader.cpp:71-82](textreader.cpp#L71-L82) — print all 11 counters
  per row.

**VM-only defense:** if `dmesg` in Phase B reported fewer than 8 GP counters,
`wrmsrl(MSR_CORE_PERF_GLOBAL_CTRL, 0xFF | (7ULL<<32))` will #GP on the
nonexistent counters. Read the available count from `CPUID 0xA EAX[15:8]`
and write only the available mask. Treat this as VM-specific defensiveness —
don't ship it to bare metal where all 8 are present.

Verify in guest, escalating period as in Stage 3:

```bash
sudo insmod module/pmu_sync_sample.ko
for i in 0 1 2 3 4 5 6 7; do echo $((0xC0)) | sudo tee /sys/sync_pmu/$i; done
echo 10000000 | sudo tee /sys/sync_pmu/period
echo 1 | sudo tee /sys/sync_pmu/status
sleep 2
sudo ./textreader </dev/pmu_samples | head -5
echo 0 | sudo tee /sys/sync_pmu/status
sudo rmmod pmu_sync_sample
```

Commit + push, refresh snapshot to `post-subtask3`.

## Stage 5 — Subtask 4: paper-style verification at period=50,000

| Idx | Event:Umask | Meaning |
|---|---|---|
| 0 | `0xC0:0x00` | INST_RETIRED.ANY (cross-check vs FIXED0) |
| 1 | `0x3C:0x00` | CPU_CLK_UNHALTED.CORE (cross-check vs FIXED1) |
| 2 | `0x3C:0x01` | CPU_CLK_UNHALTED.REF (cross-check vs FIXED2) |
| 3 | `0xC4:0x00` | BR_INST_RETIRED.ALL |
| 4 | `0xC5:0x00` | BR_MISP_RETIRED.ALL |
| 5 | `0x2E:0x4F` | LONGEST_LAT_CACHE.REFERENCE |
| 6 | `0x2E:0x41` | LONGEST_LAT_CACHE.MISS |
| 7 | `0xC0:0x01` | INST_RETIRED.PREC_DIST |

These are architectural events with stable encodings across Intel
generations, so the table works on Skylake-SP, Ice Lake, and Alder Lake
P-core alike.

```bash
sudo insmod module/pmu_sync_sample.ko
# write each (umask<<8)|event into /sys/sync_pmu/0..7
echo 50000 | sudo tee /sys/sync_pmu/period
echo 1 | sudo tee /sys/sync_pmu/status
./exercise1 &                          # supply real load
sudo ./textreader </dev/pmu_samples > /tmp/samples.csv &
sleep 5
echo 0 | sudo tee /sys/sync_pmu/status
kill %1; wait
sudo rmmod pmu_sync_sample
```

Verification queries on `/tmp/samples.csv` (small awk/python helper):
- `fixed1` ≈ 50000 per sample (drift only from interrupt latency).
- `gp[0] ≈ fixed[0]` (INST_RETIRED.ANY vs FIXED0).
- `gp[1] ≈ fixed[1]` (CPU_CLK_UNHALTED.CORE vs FIXED1).
- `gp[2] ≈ fixed[2]` (CPU_CLK_UNHALTED.REF vs FIXED2).
- Branch misprediction rate `gp[4]/gp[3]` plausible (single-digit %).
- `cat /sys/sync_pmu/missed` low and not exploding.

All five within ~2% tolerance → Stage 5 passes. Commit + push, final
snapshot `post-subtask4`.

---

## Recovery procedures

| Symptom | Action |
|---|---|
| Guest unresponsive, SSH dead | `virsh destroy pmu-test` from host |
| Suspect kernel oops, guest still alive | `journalctl -k -b > /tmp/oops.log && scp ...` before destroy |
| Need to retry from scratch | `virsh snapshot-revert pmu-test <snap>` |
| Module load failed cleanly (no hang) | `dmesg \| tail -50`, fix, `make`, re-insmod — no VM reset |

Persist `/var/log/kern.log` and `dmesg` after every test run via `scp` so a
guest revert doesn't lose them.

## When to leave the VM

After Stage 5 passes inside the VM, Subtask 0 has demonstrably closed the
deadlock and the module is ready for cautious bare-metal use:

1. Reboot the host (clean PMU state).
2. Load the module. **Do not** enable sampling immediately.
3. Repeat Stages 1 → 5 on bare metal with the same period escalation. Use a
   serial console or netconsole so an oops can be captured.
4. Only then run real workloads.

The remaining "`stopAll()` clobbers global PMU state" issue
([README.md](README.md) known issue #2) is still present — be explicit that
this module shouldn't coexist with `perf record` or other PMU users on the
host until that's fixed too.

---

## Critical files (single reference list)

- [module/pmu_sync_sample_main.c](module/pmu_sync_sample_main.c) — char dev,
  sysfs, buffer pipeline. Touched by Subtasks 0/2/3.
- [module/intel.c](module/intel.c) — NMI handler, MSRs. Touched by Subtask 3.
- [module/sample_buffer.h](module/sample_buffer.h) — kernel↔userspace ABI.
  Bumped by Subtask 3.
- [module/pmu_api.h](module/pmu_api.h) — minor: `read_fixed` decl in
  Subtask 3.
- [textreader.cpp](textreader.cpp) — print all 11 counters in Subtask 3.
- [example_run.sh](example_run.sh) — drop `mknod` line in Subtask 2.

## Out of scope

- `sender/`, `reader/` — wire format still encodes 6 counters; documented
  limitation, not blocking the subtasks.
- `stopAll()` global-PMU clobber — not a deadlock, defer.
- Bare-metal validation — covered in "When to leave the VM" but not part of
  this VM-only document.

---

## Addendum — Testing on Ubuntu 24.04 / kernel 6.x / Alder Lake host

This is a viable interim if the original Skylake-SP / 5.15 host
(`bastion`) is unavailable. Three host differences to handle.

### A1. Hybrid PMU (P-cores + E-cores)

Alder Lake is hybrid: P-cores expose 8 GP + 3 fixed counters; E-cores expose
6 GP + 3 fixed and use a different event encoding. The module's
`on_each_cpu(startCtrs, ...)` writes
`MSR_CORE_PERF_GLOBAL_CTRL = 0xFF | (7ULL<<32)` to *every* logical CPU — on
E-cores that hits nonexistent counters and may #GP.

**Workaround for VM testing: pin all vCPUs to P-cores only.** The guest
then sees a homogeneous PMU.

```bash
# On the host, identify P-cores (kernel 6.x exposes type via cpu_core/cpu_atom)
cat /sys/devices/cpu_core/cpus         # P-core CPU list
cat /sys/devices/cpu_atom/cpus         # E-core CPU list
# fallback:
lscpu --extended                       # P-cores typically have higher MAX_MHZ

# Pin vCPUs to P-core CPU IDs (example: P-cores are 0,2,4,6 with SMT siblings
# at 1,3,5,7 — pick one thread per P-core for a single-threaded-per-core view)
virsh -c qemu:///system vcpupin pmu-test 0 0
virsh -c qemu:///system vcpupin pmu-test 1 2
virsh -c qemu:///system vcpupin pmu-test 2 4
virsh -c qemu:///system vcpupin pmu-test 3 6
virsh -c qemu:///system vcpuinfo pmu-test     # confirm
```

If you're nervous about hot vcpu-pin, set it in the domain XML before first
boot via `virsh edit pmu-test` (`<cputune><vcpupin vcpu="0" cpuset="0"/>...`).

### A2. Kernel 6.x API drift since 5.15

Subtask 1 was verified on 5.15. Two known breakages on 6.x to watch for:

- **`class_create()` lost the `THIS_MODULE` argument in 6.4.** The
  Subtask 2 sketch above uses `class_create(THIS_MODULE, "pmu_samples")`
  which won't compile on 6.4+. Use `class_create("pmu_samples")` instead.
- **`kobj_type.default_attrs` was removed in 6.2.** Subtask 1 already
  migrated to `default_groups`/`ATTRIBUTE_GROUPS()`, so this should be clean
  — but rebuild and read the warnings.

Run `cd module && make` first. Don't speculate about other API changes —
let the compiler tell you.

### A3. Event encodings

The Subtask 4 events are all *architectural* (encodings stable across Intel
generations per SDM Vol 3B Ch 19), so the table works on Alder Lake P-core
without modification. But when `bastion` finally comes back, the steady-state
numbers from Stage 5 will differ between Alder Lake and Skylake-SP — they're
different microarchitectures. Record which CPU each Stage 5 run was on.

### A4. Plan adjustments

In Phase B's cloud-init flow, set `DIST=noble` for Ubuntu 24.04 and use
`--os-variant ubuntu24.04`. Everything else is unchanged.

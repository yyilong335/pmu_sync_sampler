#include "pmu_api.h"


#include <linux/interrupt.h>
#include <linux/nmi.h>
#include <asm/apic.h>
#include <asm/msr-index.h>
#include <asm/perf_event.h>
#include <asm/nmi.h>

/* Exported by the kernel (arch/x86/kernel/cpu/perfctr-watchdog.c) but not
 * declared in any installed header on 5.15. */
extern int  reserve_perfctr_nmi(unsigned int msr);
extern int  reserve_evntsel_nmi(unsigned int msr);
extern void release_perfctr_nmi(unsigned int msr);
extern void release_evntsel_nmi(unsigned int msr);

unsigned long num_ctrs = 8;

uint64_t read_ccnt(void) {
	uint64_t c;
	rdmsrl(MSR_ARCH_PERFMON_FIXED_CTR1, c);
	return c;
}

uint64_t read_pmn(unsigned i) {
	uint64_t c;
	rdmsrl(MSR_ARCH_PERFMON_PERFCTR0 + i, c);
	return c;
}

uint64_t read_fixed(unsigned i) {
	uint64_t c;
	rdmsrl(MSR_ARCH_PERFMON_FIXED_CTR0 + i, c);
	return c;
}

#define write_ccnt(V) wrmsrl(MSR_ARCH_PERFMON_FIXED_CTR1, (V))
#define read_cnf(I, V) rdmsrl(MSR_ARCH_PERFMON_EVENTSEL0 + (I), V)
/* Pass through user bits 0..15 (event/umask), 18 (edge), 19 (pin),
 * 21 (anythread), 23 (invert), 24..31 (cmask). Force USR=OS=EN=1,
 * INT=0 (only FIXED1 raises PMI in this driver). */
#define pmn_config(I, C) wrmsrl(MSR_ARCH_PERFMON_EVENTSEL0 + (I), \
            ((C) & 0xFFACFFFFULL)         \
            | (1ULL << 16) /* USR */      \
            | (1ULL << 17) /* OS */       \
            | (1ULL << 22) /* EN */ );

void dump_regs(void) {
    uint64_t c, c0, c1, c2, c3, g;
    c = read_ccnt();
    c0 = native_read_msr(MSR_ARCH_PERFMON_PERFCTR0 + 0); 
    c1 = native_read_msr(MSR_ARCH_PERFMON_PERFCTR0 + 1); 
    c2 = native_read_msr(MSR_ARCH_PERFMON_PERFCTR0 + 2); 
    c3 = native_read_msr(MSR_ARCH_PERFMON_PERFCTR0 + 3); 
    
    printk(KERN_ERR "[%u] %llu, %llu, %llu, %llu, %llu",
        smp_processor_id(), c, c0, c1, c2, c3 );

    read_cnf(0, c0);
    read_cnf(1, c1);
    read_cnf(2, c2);
    read_cnf(3, c3);
    

    rdmsrl(MSR_CORE_PERF_GLOBAL_STATUS, c);
    rdmsrl(MSR_CORE_PERF_GLOBAL_CTRL, g);
    printk(KERN_ERR "[%u] config (%llx, %llx) %llx, %llx, %llx, %llx",
        smp_processor_id(), c, g, c0, c1, c2, c3 );

}

static int my_nmi_handler(unsigned int cmd, struct pt_regs *regs)
{
    size_t i;

    /* Only the target CPU has counters armed; let NMIs on any other CPU
     * fall through to the watchdog / kgdb / etc. handlers. */
    if (smp_processor_id() != PMU_TARGET_CPU)
        return NMI_DONE;

    total_interrupts += 1;

    gatherSample();

    /* Reset all 8 GP counters and FIXED_CTR0 / FIXED_CTR2 so the next
     * sample reports a per-period delta (FIXED_CTR1 is reloaded below to
     * drive the next overflow). */
    write_ccnt(0xFFFFFFFFFFFF - period);
    for (i=0; i<num_ctrs; i++) {
        wrmsrl(MSR_ARCH_PERFMON_PERFCTR0 + i, 0);
    }
    wrmsrl(MSR_ARCH_PERFMON_FIXED_CTR0, 0);
    wrmsrl(MSR_ARCH_PERFMON_FIXED_CTR0 + 2, 0);

    /* Clear the overflow flags only after the reads -- it's only
     * required before re-arming LVTPC, and keeping it out of the
     * gatherSample path removes one variable-cost wrmsrl from the
     * read-side latency (matters in KVM where each MSR write costs
     * ~500-2000 cycles with jitter). */
    wrmsrl(MSR_CORE_PERF_GLOBAL_OVF_CTRL,
            (1ULL << 63) | (1ULL << 62) | (7ULL << 32) | 0xFFULL);

    if (shutdown != 0) {
        wrmsrl(MSR_CORE_PERF_GLOBAL_CTRL, 0);
    }

    apic_write(APIC_LVTPC, APIC_DM_NMI);
    return NMI_HANDLED;
}

void register_interrupt(void) {
    register_nmi_handler(NMI_LOCAL, my_nmi_handler, 0, "sync-pmu");
}

void deregister_interrupt(void) {
    unregister_nmi_handler(NMI_LOCAL, "sync-pmu");
}

void EnablePerfVect(uint32_t wantEnable) {
    if (wantEnable) {
        apic_write(APIC_LVTPC, APIC_DM_NMI); //PERF_MON_VECTOR);
    } else {
        apic_write(APIC_LVTPC, APIC_LVT_MASKED);
    }
    return;
}

void stopCtrsLocal(void* d) {
    wrmsrl(MSR_CORE_PERF_GLOBAL_CTRL, 0);
    wrmsrl(MSR_ARCH_PERFMON_EVENTSEL0, 0);

    EnablePerfVect(0);
}

void startCtrsLocal(unsigned long* cfgs) {
	int i;
    wrmsrl(MSR_CORE_PERF_GLOBAL_CTRL, 0);

    EnablePerfVect(1);

    // Overflow once every 'period' cycles
    write_ccnt(0xFFFFFFFFFFFF - period);
    for (i=0; i<num_ctrs; i++) {
	    pmn_config(i, cfgs[i]);
	    wrmsrl(MSR_ARCH_PERFMON_PERFCTR0 + i, 0);
    }
    /* Symmetric with my_nmi_handler: clear FIXED_CTR0/2 so the very
     * first sample after arming isn't contaminated with whatever the
     * counters held when GLOBAL_CTRL was last cleared. (FIXED_CTR1 was
     * just rewritten by write_ccnt above.) */
    wrmsrl(MSR_ARCH_PERFMON_FIXED_CTR0, 0);
    wrmsrl(MSR_ARCH_PERFMON_FIXED_CTR0 + 2, 0);

    /* FIXED_CTR_CTRL: FIXED0 OS|USR=0x3, FIXED1 OS|USR|PMI=0xB,
     * FIXED2 OS|USR=0x3 → 0x3 | (0xB<<4) | (0x3<<8) = 0x3B3 */
    wrmsrl(MSR_CORE_PERF_FIXED_CTR_CTRL, 0x3B3ULL);

    wrmsrl(MSR_CORE_PERF_GLOBAL_OVF_CTRL,
            (1ULL << 63) | (1ULL << 62) | (7ULL << 32) | 0xFFULL);
    /* Enable PMC0..7 + FIXED_CTR0..2 */
    wrmsrl(MSR_CORE_PERF_GLOBAL_CTRL, 0xFFULL | (7ULL << 32));
}

int initialize_arch(void) {
    //Reserve PCMx
    if (!reserve_perfctr_nmi(MSR_ARCH_PERFMON_PERFCTR0)) {
        printk(KERN_ERR "   Error: couldn't reserve perfctr!");
        return -EBUSY;
    }

    //Reserve PerfEvtSelx
    if (!reserve_evntsel_nmi(MSR_ARCH_PERFMON_EVENTSEL0)) {
        release_perfctr_nmi(MSR_ARCH_PERFMON_PERFCTR0);
        printk(KERN_ERR "   Error: couldn't reserve perfctr!");
        return -EBUSY;
    }

    num_ctrs = 8;

    return 0;
}

void cleanup_arch(void) {
    //Release PCMx
    release_perfctr_nmi(MSR_ARCH_PERFMON_PERFCTR0);

    //Release PerfEvtSelx
    release_evntsel_nmi(MSR_ARCH_PERFMON_EVENTSEL0);
}


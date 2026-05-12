#ifndef __PMU_API_H__
#define __PMU_API_H__

#include <linux/types.h>

/* CPU on which PMU counters are armed. The user's workload runs
 * `taskset -c PMU_TARGET_CPU ./prog`; counters on other CPUs are not
 * configured and the NMI handler ignores NMIs from those CPUs.
 *
 * Skylake-SP / Xeon Gold 6142 (bastion): 16 physical cores, SMT off
 * so all 16 CPUs are independent. CPU 3 has been the target across
 * all the kernel-5.15 verification runs. */
#define PMU_TARGET_CPU 3

// Provided in architecture-specific c file
extern unsigned long num_ctrs;
uint64_t read_ccnt(void);
uint64_t read_pmn(unsigned);
uint64_t read_fixed(unsigned);
int initialize_arch(void);
void cleanup_arch(void);
void startCtrsLocal(unsigned long *);
void stopCtrsLocal(void*);
void dump_regs(void);
void register_interrupt(void);
void deregister_interrupt(void);

// Used in architecture-specific interrupt
void gatherSample(uint64_t entry_ccnt);
extern volatile uint64_t total_interrupts;
extern uint64_t period;
extern volatile unsigned char shutdown;

#endif
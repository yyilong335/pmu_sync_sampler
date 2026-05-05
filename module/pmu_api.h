#ifndef __PMU_API_H__
#define __PMU_API_H__

#include <linux/types.h>

/* CPU on which PMU counters are armed. The user's workload runs
 * `taskset -c PMU_TARGET_CPU ./prog`; counters on other CPUs are not
 * configured and the NMI handler ignores NMIs from those CPUs.
 *
 * Alder Lake i5-1240P: P-cores are 0/2/4/6 (HT siblings 1/3/5/7 are
 * offline with SMT disabled). The original CPU 3 was CPU 2's HT
 * sibling; CPU 2 is the natural replacement on this hybrid part. */
#define PMU_TARGET_CPU 2

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
void gatherSample(void);
extern volatile uint64_t total_interrupts;
extern uint64_t period;
extern volatile unsigned char shutdown;

#endif
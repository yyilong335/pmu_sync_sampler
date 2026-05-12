#ifndef _SAMPLE_BUFFER_H_
#define _SAMPLE_BUFFER_H_

#ifdef __cplusplus
extern "C" {
#endif

#define BUFFER_SIZE (4*1024)
#define NUM_GP_COUNTERS    8
#define NUM_FIXED_COUNTERS 3

/* Packed: keeps sizeof(struct sample) at 64 (no struct padding) so
 * sizeof(struct buffer) <= BUFFER_SIZE -- userspace read(bs=BUFFER_SIZE)
 * trips my_read's count < BUFFER_SIZE check otherwise. counters[0..7]
 * are GP slots; counters[8..10] are FIXED_CTR0..2.
 *
 * handler_entry_ccnt is the FIXED_CTR1 value captured at the very top
 * of the NMI handler (before any other work), i.e. cycles since the
 * PMI overflow when our handler first got CPU time. Subtract this
 * from (cycles - period) to isolate "kernel/our handler prologue" cost. */
struct sample {
    unsigned long cycles;
    unsigned long pid;
    unsigned int counters[NUM_GP_COUNTERS + NUM_FIXED_COUNTERS];
    unsigned int handler_entry_ccnt;
} __attribute__((packed));

#define BUFFER_ENTRIES ((BUFFER_SIZE - 12) / sizeof(struct sample))
struct buffer {
    unsigned int core;
    unsigned int num_samples;
    struct buffer *nextBuffer; // For linked list purposes
    struct sample samples[BUFFER_ENTRIES];
};

#ifdef __cplusplus
}
#endif

#endif //_SAMPLE_BUFFER_H_
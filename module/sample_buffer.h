#ifndef _SAMPLE_BUFFER_H_
#define _SAMPLE_BUFFER_H_

#ifdef __cplusplus
extern "C" {
#endif

#define BUFFER_SIZE (4*1024)
#define NUM_GP_COUNTERS    8
#define NUM_FIXED_COUNTERS 3

/* Packed: without it sizeof(struct sample) pads from 60 to 64,
 * BUFFER_ENTRIES drops, and sizeof(struct buffer) no longer equals
 * BUFFER_SIZE -- userspace read(bs=BUFFER_SIZE) trips my_read's
 * count < BUFFER_SIZE check. counters[0..NUM_GP_COUNTERS-1] are
 * GP slots; counters[NUM_GP_COUNTERS..] are FIXED_CTR0..2. */
struct sample {
    unsigned long cycles;
    unsigned long pid;
    unsigned int counters[NUM_GP_COUNTERS + NUM_FIXED_COUNTERS];
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
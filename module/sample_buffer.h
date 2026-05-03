#ifndef _SAMPLE_BUFFER_H_
#define _SAMPLE_BUFFER_H_

#ifdef __cplusplus
extern "C" {
#endif

#define BUFFER_SIZE (4*1024)
#define NUM_GP_COUNTERS    8
#define NUM_FIXED_COUNTERS 3

/* Packed so sizeof(struct sample) stays at 60 bytes -- otherwise the
 * compiler pads to 64 (8-byte alignment of `unsigned long`), BUFFER_ENTRIES
 * drops from 68 to 63, sizeof(struct buffer) becomes 4048, and userspace
 * read(bs=BUFFER_SIZE) trips my_read's `count < BUFFER_SIZE` check. */
struct sample {
    unsigned long cycles;
    unsigned long pid;
    unsigned int gp[NUM_GP_COUNTERS];
    unsigned int fixed[NUM_FIXED_COUNTERS];
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
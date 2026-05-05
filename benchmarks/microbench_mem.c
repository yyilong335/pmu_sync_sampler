/* microbench_mem: random-stride memory walk pinned to CPU 3, designed to
 * drive each load to a different cache line that misses L1+L2 but hits L3.
 * Used to verify Load + Store ≈ LLC_REFERENCE on the synchronous sampler. */

#define _GNU_SOURCE
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define TARGET_CPU 3
#define LINE       64
#define BUF_BYTES  (16ULL * 1024 * 1024)        /* 16 MB > L2 (1 MB), < LLC (22 MB) */
#define NUM_LINES  (BUF_BYTES / LINE)

int main(int argc, char **argv)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(TARGET_CPU, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        perror("sched_setaffinity");
        return 1;
    }

    int seconds = (argc > 1) ? atoi(argv[1]) : 10;
    int do_stores = (argc > 2) ? atoi(argv[2]) : 1;

    /* One-cache-line nodes carrying a "next" pointer plus padding so each
     * dereference touches exactly one cache line. */
    struct node { struct node *next; uint64_t pad[7]; };
    struct node *nodes = aligned_alloc(LINE, NUM_LINES * sizeof(struct node));
    if (!nodes) { perror("aligned_alloc"); return 1; }
    memset(nodes, 0, NUM_LINES * sizeof(struct node));

    /* Fisher–Yates shuffle indices, then chain nodes in shuffled order. */
    uint32_t *order = malloc(NUM_LINES * sizeof(uint32_t));
    if (!order) { perror("malloc"); return 1; }
    for (size_t i = 0; i < NUM_LINES; i++) order[i] = (uint32_t)i;
    srand(42);
    for (size_t i = NUM_LINES - 1; i > 0; i--) {
        size_t j = (size_t)rand() % (i + 1);
        uint32_t t = order[i]; order[i] = order[j]; order[j] = t;
    }
    for (size_t i = 0; i < NUM_LINES - 1; i++)
        nodes[order[i]].next = &nodes[order[i+1]];
    nodes[order[NUM_LINES-1]].next = &nodes[order[0]];
    free(order);

    fprintf(stderr,
            "microbench_mem: pid=%d cpu=%d %zuMB / %zu lines, stores=%d, %ds\n",
            getpid(), TARGET_CPU, (size_t)(BUF_BYTES >> 20),
            (size_t)NUM_LINES, do_stores, seconds);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* Pointer-chase. Pseudo-random order so HW prefetchers can't help.
     * If do_stores, also write to the line we just loaded → mixes
     * MEM_INST_RETIRED.ALL_LOADS and ALL_STORES, both of which
     * generate one LLC ref to the (cold) line they touch. */
    register struct node *p = &nodes[0];
    uint64_t loads = 0;
    for (;;) {
        for (int k = 0; k < 100000; k++) {
            struct node *n = p->next;        /* load */
            if (do_stores) p->pad[0] = (uint64_t)n; /* store to same line */
            p = n;
        }
        loads += 100000;

        clock_gettime(CLOCK_MONOTONIC, &t1);
        double elapsed = (t1.tv_sec - t0.tv_sec) +
                         (t1.tv_nsec - t0.tv_nsec) / 1e9;
        if (elapsed >= seconds) break;
    }

    fprintf(stderr, "microbench_mem: done; %lu loads (final=%p)\n",
            (unsigned long)loads, (void*)p);
    free(nodes);
    return 0;
}

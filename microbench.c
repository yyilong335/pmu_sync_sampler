/* microbench: pin to CPU 3 and burn cycles in a tight ALU loop so the
 * sampler has something deterministic to measure. Single-purpose debug
 * tool — not part of the production build set. */

#define _GNU_SOURCE
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define TARGET_CPU 3

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
    fprintf(stderr, "microbench: pid=%d pinned to CPU %d, running %d seconds\n",
            getpid(), TARGET_CPU, seconds);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    volatile uint64_t x = 0;
    uint64_t iters = 0;
    for (;;) {
        for (int i = 0; i < 1000000; i++)
            x = x * 6364136223846793005ULL + (uint64_t)i;
        iters += 1000000;

        clock_gettime(CLOCK_MONOTONIC, &t1);
        double elapsed = (t1.tv_sec - t0.tv_sec) +
                         (t1.tv_nsec - t0.tv_nsec) / 1e9;
        if (elapsed >= seconds) break;
    }

    fprintf(stderr, "microbench: done; %lu iters, x=%lu\n",
            (unsigned long)iters, (unsigned long)x);
    return 0;
}

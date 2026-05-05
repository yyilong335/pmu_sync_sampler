/* microbench_alu: tight ALU loop pinned to CPU 3 with 8 independent
 * integer accumulators to expose ILP. No memory accesses in hot loop;
 * Skylake has 4 ALU ports so steady-state IPC should approach 3-4.
 * Used to verify the synchronous sampler reports high IPC for a
 * compute-bound workload. */

#define _GNU_SOURCE
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define TARGET_CPU 2

int main(int argc, char **argv)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(TARGET_CPU, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        perror("sched_setaffinity");
        return 1;
    }

    int seconds = (argc > 1) ? atoi(argv[1]) : 5;

    /* Volatile sink so the compiler can't fold the whole loop away. */
    volatile uint64_t sink = 0;

    fprintf(stderr, "microbench_alu: pid=%d cpu=%d %ds\n",
            getpid(), TARGET_CPU, seconds);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    register uint64_t a0 = 1, a1 = 2, a2 = 3, a3 = 4;
    register uint64_t a4 = 5, a5 = 6, a6 = 7, a7 = 8;
    uint64_t iters = 0;
    for (;;) {
        for (int k = 0; k < 1000000; k++) {
            /* 8 independent adds per iteration -> 8 in-flight uops,
             * dispatchable to 4 ALU ports => ~2 cycles per 8 uops = 4 IPC. */
            a0 += 0x9e3779b97f4a7c15ULL;
            a1 += 0xbf58476d1ce4e5b9ULL;
            a2 += 0x94d049bb133111ebULL;
            a3 += 0x2545f4914f6cdd1dULL;
            a4 += 0x9e3779b97f4a7c15ULL;
            a5 += 0xbf58476d1ce4e5b9ULL;
            a6 += 0x94d049bb133111ebULL;
            a7 += 0x2545f4914f6cdd1dULL;
        }
        iters += 1000000;
        sink += a0 ^ a1 ^ a2 ^ a3 ^ a4 ^ a5 ^ a6 ^ a7;

        clock_gettime(CLOCK_MONOTONIC, &t1);
        double elapsed = (t1.tv_sec - t0.tv_sec) +
                         (t1.tv_nsec - t0.tv_nsec) / 1e9;
        if (elapsed >= seconds) break;
    }

    fprintf(stderr, "microbench_alu: done; %lu iters sink=%lu\n",
            (unsigned long)iters, (unsigned long)sink);
    return 0;
}

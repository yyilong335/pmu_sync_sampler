/* microbench_ipc: deliberately high-IPC kernel for the synchronous PMU
 * sampler. Keep the timed loop pure: no clock_gettime, no I/O, no FP,
 * no syscalls. The PMU sampler is already the watcher; instrumenting
 * the bench would contaminate the samples (microbench_alu measured
 * 1.5 IPC because gcc folded its 1M-iter loop and the hot path became
 * clock_gettime + divsd, not the eight adds it claimed to test).
 *
 * Inline asm volatile prevents gcc from strength-reducing or hoisting
 * the kernel; iteration count comes from argv so the caller controls
 * runtime; the accumulator digest is emitted only AFTER the timed
 * loop. */

#define _GNU_SOURCE
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
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

    /* ~3 cyc/iter on Golden Cove -> 5e9 iters ~= 7.5s at 2 GHz. */
    uint64_t iters = (argc > 1) ? strtoull(argv[1], NULL, 10)
                                : 5000000000ULL;

    fprintf(stderr, "microbench_ipc: pid=%d cpu=%d iters=%lu\n",
            getpid(), TARGET_CPU, (unsigned long)iters);

    uint64_t a0=1, a1=2, a2=3, a3=4, a4=5, a5=6, a6=7, a7=8;
    uint64_t k1 = 0x9e3779b97f4a7c15ULL;
    uint64_t k2 = 0xbf58476d1ce4e5b9ULL;
    uint64_t k3 = 0x94d049bb133111ebULL;
    uint64_t k4 = 0x2545f4914f6cdd1dULL;

    for (uint64_t i = 0; i < iters; i++) {
        asm volatile (
            "addq %8,  %0\n\t"
            "addq %9,  %1\n\t"
            "addq %10, %2\n\t"
            "addq %11, %3\n\t"
            "addq %8,  %4\n\t"
            "addq %9,  %5\n\t"
            "addq %10, %6\n\t"
            "addq %11, %7\n\t"
            : "+r"(a0), "+r"(a1), "+r"(a2), "+r"(a3),
              "+r"(a4), "+r"(a5), "+r"(a6), "+r"(a7)
            : "r"(k1), "r"(k2), "r"(k3), "r"(k4));
    }

    fprintf(stderr,
            "microbench_ipc: done; a0..a7 = "
            "%lx %lx %lx %lx %lx %lx %lx %lx\n",
            a0, a1, a2, a3, a4, a5, a6, a7);
    return 0;
}

#include "module/sample_buffer.h"

#include <stdlib.h>
#include <stdio.h>
#include <cassert>
#include <stdint.h>
#include <unistd.h>

#include <fstream>
#include <streambuf>
#include <unordered_map>
#include <string>

using namespace std;

struct ProcessInfo {
	uint32_t pid;
	enum {
		Unknown,
		Kernel,
		User
	} mode;
	string cmdline;
	string executable;

	ProcessInfo() {
		pid = 0;
		mode = Unknown;
	}
};

unordered_map<unsigned long, ProcessInfo> procMap;

void readInto(unsigned long pid, const char* fn, string& into) {
	char fnBuffer[256];
	snprintf(fnBuffer, 256, "/proc/%lu/%s", pid, fn);
	std::ifstream t(fnBuffer);
	into.assign((std::istreambuf_iterator<char>(t)),
                 std::istreambuf_iterator<char>());
}

void readLinkPathInto(unsigned long pid, const char* fn, string& into) {
	char fnBuffer[256], buf[1024];
	snprintf(fnBuffer, 256, "/proc/%lu/%s", pid, fn);
	ssize_t rc = readlink(fnBuffer, buf, sizeof(buf)-1);
	if (rc != -1) {
		buf[rc] = '\0';
		into = buf;
	} else {
		into = "";
	}
}

void populate(ProcessInfo& pi) {
	readInto(pi.pid, "cmdline", pi.cmdline);
	readLinkPathInto(pi.pid, "exe", pi.executable);
	if (pi.executable == "" && pi.cmdline == "")
		pi.mode = ProcessInfo::Kernel;
	else
		pi.mode = ProcessInfo::User;
}

ProcessInfo& getProcessInfo(unsigned long pid) {
	ProcessInfo& pi = procMap[pid];
	if (pi.mode == ProcessInfo::Unknown) {
		pi.pid = pid;
		populate(pi);
	}
	return pi;
}

/* Per-CPU previous-sample state. Kernel no longer resets the 8 GP
 * counters or FIXED_CTR0 / FIXED_CTR1 at handler exit, so the values in
 * c.counters[0..9] arrive monotonic-accumulating since arm. textreader
 * computes per-PMI deltas via unsigned subtraction (mod 2^32 wraparound is
 * the right behavior for sub-2^32 deltas, which all our event rates are).
 * counters[10] is FIXED_CTR2's second read -- already per-PMI because
 * write_ccnt reloads it every handler (FIXED_CTR2 is the PMI-driver) --
 * passed through raw. Same for cycles and handler_entry_ccnt. */
struct CpuPrev {
	unsigned int counters[NUM_GP_COUNTERS + NUM_FIXED_COUNTERS];
	bool initialized;
	CpuPrev() : initialized(false) {
		for (int i = 0; i < NUM_GP_COUNTERS + NUM_FIXED_COUNTERS; i++)
			counters[i] = 0;
	}
};

unordered_map<unsigned int, CpuPrev> cpuPrev;

void outputBuffer(struct buffer& b) {
	assert(b.num_samples <= BUFFER_ENTRIES);
	CpuPrev& prev = cpuPrev[b.core];
	for (size_t i=0; i<b.num_samples; i++) {
		struct sample& c = b.samples[i];
		ProcessInfo& pi = getProcessInfo(c.pid);

		/* First sample on this CPU: kernel set counters to 0 at arm, so
		 * the raw value already IS the delta from arm-time. After that,
		 * unsigned (a - b) gives the per-PMI count. counters[10] is left
		 * raw (per-PMI by construction via write_ccnt on FIXED_CTR2). */
		unsigned int d[NUM_GP_COUNTERS + NUM_FIXED_COUNTERS];
		for (int j = 0; j < NUM_GP_COUNTERS + NUM_FIXED_COUNTERS; j++) {
			if (j == NUM_GP_COUNTERS + 2)
				d[j] = c.counters[j];   /* FIXED_CTR2: passthrough */
			else
				d[j] = prev.initialized ? (c.counters[j] - prev.counters[j])
				                        : c.counters[j];
			prev.counters[j] = c.counters[j];
		}
		prev.initialized = true;

		printf("%lu,%u,%lu,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%s,%s\n",
			c.pid, b.core, c.cycles,
			d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
			d[8], d[9], d[10],
			c.handler_entry_ccnt,
			pi.cmdline.c_str(), pi.executable.c_str());
	}
}

int main(int argc, const char** argv) {
	FILE* f = fopen("/dev/pmu_samples", "rb");
	if (f == NULL) {
		perror("Error opening samples device:");
		return -1;
	}

	while (!feof(f)) {
		struct buffer b;
		size_t rc = fread(&b, sizeof(struct buffer), 1, f);
		outputBuffer(b);
	}

	fclose(f);

	return 0;
}
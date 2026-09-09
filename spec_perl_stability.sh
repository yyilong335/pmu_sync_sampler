#!/bin/bash
# Stability harness: run SPEC 600.perlbench_s (checkspam ref-speed input) under
# the synchronous PMU sampler N times, save each run's CSV separately, and
# report cross-run mean/stddev/CV for total INST, LOAD, STORE, BRANCH, etc.
#
# Usage:
#   sudo ./spec_perl_stability.sh              # default RUNS=5
#   sudo RUNS=3 ./spec_perl_stability.sh
#
# Output (under results/):
#   spec_perl_<i>.csv     per-PMI samples from run i
#   spec_perl_<i>.log     per-run setup + per-run totals
#   spec_perl_stability.log    cross-run summary table

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

RUNS="${RUNS:-5}"
SPEC_DIR=/p/csd/SPEC2017/benchspec/CPU/600.perlbench_s/run/run_base_refspeed_gcc_14_2_singleThread_static-m64.0000
BENCH=perlbench_s_base.gcc_14_2_singleThread_static-m64
BENCH_ARGV=(-I./lib checkspam.pl 2500 5 25 11 150 1 1 1 1)

KO="$HERE/module/pmu_sync_sample.ko"
USER_NAME="${SUDO_USER:-kbh8sa}"

mkdir -p results
SUMMARY="$HERE/results/spec_perl_stability.log"
: > "$SUMMARY"

if [ "$EUID" -ne 0 ]; then
    echo "error: must be run as root (insmod/rmmod)" >&2; exit 1
fi
if [ -z "${SUDO_USER:-}" ]; then
    echo "error: SUDO_USER is empty -- invoke via 'sudo', not as raw root" >&2; exit 1
fi
# Do NOT stat $SPEC_DIR/$BENCH from root: /p/csd is NFS with root_squash,
# so root sees ENOENT/EACCES even though $SUDO_USER can execute the binary.
# We run the workload itself as $SUDO_USER (see runuser block below).
if [ ! -f "$KO" ]; then
    echo "error: missing $KO (build with: cd module && make)" >&2; exit 1
fi
if [ "$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)" = "1" ]; then
    echo "error: nmi_watchdog=1 -- run prepare_for_benchmarking.sh first" >&2; exit 1
fi

# Preflight: KVM guest holds host's PMC0 via vPMU passthrough.
if command -v virsh >/dev/null 2>&1; then
    if [ -n "$(virsh list --name 2>/dev/null | sed '/^$/d')" ]; then
        echo "error: KVM guest(s) running -- shut down before sampling" >&2; exit 1
    fi
fi

#-----------------------------------------------------------------------
# one_run RUN_NUM CSV LOG TR_ERR  -- insmod, configure, arm, run perl,
# stop, rmmod. Returns 0 on success.
#-----------------------------------------------------------------------
one_run() {
    local run="$1" csv="$2" log="$3" tr_err="$4"
    : > "$csv"; : > "$log"; : > "$tr_err"

    {
    echo "=== run $run starting at $(date -Iseconds) ==="
    uname -r
    echo "branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

    lsmod | grep -q '^pmu_sync_sample ' && rmmod pmu_sync_sample
    dmesg -C

    echo "--- insmod ---"
    insmod "$KO" || { echo "insmod failed"; return 1; }

    echo "--- configure events from events.conf, period=50000 ---"
    echo 50000 > /sys/sync_pmu/period
    local slot=0
    while read -r name enc _rest; do
        case "$name" in ''|\#*) continue ;; esac
        [ "$slot" -ge 8 ] && continue
        local enc_dec=$((enc))
        echo "$enc_dec" > /sys/sync_pmu/$slot
        printf '  slot %d  %-18s 0x%04X\n' "$slot" "$name" "$enc_dec"
        slot=$((slot + 1))
    done < "$HERE/events.conf"
    while [ "$slot" -lt 8 ]; do
        echo 0 > /sys/sync_pmu/$slot
        slot=$((slot + 1))
    done

    echo "--- launch textreader ---"
    "$HERE/textreader" > "$csv" 2> "$tr_err" &
    local tr_pid=$!
    sleep 0.3
    if ! kill -0 "$tr_pid" 2>/dev/null; then
        echo "textreader died early; stderr:"
        cat "$tr_err"
        rmmod pmu_sync_sample
        return 1
    fi
    echo "textreader pid=$tr_pid"

    echo "--- arm sampler (status=1) ---"
    echo 1 > /sys/sync_pmu/status

    echo "--- run $BENCH (workload args: ${BENCH_ARGV[*]}) on CPU 3 as $SUDO_USER ---"
    local t0=$(date +%s)
    # Run the workload as the invoking user, not root: /p/csd is NFS with
    # root_squash, and the bench itself never needed root privileges anyway.
    runuser -u "$SUDO_USER" -- bash -c '
        cd "$1" || exit 127
        taskset -c 3 "./$2" "${@:3}"
    ' _ "$SPEC_DIR" "$BENCH" "${BENCH_ARGV[@]}" > /dev/null
    local rc=$?
    local t1=$(date +%s)
    echo "bench rc=$rc, wall=$((t1-t0))s"

    echo "--- stop sampler (status=0) ---"
    echo 0 > /sys/sync_pmu/status
    wait "$tr_pid" 2>/dev/null

    echo "--- results ---"
    echo "missed: $(cat /sys/sync_pmu/missed)"
    echo "csv lines: $(wc -l < "$csv")"

    echo "--- dmesg tail ---"
    dmesg | tail -5

    rmmod pmu_sync_sample && echo "rmmod ok"
    echo "=== run $run done at $(date -Iseconds) ==="
    } 2>&1 | tee -a "$log"

    chown "$USER_NAME:$USER_NAME" "$csv" "$log" "$tr_err" 2>/dev/null || true
    return 0
}

#-----------------------------------------------------------------------
# extract_totals CSV  -- emit one line per workload-PID with totals.
# Identifies the workload PID as the one with the most rows.
#
# Drops u32-underflow rows: with the no-reset code path, textreader
# computes per-PMI deltas via unsigned subtraction; on rare buffer-pool
# transitions (~1 in 400K samples observed) prev > current, so the
# delta underflows to ~2^32. Such a row would inflate totals by ~2^32
# per affected column. Threshold: any counter > 2^31 is an underflow,
# since real per-period deltas at period=50,000 are far below 2^31.
#-----------------------------------------------------------------------
extract_totals() {
    local csv="$1"
    awk -F, -v THRESH=2147483648 '
    {
        pid=$1
        rows_by_pid[pid]++
        bad=0
        for (i=4; i<=14; i++) if ($i+0 > THRESH) { bad=1; break }
        if (bad) { skipped[pid]++; next }
        n[pid]++
        cyc[pid]+=$3
        c0[pid]+=$4   # STALL_ISSUE
        c1[pid]+=$5   # STALL_RETIRE
        c2[pid]+=$6   # LOAD
        c3[pid]+=$7   # STORE
        c4[pid]+=$8   # BRANCH
        c5[pid]+=$9   # L1D_REPLACEMENT
        c6[pid]+=$10  # L1I_MISS
        c8[pid]+=$12  # INST_RETIRED (FIXED_CTR0 delta)
        c9[pid]+=$13  # CORE cycles per PMI (FIXED_CTR1 delta; PMI is REF-driven now)
        hec[pid]+=$15
    }
    END {
        max=0; wl=""
        for (p in rows_by_pid) if (rows_by_pid[p] > max) { max=rows_by_pid[p]; wl=p }
        if (wl=="") exit
        # output: pid n_clean cyc(REF) inst load store branch l1d l1i stall_iss stall_ret corecyc skipped
        printf "%s %d %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %d\n",
               wl, n[wl],
               cyc[wl], c8[wl], c2[wl], c3[wl], c4[wl],
               c5[wl], c6[wl], c0[wl], c1[wl], c9[wl],
               skipped[wl]+0
    }' "$csv"
}

#-----------------------------------------------------------------------
# main: loop RUNS times, then summarize
#-----------------------------------------------------------------------
echo "=== spec_perl_stability: $RUNS runs at period=50000 ===" | tee -a "$SUMMARY"
date -Iseconds | tee -a "$SUMMARY"

# header: pid  n_clean  cyc(REF)  inst  load  store  branch  l1d  l1i  stall_iss stall_ret corecyc  skipped
declare -a TOT
for i in $(seq 1 "$RUNS"); do
    csv="$HERE/results/spec_perl_${i}.csv"
    log="$HERE/results/spec_perl_${i}.log"
    tr_err="$HERE/results/spec_perl_${i}.tr.err"

    echo
    echo "============ RUN $i / $RUNS ============" | tee -a "$SUMMARY"
    one_run "$i" "$csv" "$log" "$tr_err" || { echo "run $i failed"; continue; }
    line="$(extract_totals "$csv")"
    if [ -n "$line" ]; then
        TOT[i]="$line"
        echo "totals run $i: $line" | tee -a "$SUMMARY"
    else
        echo "run $i produced no CSV totals" | tee -a "$SUMMARY"
    fi
done

#-----------------------------------------------------------------------
# Cross-run summary: per-metric mean / stddev / CV
#-----------------------------------------------------------------------
echo
echo "=== cross-run stability summary ===" | tee -a "$SUMMARY"
{
    echo "fields: pid n_clean cyc(REF) inst load store branch l1d_repl l1i_miss stall_iss stall_ret corecyc skipped"
    for i in $(seq 1 "$RUNS"); do
        printf '  run %d: %s\n' "$i" "${TOT[i]:-(missing)}"
    done
} | tee -a "$SUMMARY"

# stats per column. Field index in TOT[i]: 1=pid 2=n_clean ... 12=corecyc 13=skipped
{
    printf '\n  %-12s %16s %16s %8s\n' "metric" "mean" "stddev" "CV(%)"
    printf '  %-12s %16s %16s %8s\n' "------" "----" "------" "-----"
    for col in 2 3 4 5 6 7 8 9 10 11 12 13; do
        name=$(awk -v c=$col 'BEGIN {
            split("pid n_clean cyc_ref inst load store branch l1d_repl l1i_miss stall_iss stall_ret corecyc skipped", a, " ")
            print a[c]
        }')
        vals=""
        for i in $(seq 1 "$RUNS"); do
            v=$(printf '%s\n' "${TOT[i]:-}" | awk -v c=$col '{print $c}')
            [ -n "$v" ] && vals="$vals $v"
        done
        echo "$vals" | awk -v name="$name" '
        {
            n=NF
            if (n==0) next
            s=0; for (i=1;i<=n;i++) s+=$i
            m=s/n
            ss=0; for (i=1;i<=n;i++) ss+=($i-m)*($i-m)
            sd=(n>1)?sqrt(ss/(n-1)):0
            cv=(m>0)?100*sd/m:0
            printf "  %-12s %16.0f %16.0f %8.3f\n", name, m, sd, cv
        }'
    done
} | tee -a "$SUMMARY"

chown "$USER_NAME:$USER_NAME" "$SUMMARY" 2>/dev/null || true
echo
echo "=== done. summary: $SUMMARY ==="

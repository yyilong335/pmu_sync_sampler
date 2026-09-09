#!/bin/bash
# Multi-benchmark PMU sampling runner for SPEC CPU 2017.
#
# Runs each requested benchmark for ~1 minute of wall time under the
# synchronous PMU sampler (REF-driven, events_aegis.conf, period=50000
# REF cycles). Cache is dropped before each bench.
#
# TIMING MODEL: per-bench, a *single* background subprocess does
#   ( sleep WINDOW_SEC && kill -TERM $BENCH_PID )
# and the main script blocks on `wait $BENCH_PID`. That's ONE blocking
# nanosleep, no polling, no clock_gettime, no busy loop. The killer
# subprocess consumes zero CPU during the 60s and won't be scheduled
# to CPU 3 (isolcpus=2,3 excludes it). Adjust the window per bench
# via the WINDOW_SEC env var (default 60).
#
# Usage:
#   sudo ./spec_multibench_run.sh                     # all 20 benches
#   sudo ./spec_multibench_run.sh perl_1 mcf leela    # named subset
#
# Output:
#   results/multibench/spec_<bench>.csv       per-PMI samples
#   results/multibench/spec_<bench>.log       per-run trace
#   results/multibench/multibench_summary.log per-bench one-liner totals

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

SPEC_ROOT=/p/csd/SPEC2017/benchspec/CPU
RUN_SUB=run/run_base_refspeed_gcc_14_2_singleThread_static-m64.0000
KO="$HERE/module/pmu_sync_sample.ko"
EVENTS_CONF="$HERE/events_aegis.conf"
OUT_DIR="$HERE/results/multibench"
SUMMARY="$OUT_DIR/multibench_summary.log"
USER_NAME="${SUDO_USER:-kbh8sa}"
WINDOW_SEC="${WINDOW_SEC:-60}"

# Benchmark table: name  spec_number  binary_base_stem  [stdin_file]
# binary is <stem>_base.gcc_14_2_singleThread_static-m64
# Arguments live in BENCH_ARGS below (keyed by name).
BENCH_LIST=(
    "perl_1     600.perlbench_s   perlbench_s"
    "gcc_1      602.gcc_s         sgcc"
    "mcf        605.mcf_s         mcf_s"
    "omnetpp    620.omnetpp_s     omnetpp_s"
    "xalan      623.xalancbmk_s   xalancbmk_s"
    "x264_3     625.x264_s        x264_s"
    "deepsjeng  631.deepsjeng_s   deepsjeng_s"
    "leela      641.leela_s       leela_s"
    "exchange   648.exchange2_s   exchange2_s"
    "xz_1       657.xz_s          xz_s"
    "bwaves_1   603.bwaves_s      speed_bwaves      bwaves_1.in"
    "cactuBSSN  607.cactuBSSN_s   cactuBSSN_s"
    "lbm        619.lbm_s         lbm_s"
    "imagick    638.imagick_s     imagick_s"
    "nab        644.nab_s         nab_s"
    "fotonik3d  649.fotonik3d_s   fotonik3d_s"
    "roms       654.roms_s        sroms             ocean_benchmark3.in"
    "wrf        621.wrf_s         wrf_s"
    "pop2       628.pop2_s        speed_pop2"
    "cam4       627.cam4_s        cam4_s"
)

declare -A BENCH_ARGS=(
    [perl_1]="-I./lib checkspam.pl 2500 5 25 11 150 1 1 1 1"
    [gcc_1]="gcc-pp.c -O5 -fipa-pta -o gcc-pp.opts-O5_-fipa-pta.s"
    [mcf]="inp.in"
    [omnetpp]="-c General -r 0"
    [xalan]="-v t5.xml xalanc.xsl"
    [x264_3]="--seek 500 --dumpyuv 200 --frames 1250 -o BuckBunny_New.264 BuckBunny.yuv 1280x720"
    [deepsjeng]="ref.txt"
    [leela]="ref.sgf"
    [exchange]="6"
    [xz_1]="cpu2006docs.tar.xz 6643 055ce243071129412e9dd0b3b69a21654033a9b723d874b2015c774fac1553d9713be561ca86f74e4f16f22e664fc17a79f30caa5ad2c04fbc447549c2810fae 1036078272 1111795472 4"
    [bwaves_1]="bwaves_1"
    [cactuBSSN]="spec_ref.par"
    [lbm]="2000 reference.dat 0 0 200_200_260_ldc.of"
    [imagick]="-limit disk 0 refspeed_input.tga -resize 817% -rotate -2.76 -shave 540x375 -alpha remove -auto-level -contrast-stretch 1x1% -colorspace Lab -channel R -equalize +channel -colorspace sRGB -define histogram:unique-colors=false -adaptive-blur 0x5 -despeckle -auto-gamma -adaptive-sharpen 55 -enhance -brightness-contrast 10x10 -resize 30% refspeed_output.tga"
    [nab]="3j1n 20140317 220"
    [fotonik3d]=""
    [roms]=""
    [wrf]=""
    [pop2]=""
    [cam4]=""
)

#-----------------------------------------------------------------------
# Preflight (once)
#-----------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "error: must be run as root (insmod/rmmod)" >&2; exit 1
fi
if [ -z "${SUDO_USER:-}" ]; then
    echo "error: SUDO_USER empty -- invoke via 'sudo', not raw root" >&2; exit 1
fi
if [ ! -f "$KO" ]; then
    echo "error: missing $KO (build with: cd module && make)" >&2; exit 1
fi
if [ ! -r "$EVENTS_CONF" ]; then
    echo "error: missing $EVENTS_CONF" >&2; exit 1
fi
if [ "$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)" = "1" ]; then
    echo "error: nmi_watchdog=1 -- run prepare_for_benchmarking.sh first" >&2; exit 1
fi
if command -v virsh >/dev/null 2>&1; then
    if [ -n "$(virsh list --name 2>/dev/null | sed '/^$/d')" ]; then
        echo "error: KVM guest running -- shut down before sampling" >&2; exit 1
    fi
fi
KO_VMAG=$(modinfo "$KO" | awk '/^vermagic:/ {print $2}')
if [ "$KO_VMAG" != "$(uname -r)" ]; then
    echo "error: .ko vermagic $KO_VMAG != running kernel $(uname -r) -- rebuild" >&2; exit 1
fi

mkdir -p "$OUT_DIR"

#-----------------------------------------------------------------------
# resolve_bench <name>
#   Prints "SPEC_NUM BIN_STEM STDIN_FILE" or empty if unknown.
#-----------------------------------------------------------------------
resolve_bench() {
    local want="$1" row
    for row in "${BENCH_LIST[@]}"; do
        read -r n spec stem stdin_file <<<"$row"
        if [ "$n" = "$want" ]; then
            echo "$spec $stem ${stdin_file:-}"; return 0
        fi
    done
    return 1
}

#-----------------------------------------------------------------------
# run_one <bench_name>
#-----------------------------------------------------------------------
run_one() {
    local bench="$1"
    local row spec stem stdin_file
    row="$(resolve_bench "$bench")" || { echo "unknown bench: $bench"; return 1; }
    read -r spec stem stdin_file <<<"$row"

    local cwd="$SPEC_ROOT/$spec/$RUN_SUB"
    local bin="${stem}_base.gcc_14_2_singleThread_static-m64"
    local args="${BENCH_ARGS[$bench]:-}"

    local csv="$OUT_DIR/spec_${bench}.csv"
    local log="$OUT_DIR/spec_${bench}.log"
    local tr_err="$OUT_DIR/spec_${bench}.tr.err"
    : > "$csv"; : > "$log"; : > "$tr_err"

    {
    echo "=== $bench starting at $(date -Iseconds) ==="
    echo "spec_num=$spec stem=$stem stdin_file=${stdin_file:-(none)}"
    echo "cwd=$cwd"
    echo "args=$args"

    # cwd/binary readable by $SUDO_USER? (NFS root_squash means we can't check
    # from root; runuser probe instead.)
    if ! runuser -u "$USER_NAME" -- test -x "$cwd/$bin"; then
        echo "WARN: $USER_NAME cannot execute $cwd/$bin -- skipping"
        return 2
    fi
    if [ -n "$stdin_file" ] && ! runuser -u "$USER_NAME" -- test -r "$cwd/$stdin_file"; then
        echo "WARN: $USER_NAME cannot read stdin $cwd/$stdin_file -- skipping"
        return 2
    fi

    # --- drop OS caches: aligned with Aegis's collector methodology ---
    echo "--- drop caches ---"
    sync
    echo 3 > /proc/sys/vm/drop_caches

    lsmod | grep -q '^pmu_sync_sample ' && rmmod pmu_sync_sample
    dmesg -C

    echo "--- insmod ---"
    insmod "$KO" || { echo "insmod failed"; return 1; }

    echo "--- configure events (aegis) period=50000 ---"
    echo 50000 > /sys/sync_pmu/period
    local slot=0
    while read -r name enc _rest; do
        case "$name" in ''|\#*) continue ;; esac
        [ "$slot" -ge 8 ] && continue
        local enc_dec=$((enc))
        echo "$enc_dec" > /sys/sync_pmu/$slot
        printf '  slot %d  %-18s 0x%04X\n' "$slot" "$name" "$enc_dec"
        slot=$((slot + 1))
    done < "$EVENTS_CONF"
    while [ "$slot" -lt 8 ]; do
        echo 0 > /sys/sync_pmu/$slot
        slot=$((slot + 1))
    done

    echo "--- launch textreader ---"
    "$HERE/textreader" > "$csv" 2> "$tr_err" &
    local tr_pid=$!
    # $! is valid immediately after &; the char device is opened by
    # textreader before it blocks on read. If it crashed on startup,
    # the subsequent `echo 1 > /sys/sync_pmu/status` still succeeds
    # but no reader will drain buffers -- we'd see missed spike in the
    # log. Log a warning if the PID is already gone right now:
    if ! kill -0 "$tr_pid" 2>/dev/null; then
        echo "textreader died early:"; cat "$tr_err"
        rmmod pmu_sync_sample; return 1
    fi
    echo "textreader pid=$tr_pid"

    echo "--- arm sampler (status=1) ---"
    echo 1 > /sys/sync_pmu/status

    # --- launch workload as $SUDO_USER, taskset to CPU 3 ---
    echo "--- launch $bench on CPU 3 as $USER_NAME ---"
    local bench_stdout="$OUT_DIR/spec_${bench}.stdout"
    local bench_stderr="$OUT_DIR/spec_${bench}.stderr"
    local t0 t1

    if [ -n "$stdin_file" ]; then
        runuser -u "$USER_NAME" -- bash -c '
            cd "$1" || exit 127
            exec taskset -c 3 "./$2" $3 < "$4"
        ' _ "$cwd" "$bin" "$args" "$stdin_file" \
            > "$bench_stdout" 2> "$bench_stderr" &
    else
        runuser -u "$USER_NAME" -- bash -c '
            cd "$1" || exit 127
            exec taskset -c 3 "./$2" $3
        ' _ "$cwd" "$bin" "$args" \
            > "$bench_stdout" 2> "$bench_stderr" &
    fi
    local bench_pid=$!
    t0=$(date +%s)
    echo "bench pid=$bench_pid, window=${WINDOW_SEC}s"

    # ONE blocking sleep in a background subprocess. When it wakes, it
    # SIGTERMs the bench and exits. No polling, no clock_gettime; the
    # subprocess consumes zero CPU during the sleep and can't be
    # scheduled to CPU 3 (isolcpus). If the bench finishes naturally
    # before the window, we kill the killer below.
    ( sleep "$WINDOW_SEC" && kill -TERM "$bench_pid" 2>/dev/null ) &
    local killer_pid=$!

    wait "$bench_pid" 2>/dev/null
    local rc=$?
    t1=$(date +%s)

    # If the bench finished on its own, cancel the killer.
    kill "$killer_pid" 2>/dev/null
    wait "$killer_pid" 2>/dev/null

    echo "bench rc=$rc, wall=$((t1-t0))s (rc=143=SIGTERM from window = expected)"

    echo "--- stop sampler ---"
    echo 0 > /sys/sync_pmu/status
    wait "$tr_pid" 2>/dev/null

    echo "--- results ---"
    local missed csv_lines
    missed=$(cat /sys/sync_pmu/missed 2>/dev/null || echo -1)
    csv_lines=$(wc -l < "$csv")
    echo "missed: $missed"
    echo "csv lines: $csv_lines"

    # --- per-bench totals for the summary line ---
    # cols: pid,core,cyc,d0..d7,d8,d9,d10,hec,cmdline,exe
    # events_aegis.conf: d0=LOAD d1=L1D_REPL d2=STORE d3=L1I_MISS
    #                    d4=BRANCH d5=LLC_REF d6=LLC_MISS d7=unused
    #                    d8=INST d9=CORE-cyc(delta) d10=REF-cyc(raw)
    awk -F, -v bench="$bench" -v wall=$((t1-t0)) -v missed="$missed" '
    { rows_by_pid[$1]++ }
    {
        bad=0
        for (i=4;i<=14;i++) if ($i+0 > 2147483648) { bad=1; break }
        if (bad) { skipped[$1]++; next }
        n[$1]++
        cyc[$1]+=$3
        load[$1]+=$4; l1d_repl[$1]+=$5; store[$1]+=$6
        l1i[$1]+=$7; branch[$1]+=$8; llc_ref[$1]+=$9; llc_miss[$1]+=$10
        inst[$1]+=$12; corecyc[$1]+=$13
    }
    END {
        max=0; wl=""
        for (p in rows_by_pid) if (rows_by_pid[p]>max) { max=rows_by_pid[p]; wl=p }
        if (wl=="") { print bench" no data"; exit }
        share=100*rows_by_pid[wl]/(NR)
        ipc = (corecyc[wl]>0) ? inst[wl]/corecyc[wl] : 0
        printf "%s wall=%ds missed=%s n=%d workload_share=%.3f%% skipped=%d inst=%.0f load=%.0f store=%.0f branch=%.0f l1d_repl=%.0f l1i_miss=%.0f llc_ref=%.0f llc_miss=%.0f corecyc=%.0f cyc_ref=%.0f ipc=%.3f\n",
               bench, wall, missed, n[wl], share, skipped[wl]+0,
               inst[wl], load[wl], store[wl], branch[wl],
               l1d_repl[wl], l1i[wl], llc_ref[wl], llc_miss[wl],
               corecyc[wl], cyc[wl], ipc
    }' "$csv" | tee -a "$SUMMARY"

    echo "--- dmesg tail ---"
    dmesg | tail -5

    rmmod pmu_sync_sample && echo "rmmod ok"
    echo "=== $bench done at $(date -Iseconds) ==="
    } 2>&1 | tee -a "$log"

    chown "$USER_NAME:$USER_NAME" "$csv" "$log" "$tr_err" 2>/dev/null || true
    return 0
}

#-----------------------------------------------------------------------
# main
#-----------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
    REQUESTED=("$@")
else
    REQUESTED=()
    for row in "${BENCH_LIST[@]}"; do
        read -r n _ <<<"$row"
        REQUESTED+=("$n")
    done
fi

echo "=== spec_multibench_run: ${#REQUESTED[@]} benches ===" | tee -a "$SUMMARY"
date -Iseconds | tee -a "$SUMMARY"
echo "events: $EVENTS_CONF" | tee -a "$SUMMARY"

for b in "${REQUESTED[@]}"; do
    echo
    echo "############ $b ############"
    run_one "$b" || true
done

chown "$USER_NAME:$USER_NAME" "$SUMMARY" 2>/dev/null || true
echo "=== ALL DONE. summary: $SUMMARY ==="

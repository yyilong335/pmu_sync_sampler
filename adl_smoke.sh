#!/bin/bash
# Bundled smoke test for branch adl on Alder Lake.
# Run as:
#   sudo bash adl_smoke.sh                       # default: microbench_alu, 3s
#   sudo BENCH=./benchmarks/microbench_ipc \
#        BENCH_ARGS=5000000000 \
#        bash adl_smoke.sh                       # override workload
#
# Order of operations matters: textreader has to be blocked on read
# BEFORE sampling starts, otherwise NMIs fill the 8-buffer pool with
# no reader and almost everything is dropped (missed counter spikes).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

BENCH="${BENCH:-./benchmarks/microbench_alu}"
BENCH_ARGS="${BENCH_ARGS:-3}"
BENCH_NAME="$(basename "$BENCH")"

CSV="$HERE/results/adl_${BENCH_NAME}.csv"
TR_ERR="$HERE/results/adl_${BENCH_NAME}.tr.err"
KO="$HERE/module/pmu_sync_sample.ko"
USER_NAME="${SUDO_USER:-kbh8sa}"

mkdir -p results
rm -f "$CSV" "$TR_ERR"

echo "=== environment ==="
uname -r
echo "online CPUs: $(cat /sys/devices/system/cpu/online)"
echo "branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

echo "=== preflight: ensure clean ==="
lsmod | grep -q '^pmu_sync_sample ' && rmmod pmu_sync_sample
dmesg -C

echo "=== insmod (sampler NOT armed yet) ==="
insmod "$KO"
ls -l /dev/pmu_samples

echo "=== set period and event slots from events.conf ==="
# DO NOT write 0 to /sys/sync_pmu/status here. Fresh insmod is already
# stopped (shutdown=0). Writing 0 calls stopAll() which sets shutdown=2,
# and any subsequent read on /dev/pmu_samples returns 0 (EOF) -- the
# kernel's my_read short-circuits on shutdown != 0. textreader would
# then exit immediately on launch.
echo 50000 > /sys/sync_pmu/period
slot=0
while read -r name enc _rest; do
    case "$name" in ''|\#*) continue ;; esac
    [ "$slot" -ge 8 ] && continue
    enc_dec=$((enc))
    echo "$enc_dec" > /sys/sync_pmu/$slot
    printf '  slot %d  %-18s 0x%04X\n' "$slot" "$name" "$enc_dec"
    slot=$((slot + 1))
done < "$HERE/events.conf"
while [ "$slot" -lt 8 ]; do
    echo 0 > /sys/sync_pmu/$slot
    slot=$((slot + 1))
done

echo "=== launch textreader (will block on read until sampler arms) ==="
./textreader > "$CSV" 2> "$TR_ERR" &
TR_PID=$!
sleep 0.3
if ! kill -0 "$TR_PID" 2>/dev/null; then
    echo "textreader died early; stderr:"
    cat "$TR_ERR"
    rmmod pmu_sync_sample
    exit 1
fi
echo "textreader pid=$TR_PID"

echo "=== arm sampler (status=1) ==="
echo 1 > /sys/sync_pmu/status

echo "=== run $BENCH_NAME on CPU 2 (args: $BENCH_ARGS) ==="
taskset -c 2 "$BENCH" $BENCH_ARGS

echo "=== stop sampler; textreader will hit EOF and exit on its own ==="
echo 0 > /sys/sync_pmu/status
# stopAll() in the module sets shutdown=2 and wake_up_all -- pending my_read
# returns 0, fread sets EOF, textreader's main loop exits.
wait "$TR_PID" 2>/dev/null

echo "=== results ==="
echo "missed: $(cat /sys/sync_pmu/missed)"
echo "csv lines: $(wc -l < "$CSV")"
echo "--- first 3 csv rows ---"
head -3 "$CSV"
echo "--- last 3 csv rows ---"
tail -3 "$CSV"

BENCH_ROWS=$(grep -c "${BENCH_NAME}\$" "$CSV" || true)
echo "rows whose exe ends in $BENCH_NAME: $BENCH_ROWS"
echo "distinct pids in csv:"
awk -F, '{print $1}' "$CSV" | sort -u | head

echo "--- column means over $BENCH_NAME rows (cycles, c0..c10) ---"
awk -F, -v bench="$BENCH_NAME" '
$0 ~ bench"$" {
    n++; cyc+=$3
    for (i=4; i<=14; i++) s[i]+=$i
}
END {
    if (n==0) { printf "  (no %s rows -- something wrong)\n", bench; exit }
    printf "  n=%d  cyc=%.0f", n, cyc/n
    for (i=4; i<=14; i++) printf "  c%d=%.1f", i-4, s[i]/n
    print ""
    printf "  IPC (c8/cyc) = %.3f\n", s[12]/cyc
}' "$CSV"

echo "=== dmesg tail ==="
dmesg | tail -25

echo "=== cleanup ==="
rmmod pmu_sync_sample && echo "rmmod ok"

# Hand outputs back to the invoking user so they can read without sudo
chown "$USER_NAME:$USER_NAME" "$CSV" "$TR_ERR" 2>/dev/null || true

echo "=== done; csv=$CSV ==="

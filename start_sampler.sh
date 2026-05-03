#!/bin/bash
# Arm the synchronous PMU sampler from an events config file.
#
# Usage: sudo ./start_sampler.sh <period_cycles> [events.conf]
#
# Loads module/pmu_sync_sample.ko if not already loaded, sets the period,
# writes one event encoding per non-comment line of events.conf into
# /sys/sync_pmu/<slot>, zeros any unused slots, and starts sampling.

set -e

PERIOD="${1:?usage: $0 <period_cycles> [events.conf]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="${2:-$HERE/events.conf}"
KO="$HERE/module/pmu_sync_sample.ko"

[ -f "$CONF" ] || { echo "events file not found: $CONF" >&2; exit 1; }
[ -f "$KO" ]   || { echo "module not built: $KO"       >&2; exit 1; }

if ! lsmod | grep -q '^pmu_sync_sample '; then
    insmod "$KO"
fi

echo 0 > /sys/sync_pmu/status
echo "$PERIOD" > /sys/sync_pmu/period

slot=0
while read -r name enc _rest; do
    case "$name" in ''|\#*) continue ;; esac
    if [ "$slot" -ge 8 ]; then
        echo "warning: more than 8 entries in $CONF, ignoring '$name'" >&2
        continue
    fi
    enc_dec=$((enc))
    echo "$enc_dec" > /sys/sync_pmu/$slot
    printf '  slot %d  %-18s 0x%04X\n' "$slot" "$name" "$enc_dec"
    slot=$((slot + 1))
done < "$CONF"

while [ "$slot" -lt 8 ]; do
    echo 0 > /sys/sync_pmu/$slot
    slot=$((slot + 1))
done

echo 1 > /sys/sync_pmu/status
echo "Sampler armed: period=$PERIOD, conf=$CONF"

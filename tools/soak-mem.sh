#!/bin/bash
# Memory soak logger for the RA81: one CSV row per interval with MemAvailable,
# SUnreclaim, the NSS skb count, allocation failures and load, sampled over SSH
# (nothing is written on the router). Optionally runs a bidirectional iperf3 load
# through the router in parallel (needs tools/bench-netns.sh up).
#   tools/soak-mem.sh [-d seconds] [-i interval] [-o file.csv] [--load]
# A steady climb of sunreclaim_kb / nss_skb_count = leak; a plateau = pools filling.
set -euo pipefail

DUR=10800 INT=60 OUT= LOAD=0
while [ $# -gt 0 ]; do
	case $1 in
	-d) DUR=$2; shift 2 ;;
	-i) INT=$2; shift 2 ;;
	-o) OUT=$2; shift 2 ;;
	--load) LOAD=1; shift ;;
	*) echo "usage: $0 [-d seconds] [-i interval] [-o file.csv] [--load]" >&2; exit 2 ;;
	esac
done
OUT=${OUT:-soak-$(date +%Y%m%d-%H%M).csv}
SERVER=10.0.0.51
R="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 root@10.0.0.3"

sample='awk "/^MemAvailable/{a=\$2} /^SUnreclaim/{u=\$2} /^MemFree/{f=\$2} END{printf \"%s,%s,%s,\", a, u, f}" /proc/meminfo
awk "/drv_nss_skb_count/{printf \"%s,\", \$3}" /sys/kernel/debug/qca-nss-drv/stats/drv
printf "%s,%s," "$(dmesg | grep -c "page allocation failure")" "$(cut -d" " -f1 /proc/loadavg)"
awk "/^cpu /{printf \"%d\\n\", 100*\$5/(\$2+\$3+\$4+\$5+\$6+\$7+\$8)}" /proc/stat'

iperf_pid=
cleanup() { [ -n "$iperf_pid" ] && kill "$iperf_pid" 2>/dev/null || true; }
trap cleanup EXIT

if [ "$LOAD" = 1 ]; then
	SRCIP=$(ip -4 -o addr show wlp2s0 | awk '{print $4}' | cut -d/ -f1)
	iperf3 -c "$SERVER" -B "$SRCIP" -t "$DUR" -P 4 --bidir -f m >"${OUT%.csv}.iperf.txt" 2>&1 &
	iperf_pid=$!
fi

echo "time,mem_avail_kb,sunreclaim_kb,mem_free_kb,nss_skb_count,alloc_failures,load1,cpu_idle_since_boot_pct" >"$OUT"
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
	row=$($R "$sample" 2>/dev/null | tr -d '\n') || row=
	echo "$(date +%H:%M:%S),${row:-,,,,,,}" | tee -a "$OUT"
	sleep "$INT"
done
echo "done: $OUT"

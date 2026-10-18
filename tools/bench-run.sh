#!/bin/bash
# One iperf3 run through the RA81 (Wi-Fi client -> router -> wired netns server)
# with the router's CPU use and ECM counters over the run.
#   tools/bench-run.sh <label> [iperf3 args...]      e.g. tools/bench-run.sh "dl 4" -R -P 4
# Wired client (tools/bench-wired.sh): CLIENT_PREFIX="ip netns exec lanc" SRCIP=... SSH_PREFIX="sudo -u me"
# Router-role bench: SERVER=172.16.0.1 ROUTER=192.168.1.1 tools/bench-run.sh ...
set -euo pipefail
label=$1; shift
SERVER=${SERVER:-10.0.0.51}
SRCIP=${SRCIP:-$(ip -4 -o addr show wlp2s0 | awk '{print $4}' | cut -d/ -f1)}
R="${SSH_PREFIX:-} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@${ROUTER:-10.0.0.3}"
snap='grep -E "^cpu[0-9 ]" /proc/stat; E=/sys/kernel/debug/ecm/ecm_nss_ipv4; echo "ecm $(cat $E/tcp_accelerated_count) $(cat $E/accelerated_count)"; echo "wan $(cat /sys/class/net/wan/statistics/rx_bytes) $(cat /sys/class/net/wan/statistics/tx_bytes)"'

a=$($R "$snap")
out=$(${CLIENT_PREFIX:-} iperf3 -c $SERVER -B "$SRCIP" -t 20 -O 2 -f m "$@")
b=$($R "$snap")

rate=$(echo "$out" | awk '/receiver/ {r=$(NF-2)} END {print r}')
python3 -I - "$label" "$rate" "$a" "$b" <<'EOF'
import sys
label, rate, a, b = sys.argv[1:]
def parse(s):
    d = {}
    for l in s.splitlines():
        f = l.split()
        d[f[0]] = list(map(int, f[1:]))
    return d
A, B = parse(a), parse(b)
cpus = []
for c in ('cpu', 'cpu0', 'cpu1'):
    x = [q - p for p, q in zip(A[c], B[c])]
    tot = sum(x) or 1
    # user nice system idle iowait irq softirq
    cpus.append(f"{c} idle {100*x[3]/tot:.0f}% sirq {100*x[6]/tot:.0f}%")
ecm = B['ecm'][0] - A['ecm'][0]
wan = [(q - p) * 8 / 1e6 / 22 for p, q in zip(A['wan'], B['wan'])]
print(f"{label:10s} {rate:>7s} Mbit/s | {' | '.join(cpus)} | ecm tcp accel +{ecm} | uplink port rx {wan[0]:.0f} tx {wan[1]:.0f} Mbit/s")
EOF

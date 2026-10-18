#!/bin/bash
# Wired-LAN-client NAT bench (RA81 as router): a spare NIC cabled to a RA81 LAN port
# goes into netns "lanc" (192.168.1.50/24, gw 192.168.1.1) and runs iperf3 to the
# "internet" netns of tools/bench-nat.sh (172.16.0.1, must be up).
#   sudo tools/bench-wired.sh [NIC]    # up, 4 runs (ul/dl x 1/4 streams), down
# Needs root for the netns; router counters are read over ssh as the invoking user.
set -euo pipefail
NIC=${1:-enp0s20f0u2u1}
NS=lanc
TOP=$(cd "$(dirname "$0")/.." && pwd)
ME=${SUDO_USER:?run with sudo}
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH

cleanup() {
	ip -n $NS link set $NIC netns 1 2>/dev/null || true
	ip netns del $NS 2>/dev/null || true
}
trap cleanup EXIT

ip netns add $NS
ip link set $NIC netns $NS
ip -n $NS addr add 192.168.1.50/24 dev $NIC
ip -n $NS link set lo up
ip -n $NS link set $NIC up
ip -n $NS route add default via 192.168.1.1
sleep 4
ip netns exec $NS ping -c2 -W2 172.16.0.1 >/dev/null || { echo "no path to 172.16.0.1 (is bench-nat.sh up and $NIC cabled to a LAN port?)"; exit 1; }

export SERVER=172.16.0.1 ROUTER=192.168.1.1 SRCIP=192.168.1.50
export CLIENT_PREFIX="ip netns exec $NS" SSH_PREFIX="sudo -u $ME"
for r in "wired ul 1:" "wired ul 4:-P 4" "wired dl 1:-R" "wired dl 4:-R -P 4"; do
	# shellcheck disable=SC2086
	"$TOP/tools/bench-run.sh" "${r%%:*}" ${r#*:}
done

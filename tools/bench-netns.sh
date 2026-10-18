#!/bin/sh
# Wired iperf3 endpoint for the RA81 forwarding bench, in a network namespace.
#   sudo sh tools/bench-netns.sh up     # macvlan on the 2.5G NIC, 10.0.0.51/23, iperf3 -s,
#                                   # wlp2s0 onto the RA81 test AP
#   sudo sh tools/bench-netns.sh down   # remove everything, wlp2s0 back to APT22
# Runtime state only: nothing survives a reboot.
set -eu
NS=ra81s
PARENT=enp0s20f0u6
IP=10.0.0.51/23
IPERF=/home/linuxbrew/.linuxbrew/bin/iperf3

case "${1:-}" in
up)
	ip netns add $NS
	ip link add link $PARENT name ra81mv type macvlan mode bridge
	ip link set ra81mv netns $NS
	ip -n $NS addr add $IP dev ra81mv
	ip -n $NS link set lo up
	ip -n $NS link set ra81mv up
	# The host must not answer ARP on the wire for its Wi-Fi address,
	# or the replies would skip the RA81 (restored by "down").
	sysctl -q -w net.ipv4.conf.$PARENT.arp_ignore=1
	ip netns exec $NS $IPERF -s -D -B ${IP%/*}
	echo "iperf3 server on ${IP%/*} in netns $NS"
	nmcli con up RA81-iperf
	;;
down)
	ip netns pids $NS 2>/dev/null | xargs -r kill
	ip netns del $NS 2>/dev/null || true
	sysctl -q -w net.ipv4.conf.$PARENT.arp_ignore=0
	echo "removed netns $NS"
	nmcli con up APT22
	;;
*)
	echo "usage: $0 up|down" >&2
	exit 2
	;;
esac

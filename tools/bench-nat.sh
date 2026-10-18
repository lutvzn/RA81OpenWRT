#!/bin/sh
# "Internet" side for the RA81 router-role (WAN<->LAN NAT) bench, in a netns.
#   sudo sh tools/bench-nat.sh up     # eno1 (cabled to the RA81 WAN port) moved into netns
#                                     # "inet" as 172.16.0.1/24 with an iperf3 server; host
#                                     # route to it via the RA81 LAN (wlp2s0, 192.168.1.1)
#   sudo sh tools/bench-nat.sh down   # eno1 back to the main namespace, route removed
# The RA81 must have wan = static 172.16.0.2/24, gateway 172.16.0.1 (tools/bench-nat.sh
# does not touch it). Runtime state only: nothing survives a reboot.
set -eu
NS=inet
NIC=eno1
IP=172.16.0.1/24
GW=192.168.1.1
IPERF=/home/linuxbrew/.linuxbrew/bin/iperf3

case "${1:-}" in
up)
	ip netns add $NS
	ip link set $NIC netns $NS
	ip -n $NS addr add $IP dev $NIC
	ip -n $NS link set lo up
	ip -n $NS link set $NIC up
	ip -n $NS route add default via 172.16.0.2
	ip route replace 172.16.0.0/24 via $GW dev wlp2s0
	ip netns exec $NS $IPERF -s -D -B ${IP%/*}
	echo "iperf3 server on ${IP%/*} in netns $NS; client route via $GW"
	;;
down)
	ip netns pids $NS 2>/dev/null | xargs -r kill
	ip -n $NS link set $NIC netns 1 2>/dev/null || true
	ip netns del $NS 2>/dev/null || true
	ip route del 172.16.0.0/24 via $GW dev wlp2s0 2>/dev/null || true
	echo "removed netns $NS, $NIC back in the main namespace"
	;;
*)
	echo "usage: $0 up|down" >&2
	exit 2
	;;
esac

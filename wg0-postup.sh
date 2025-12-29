#!/bin/sh
EXT_IF="eth0"
WG_IF="wg0"
WG_NET="10.1.1.1"
CAKE_MARK=1
CAKE_LIMIT=""

/sbin/iptables -A FORWARD -i $WG_IF -o $EXT_IF -j ACCEPT
/sbin/iptables -A FORWARD -i $EXT_IF -o $WG_IF -m state --state ESTABLISHED,RELATED -j ACCEPT
/sbin/iptables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE
/sbin/iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
/sbin/iptables -t mangle -A POSTROUTING -s $WG_NET -o $EXT_IF -j MARK --set-mark $CAKE_MARK
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
/sbin/tc qdisc del dev $EXT_IF root 2>/dev/null || true
if [ -n "$CAKE_LIMIT" ]; then
/sbin/tc qdisc add dev $EXT_IF root cake bandwidth $CAKE_LIMIT besteffort separate-flow triple-isolate nonat
else
/sbin/tc qdisc add dev $EXT_IF root cake besteffort separate-flow triple-isolate nonat
fi
/sbin/tc filter add dev $EXT_IF protocol ip parent 1:0 prio 1 handle $CAKE_MARK fw flowid 1:1 2>/dev/null || true

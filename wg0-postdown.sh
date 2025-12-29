#!/bin/sh
EXT_IF="eth0"
WG_IF="wg0"
WG_NET="10.1.1.1"
CAKE_MARK=1

/sbin/iptables -D FORWARD -i $WG_IF -o $EXT_IF -j ACCEPT 2>/dev/null || true
/sbin/iptables -D FORWARD -i $EXT_IF -o $WG_IF -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
/sbin/iptables -t nat -D POSTROUTING -o $EXT_IF -j MASQUERADE 2>/dev/null || true
/sbin/iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
/sbin/iptables -t mangle -D POSTROUTING -s $WG_NET -o $EXT_IF -j MARK --set-mark $CAKE_MARK 2>/dev/null || true
/sbin/tc qdisc del dev $EXT_IF root 2>/dev/null || true

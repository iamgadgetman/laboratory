#!/bin/bash
# lab-border: a ONE-WAY door from the real Fort LAN into the GNS3 lab.
#   eth0  10.40.0.27    real Fort LAN (GNS3 Cloud node bridged to the host NIC)
#   eth1  10.140.2.62   lab Fort DMZ
# Real halt routes the lab ranges here. Traffic is MASQUERADEd into the lab, so
# the lab needs no routes back and never learns production addresses. Nothing
# the lab starts can cross to eth0: FORWARD is default-deny and only
# real->lab NEW connections are accepted.
#
# Sanitized per docs/SANITIZATION.md. In production the real side is matched as
# a single RFC 1918 block; here the real site blocks are listed explicitly so
# they don't overlap the sanitized lab ranges.
set -e
LAB_NETS="10.140.0.0/22 10.120.0.0/23 10.120.3.0/24"   # see README: why not 10.120.0.0/22
REAL_NETS="10.40.0.0/22 10.20.0.0/22"

# GNS3 attaches and addresses the interfaces after the container starts
for _ in $(seq 60); do
  ip -4 addr show eth0 | grep -q inet && ip -4 addr show eth1 | grep -q inet && break
  sleep 1
done

sysctl -qw net.ipv4.ip_forward=1
for n in $LAB_NETS;  do ip route replace "$n" via 10.140.2.100 dev eth1; done   # lab halt
for n in $REAL_NETS; do ip route replace "$n" via 10.40.0.100 dev eth0; done    # real halt

iptables -P FORWARD DROP
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for n in $REAL_NETS; do
  iptables -A FORWARD -i eth0 -o eth1 -s "$n" -m conntrack --ctstate NEW -j ACCEPT
  iptables -t nat -A POSTROUTING -o eth1 -s "$n" -j MASQUERADE
done

echo "lab-border up: $(ip -br -4 addr | tr '\n' ' ')"
exec sleep infinity

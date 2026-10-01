#!/bin/sh
set -eu

while [ ! -e /run/lab/ready ]; do sleep 1; done
dnsmasq --keep-in-foreground --conf-file=/etc/dnsmasq.conf &
chronyd -d -x -f /etc/chrony.conf &
exec /usr/lib/frr/docker-start

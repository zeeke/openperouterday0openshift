FROM quay.io/frrouting/frr:10.6.1

RUN apk add --no-cache dnsmasq chrony
COPY --chown=frr:frr daemons frr.conf vtysh.conf /etc/frr/
COPY dnsmasq.conf /etc/dnsmasq.conf
COPY chrony.conf /etc/chrony.conf
COPY --chmod=755 start.sh /usr/local/bin/tor-start
CMD ["/usr/local/bin/tor-start"]

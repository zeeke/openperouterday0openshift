#!/usr/bin/env bash
set -euo pipefail

# Run an external FRR instance as a TOR with ISIS + SRv6 + iBGP.
# Peers with all PE nodes for L3VPN (ipv4/ipv6 vpn) via SRv6.
# No L2 EVPN / VXLAN — this node does L3VPN only.
#
# Creates:
#   - Loopback addresses (Router ID, IPv6, SRv6 source)
#   - VRF "red" with a dummy loopback (lored)
#   - SRv6 sysctls
#   - FRR container with ISIS + BGP + SRv6 config
#   - DNS server in VRF for cluster access
#
# Usage:
#   ./run_frr.sh

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
ISIS_IFACE="${ISIS_IFACE:-sno-labbm}"

BGP_AS="${BGP_AS:-65500}"
IFS=' ' read -ra PE_INDICES <<< "${PE_INDICES:-2 3 4 5 6}"

# Addressing — fixed IPs for external FRR remotepe
ROUTER_ID="${ROUTER_ID:-10.0.0.20}"
LOOPBACK_V6="${LOOPBACK_V6:-fc00:0:20::1}"
SRV6_SOURCE="${SRV6_SOURCE:-fd00:20::1}"
SRV6_PREFIX="${SRV6_PREFIX:-fd00:20::/48}"
UNDERLAY_V6="${UNDERLAY_V6:-fc00:100::20}"
ISIS_NET="${ISIS_NET:-49.0001.0000.0000.0020.00}"
VRF_LO_V4="${VRF_LO_V4:-10.10.20.1/32}"
VRF_LO_V6="${VRF_LO_V6:-fc00:10:20::1/128}"

VRF_NAME="red"
VRF_TABLE=1100

VTEP_LO="lo-und"
LO_NAME="lo-extra"
LO_IP="${LO_IP:-10.100.0.1/32}"
DNS_LISTEN_IP="${DNS_LISTEN_IP:-10.100.0.1}"
CLUSTER_NAME="${CLUSTER_NAME:-sno-lab}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
API_VIP="${API_VIP:-192.168.110.10}"
INGRESS_VIP="${INGRESS_VIP:-192.168.110.11}"
CONTAINER_NAME="externalfrr"
FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.5.1}"
FRR_CONF_DIR="${SCRIPTDIR}/config"

echo "============================================="
echo "External FRR — RemotePE (ISIS + SRv6)"
echo "============================================="
echo "  ISIS iface:     ${ISIS_IFACE}"
echo "  Router ID:      ${ROUTER_ID}"
echo "  Loopback IPv6:  ${LOOPBACK_V6}"
echo "  SRv6 source:    ${SRV6_SOURCE}"
echo "  SRv6 prefix:    ${SRV6_PREFIX}"
echo "  ISIS NET:       ${ISIS_NET}"
echo "  BGP AS:         ${BGP_AS}"
echo "  PE indices:     ${PE_INDICES[*]}"
echo "  VRF:            ${VRF_NAME} (table ${VRF_TABLE})"
echo "  FRR image:      ${FRR_IMAGE}"
echo ""

# --- Loopback interface for Router ID + IPv6 ---
echo "Creating loopback ${VTEP_LO}..."
if ip link show "${VTEP_LO}" &>/dev/null; then
    echo "  ${VTEP_LO} already exists, skipping"
else
    sudo ip link add "${VTEP_LO}" type dummy
    sudo ip link set "${VTEP_LO}" up
fi
sudo ip addr add "${ROUTER_ID}/32" dev "${VTEP_LO}" 2>/dev/null || true
sudo ip -6 addr add "${LOOPBACK_V6}/128" dev "${VTEP_LO}" 2>/dev/null || true
sudo ip -6 addr add "${SRV6_SOURCE}/128" dev "${VTEP_LO}" 2>/dev/null || true
sudo sysctl -w "net.ipv4.conf.${VTEP_LO}.rp_filter=0" >/dev/null

# --- Underlay IPv6 on ISIS interface ---
echo "Adding underlay IPv6 ${UNDERLAY_V6}/64 to ${ISIS_IFACE}..."
sudo ip -6 addr add "${UNDERLAY_V6}/64" dev "${ISIS_IFACE}" 2>/dev/null || true
sudo sysctl -w "net.ipv4.conf.${ISIS_IFACE}.rp_filter=0" >/dev/null

# --- SRv6 sysctls ---
echo "Setting SRv6 sysctls..."
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
sudo sysctl -w net.ipv6.seg6_flowlabel=1 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv6.conf.all.seg6_enabled=1 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv6.conf.default.seg6_enabled=1 >/dev/null 2>&1 || true
sudo sysctl -w "net.ipv6.conf.${ISIS_IFACE}.seg6_enabled=1" >/dev/null 2>&1 || true
sudo sysctl -w net.ipv6.conf.lo.seg6_enabled=1 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true

# --- VRF ---
echo "Creating VRF ${VRF_NAME} (table ${VRF_TABLE})..."
if ip link show "${VRF_NAME}" &>/dev/null; then
    echo "  ${VRF_NAME} already exists, skipping"
else
    sudo ip link add "${VRF_NAME}" type vrf table "${VRF_TABLE}"
    sudo ip link set "${VRF_NAME}" up
    sudo firewall-cmd --zone=trusted --add-interface="${VRF_NAME}" 2>/dev/null || true
fi
sudo sysctl -w "net.ipv4.conf.${VRF_NAME}.rp_filter=0" >/dev/null 2>&1 || true

# --- VRF strict mode (must be set AFTER creating the first VRF, otherwise the sysctl is not available) ---
# seg6local End.DT46 with vrftable requires strict_mode=1
echo "Enabling VRF strict mode..."
sudo sysctl -w net.vrf.strict_mode=1 >/dev/null

# --- Bypass conntrack for VRF traffic (firewalld drops ct state invalid) ---
echo "Adding nftables notrack rules for VRF ${VRF_NAME}..."
sudo nft -f - <<NFT
table inet srv6-vrf-notrack
delete table inet srv6-vrf-notrack
table inet srv6-vrf-notrack {
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        iifname "${VRF_NAME}" notrack
    }
    chain output {
        type filter hook output priority raw; policy accept;
        oifname "${VRF_NAME}" notrack
    }
}
NFT

# --- VRF loopback (lored) ---
echo "Creating VRF loopback 'lored'..."
if ip link show "lored" &>/dev/null; then
    echo "  lored already exists, skipping"
else
    sudo ip link add lored type dummy
    sudo ip link set lored master "${VRF_NAME}"
    sudo ip link set lored up
fi
sudo ip addr add "${VRF_LO_V4}" dev lored 2>/dev/null || true
sudo ip -6 addr add "${VRF_LO_V6}" dev lored 2>/dev/null || true
sudo sysctl -w net.ipv4.conf.lored.rp_filter=0 >/dev/null

# --- Extra loopback for DNS ---
echo "Creating loopback ${LO_NAME} with ${LO_IP}..."
if ip link show "${LO_NAME}" &>/dev/null; then
    echo "  ${LO_NAME} already exists, skipping"
else
    sudo ip link add "${LO_NAME}" type dummy
    sudo ip link set "${LO_NAME}" master "${VRF_NAME}"
    sudo ip addr add "${LO_IP}" dev "${LO_NAME}"
    sudo ip link set "${LO_NAME}" up
fi
sudo sysctl -w "net.ipv4.conf.${LO_NAME}.rp_filter=0" >/dev/null

# --- Build PE neighbor lines ---
PE_NEIGHBOR_LINES=""
for idx in "${PE_INDICES[@]}"; do
    PE_NEIGHBOR_LINES+=" neighbor fc00:0:${idx}::1 peer-group PE-NODES
"
    PE_NEIGHBOR_LINES+=" neighbor fd00::${idx} peer-group PE-NODES
"
done

# --- Generate FRR configuration ---
mkdir -p "${FRR_CONF_DIR}"

cat > "${FRR_CONF_DIR}/frr.conf" <<EOF
log file /etc/frr/frr.log debug

debug zebra events
debug bgp zebra
debug bgp updates
debug bgp neighbor-events
!
interface ${ISIS_IFACE}
 ipv6 router isis PE
exit
!
interface ${VTEP_LO}
 ipv6 router isis PE
 isis passive
exit
!
router bgp ${BGP_AS}
 bgp router-id ${ROUTER_ID}
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 no bgp network import-check
 bgp log-neighbor-changes
 !
 neighbor PE-NODES peer-group
 neighbor PE-NODES capability extended-nexthop
 neighbor PE-NODES remote-as ${BGP_AS}
 neighbor PE-NODES update-source ${LOOPBACK_V6}
${PE_NEIGHBOR_LINES} !
 segment-routing srv6
  locator MAIN
  encap-behavior H_Encaps_Red
 exit
 !
 address-family ipv4 vpn
  neighbor PE-NODES activate
 exit-address-family
 !
 address-family ipv6 vpn
  neighbor PE-NODES activate
 exit-address-family
exit
!
router bgp ${BGP_AS} vrf ${VRF_NAME}
 bgp router-id ${ROUTER_ID}
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 no bgp network import-check
 sid vpn per-vrf export auto
 !
 address-family ipv4 unicast
  network ${VRF_LO_V4}
  network ${LO_IP}
  rd vpn export ${ROUTER_ID}:2
  rt vpn both ${BGP_AS}:2
  export vpn
  import vpn
 exit-address-family
 !
 address-family ipv6 unicast
  network ${VRF_LO_V6}
  rd vpn export ${ROUTER_ID}:2
  rt vpn both ${BGP_AS}:2
  export vpn
  import vpn
 exit-address-family
exit
!
router isis PE
 is-type level-1
 net ${ISIS_NET}
 lsp-gen-interval 2
 log-adjacency-changes
 log-pdu-drops
 segment-routing srv6
  locator MAIN
 exit
exit
!
segment-routing
 srv6
  encapsulation
   source-address ${SRV6_SOURCE}
  exit
  locators
   locator MAIN
    prefix ${SRV6_PREFIX} block-len 32 node-len 16 func-bits 16
    behavior usid
   exit
  exit
 exit
exit
!
end
EOF

cat > "${FRR_CONF_DIR}/daemons" <<EOF
zebra=yes
bgpd=yes
isisd=yes
staticd=yes
bfdd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
fabricd=no
vrrpd=no
pathd=no
EOF

cat > "${FRR_CONF_DIR}/vtysh.conf" <<EOF
service integrated-vtysh-config
EOF

echo "FRR config written to ${FRR_CONF_DIR}/"

# --- Run FRR container ---
echo "Starting FRR container '${CONTAINER_NAME}'..."
if sudo podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "  Container already exists, removing..."
    sudo podman rm -f "${CONTAINER_NAME}"
fi

sudo podman run -d \
    --name "${CONTAINER_NAME}" \
    --network=host \
    --privileged \
    -v "${FRR_CONF_DIR}/frr.conf:/etc/frr/frr.conf:Z" \
    -v "${FRR_CONF_DIR}/daemons:/etc/frr/daemons:Z" \
    -v "${FRR_CONF_DIR}/vtysh.conf:/etc/frr/vtysh.conf:Z" \
    "${FRR_IMAGE}"

# --- DNS server in VRF red ---
DNS_PID_FILE="/run/dnsmasq-vrf-${VRF_NAME}.pid"
DNS_CONF="${FRR_CONF_DIR}/dnsmasq.conf"

if [ -n "${API_VIP}" ] && [ -n "${INGRESS_VIP}" ]; then
    echo "Setting up DNS server in VRF ${VRF_NAME} on ${LO_NAME} (${DNS_LISTEN_IP})..."

    for pid in $(pgrep -f "dnsmasq.*${DNS_LISTEN_IP}" 2>/dev/null); do
        echo "  Killing existing dnsmasq (PID ${pid})..."
        sudo kill "${pid}" 2>/dev/null || true
    done
    sudo rm -f "${DNS_PID_FILE}"
    sleep 1

    cat > "${DNS_CONF}" <<DNSEOF
address=/api.${CLUSTER_DOMAIN}/${API_VIP}
address=/api-int.${CLUSTER_DOMAIN}/${API_VIP}
address=/.apps.${CLUSTER_DOMAIN}/${INGRESS_VIP}
DNSEOF

    echo "  DNS config: api.${CLUSTER_DOMAIN} -> ${API_VIP}"
    echo "  DNS config: *.apps.${CLUSTER_DOMAIN} -> ${INGRESS_VIP}"

    sudo ip vrf exec "${VRF_NAME}" dnsmasq \
        --pid-file="${DNS_PID_FILE}" \
        --conf-file="${DNS_CONF}" \
        --no-dhcp-interface="${LO_NAME}" \
        --listen-address="${DNS_LISTEN_IP}" \
        --bind-interfaces \
        --no-resolv \
        --no-hosts

    echo "DNS server running at ${DNS_LISTEN_IP} in VRF ${VRF_NAME}."
else
    echo "Skipping DNS server (set API_VIP and INGRESS_VIP to enable)."
fi

# --- NTP server in VRF red ---
CHRONY_CONF="${FRR_CONF_DIR}/chrony-vrf.conf"
CHRONY_PID="/run/chronyd-vrf.pid"

echo "Setting up NTP server in VRF ${VRF_NAME} on ${DNS_LISTEN_IP}..."

for pid in $(pgrep -f "chronyd.*chrony-vrf" 2>/dev/null); do
    echo "  Killing existing chronyd (PID ${pid})..."
    sudo kill "${pid}" 2>/dev/null || true
done
sudo rm -f "${CHRONY_PID}"
sleep 1

cat > "${CHRONY_CONF}" <<NTPEOF
local stratum 3 orphan
allow all
bindaddress ${DNS_LISTEN_IP}
port 123
driftfile /var/run/chrony-vrf.drift
pidfile ${CHRONY_PID}
NTPEOF

sudo ip vrf exec "${VRF_NAME}" chronyd -f "${CHRONY_CONF}" -x

echo "NTP server running at ${DNS_LISTEN_IP} in VRF ${VRF_NAME}."

echo ""
echo "FRR is running. Useful commands:"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show isis neighbor'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show bgp summary'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show bgp ipv4 vpn'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show segment-routing srv6 locator'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh"
echo ""
echo "L3VPN test (from VRF — ping master-0 br0):"
echo "  sudo ip vrf exec ${VRF_NAME} ping 192.168.110.2"
echo ""

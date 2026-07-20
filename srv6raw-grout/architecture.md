# srv6raw-grout Architecture

## Overview

This directory builds two ISO images that together deploy an OpenShift cluster
with SRv6 + EVPN routing powered by grout (DPDK dataplane) and FRR.

- **Appliance ISO** — CoreOS live image with OpenShift + all OpenPERouter
  scripts, quadlets, and container images baked in.
- **Config ISO** — Per-cluster configuration (install-config, agent-config,
  MachineConfigs) mounted at first boot by the appliance.

Build-time scripts on the host compile butane sources, inject ignition, and
embed kernel args into the ISOs. The injected content then runs inside each
OpenShift node at bootstrap to stand up the SRv6/EVPN fabric before the
cluster is fully formed.

---

## Diagram: Build-Time Flow

```
 HOST (build time)
 ═══════════════════════════════════════════════════════════════════════

 ┌─────────────────────────────────────────────────────────────────────┐
 │                    APPLIANCE ISO PIPELINE                          │
 │                                                                    │
 │  appliance-config.yaml.base                                        │
 │         + pull-secret.json                                         │
 │                │                                                   │
 │                ▼                                                   │
 │  ┌──────────────────────────┐                                      │
 │  │  generate_appliance.sh   │  ◄── entry point                     │
 │  └────────────┬─────────────┘                                      │
 │               │                                                    │
 │               │ 1. renders appliance-config.yaml                   │
 │               │ 2. runs appliance builder container (podman)       │
 │               │ 3. produces appliance.iso                          │
 │               │                                                    │
 │               ▼                                                    │
 │  ┌──────────────────────────┐      ┌───────────────────────────┐   │
 │  │  patch_appliance.sh      │◄─────│ openperouter-raw.bu       │   │
 │  │                          │      │  (butane ──files-dir=     │   │
 │  │  • compiles .bu → ign    │      │   extras/)                │   │
 │  │  • merges ignition:      │      │                           │   │
 │  │   original + openperouter│      │  embeds ALL extras/ files:│   │
 │  │    + extras (mirrors,    │      │   rawconfig/*             │   │
 │  │      hosts, ssh key)     │      │   quadlets/*              │   │
 │  │  • embeds merged ign     │      │   common/*                │   │
 │  │    into ISO              │      │   manifests/*             │   │
 │  │  • adds kernel args:     │      │   registry/*              │   │
 │  │    hugepages, iommu, etc │      └───────────────────────────┘   │
 │  └────────────┬─────────────┘                                      │
 │               │                                                    │
 │               ▼                                                    │
 │  ┌──────────────────────────┐                                      │
 │  │  hackagent.sh (optional) │                                      │
 │  │                          │                                      │
 │  │  • extracts ignition     │                                      │
 │  │  • injects inline        │                                      │
 │  │    ignition-hack.sh +    │                                      │
 │  │    ignition-hack.service │                                      │
 │  │  • re-embeds ignition    │                                      │
 │  └────────────┬─────────────┘                                      │
 │               │                                                    │
 │               ▼                                                    │
 │         appliance.iso (final)                                      │
 └─────────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────────┐
 │                    CONFIG ISO PIPELINE                              │
 │                                                                    │
 │  install-config.yaml.base                                          │
 │  agent-config.yaml                                                 │
 │  *.bu files                                                        │
 │         │                                                          │
 │         ▼                                                          │
 │  ┌──────────────────────────┐                                      │
 │  │ generate_config_image.sh │  ◄── entry point                     │
 │  └────────────┬─────────────┘                                      │
 │               │                                                    │
 │               │ 1. renders install-config.yaml                     │
 │               │ 2. copies agent-config.yaml                        │
 │               │                                                    │
 │               ▼                                                    │
 │  ┌──────────────────────────┐      ┌───────────────────────────┐   │
 │  │ generate_machineconfigs  │◄─────│  .bu files:               │   │
 │  │          .sh             │      │   openperouter-raw.bu     │   │
 │  │                          │      │     → 99-master-*.yaml    │   │
 │  │  butane --files-dir=     │      │   openperouter-raw-       │   │
 │  │    extras/               │      │     worker.bu             │   │
 │  │                          │      │     → 99-worker-*.yaml    │   │
 │  │  (same extras/ tree      │      │   registry.bu             │   │
 │  │   compiled into          │      │     → 01-master-*.yaml    │   │
 │  │   MachineConfig YAMLs)   │      │   registry-worker.bu      │   │
 │  │                          │      │     → 01-worker-*.yaml    │   │
 │  └────────────┬─────────────┘      └───────────────────────────┘   │
 │               │                                                    │
 │               │ 3. also copies performance-profile.yaml            │
 │               │                                                    │
 │               ▼                                                    │
 │  ┌──────────────────────────┐                                      │
 │  │ openshift-install agent  │                                      │
 │  │   create config-image    │                                      │
 │  └────────────┬─────────────┘                                      │
 │               │                                                    │
 │               ▼                                                    │
 │       agentconfig.noarch.iso                                       │
 └─────────────────────────────────────────────────────────────────────┘

 Both ISOs are attached to each node's VM / bare-metal server:
   - appliance.iso   → boot disk / virtual DVD
   - config ISO      → secondary virtual DVD
```

---

## Diagram: Bootstrap-Time Flow (inside each node)

```
 NODE BOOTSTRAP (inside the ISO, on each OpenShift node)
 ═══════════════════════════════════════════════════════════════════════

 ┌─ PHASE 1: EARLY BOOT (live ISO environment) ─────────────────────┐
 │                                                                   │
 │  mountRegistry.sh                                                 │
 │    └─► mounts appliance ISO at /run/media/iso                     │
 │                                                                   │
 │  mount-agent-data.sh                                              │
 │    └─► mounts registry data at /mnt/agentdata                     │
 │                                                                   │
 │  load-registry-image.sh                                           │
 │    └─► loads registry container image from agent data             │
 │                                                                   │
 │  setup-local-registry.sh                                          │
 │    └─► generates TLS certs, adds DNS entry, starts registry       │
 │                                                                   │
 │  set-hostname.sh                                                  │
 │    └─► matches MAC addresses → sets hostname                      │
 │                                                                   │
 │  patch-installer-config.sh                                        │
 │    └─► enables virtual interfaces in assisted-service             │
 │    └─► disables belongs-to-majority-group validation              │
 │                                                                   │
 │  ignition-hack.sh  (from hackagent.sh, if applied)                │
 │    └─► masks reboot.target                                        │
 │    └─► fetches MCS ignition from bootstrap (192.168.110.2:22623)  │
 │    └─► merges local ignition with MCS ignition                    │
 │    └─► strips ignition merge/replace (MCS unreachable before      │
 │        SRv6 is up)                                                │
 │    └─► writes final ignition to boot partition                    │
 │    └─► resizes root partition (large disks)                       │
 │    └─► unmasks reboot.target → node reboots                       │
 └───────────────────────────────────────────────────────────────────┘

                    ─── node reboots into installed CoreOS ───

 ┌─ PHASE 2: POST-INSTALL (MachineConfig-driven, real OS) ───────────┐
 │                                                                   │
 │  can_start.sh  (gate for setup-underlay + controller)             │
 │    └─► waits for OVS network migration to complete                │
 │    └─► ensures host VF or br-ex is active via NetworkManager      │
 │                                                                   │
 │  openperouter-node-index.sh                                       │
 │    └─► reads hostVF IPv4 last octet → writes node-config.yaml     │
 │                                                                   │
 │                                                                   │
 │  ┌── MASTER NODES ────────────────────────────────────────────┐   │
 │  │                                                            │   │
 │  │  grout-bind@eno12399np0.service (underlay)                 │   │
 │  │  grout-bind@eno12399v1.service  (trunk)                    │   │
 │  │    └─► grout-bind.sh                                       │   │
 │  │      └─► binds NIC to vfio-pci (Intel) or moves to        │   │
 │  │          perouter netns (Mellanox)                          │   │
 │  │    └─► depends on routerpod-pod + nmstate +                │   │
 │  │        network-online.target (not can_start.sh)            │   │
 │  │                                                            │   │
 │  │  routerpod.pod starts                                      │   │
 │  │    └─► creates /run/netns/perouter network namespace       │   │
 │  │    └─► starts grout.container (DPDK dataplane, hugepages)  │   │
 │  │    └─► starts frr.container (zebra -M dplane_grout,        │   │
 │  │        bgpd, isisd, bfdd)                                  │   │
 │  │    └─► starts reloader.container (config watcher)          │   │
 │  │                                                            │   │
 │  │  controllerpod.pod starts                                  │   │
 │  │    └─► starts controller.container (orchestrator)          │   │
 │  │                                                            │   │
 │  └────────────────────────────────────────────────────────────┘   │
 │                                                                   │
 └───────────────────────────────────────────────────────────────────┘

 ┌─ PHASE 3: NETWORK FABRIC SETUP ───────────────────────────────────┐
 │                                                                   │
 │  setup-underlay.sh                                                │
 │    └─► waits for FRR ready (bgpd + isisd)                         │
 │    └─► derives all addressing from host VF/br-ex last octet:     │
 │        Router ID, VTEP IP, IPv6 loopback, SRv6 prefix, ISIS NET   │
 │    └─► adds underlay + trunk NICs to grout via grcli               │
 │    └─► configures IPv6, VTEP, loopback, SRv6 source addresses     │
 │    └─► saves all vars to vpn-setup.vars                           │
 │                          │                                        │
 │                          ▼                                        │
 │  setup-network.sh                                                 │
 │    └─► creates VRF "red", bridge, VXLAN, VLAN via grcli           │
 │    └─► creates L2VNI bridge br-pe-210, VXLAN vni210 (VNI 210)     │
 │                          │                                        │
 │                          ▼                                        │
 │  generate-config.sh                                               │
 │    └─► loads vpn-setup.vars + vpn-setup.env                       │
 │    └─► selects template: Route Reflector or Client                │
 │    └─► renders FRR config via envsubst                            │
 │    └─► reloader detects change → FRR reloads                      │
 │                                                                   │
 │  ═══════════ SRv6/EVPN fabric is now operational ═══════════      │
 │                                                                   │
 └───────────────────────────────────────────────────────────────────┘

 ┌─ PHASE 4: CLUSTER INTEGRATION (masters only) ────────────────────┐
 │                                                                   │
 │  apply-manifests.sh                                               │
 │    └─► waits for kubeconfig + API server reachable                │
 │    └─► writes system CPU list                                     │
 │    └─► applies namespace.yaml (openperouter-system)               │
 │    └─► substitutes __GROUT_CPUS__ / __GROUT_HUGEPAGES_1G__        │
 │    └─► applies grout-daemonset.yaml                               │
 │    └─► grants privileged SCC                                      │
 │    └─► labels node: openperouter.io/role=router                   │
 │                          │                                        │
 │                          ▼                                        │
 │  grout-reservation DaemonSet pod starts                           │
 │    └─► reservation container:                                     │
 │        • requests exclusive CPUs + hugepages from kubelet          │
 │        • reads assigned CPUs from cgroup                          │
 │        • updates grout.slice with reserved CPUs                   │
 │        • repins grout datapath threads via grcli                  │
 │    └─► metrics container:                                         │
 │        • socat proxy: grout unix socket → TCP :9111 (prometheus)  │
 │                                                                   │
 └───────────────────────────────────────────────────────────────────┘
```

---

## Cause-Effect Chains

### Chain 1: Appliance ISO — How Scripts Get Into the Image

```
CAUSE                              EFFECT
─────────────────────────────────  ─────────────────────────────────────
generate_appliance.sh runs         → appliance-config.yaml rendered
                                     from .base + pull-secret
                                   → appliance builder produces
                                     appliance.iso (bare CoreOS + OCP)

patch_appliance.sh runs            → butane compiles openperouter-raw.bu
                                     with --files-dir=extras/
                                   → ALL files under extras/ are encoded
                                     into a single ignition JSON
                                   → original ISO ignition is extracted
                                   → three ignitions merged (original +
                                     openperouter + extras)
                                   → merged ignition re-embedded into ISO
                                   → kernel args added (hugepages, iommu)

hackagent.sh runs (optional)       → ignition extracted from ISO
                                   → inline ignition-hack.sh + systemd
                                     service injected into ignition
                                   → ignition re-embedded into ISO
```

**Key insight:** `patch_appliance.sh` is the bridge between the `extras/`
directory tree and the appliance ISO. The butane file `openperouter-raw.bu`
acts as a manifest that maps every file in `extras/` to its target path on
the installed node. Butane compiles the entire tree into ignition JSON, and
the script merges that into whatever the appliance builder originally
produced.

### Chain 2: Config ISO — How MachineConfigs Get Into the Image

```
CAUSE                              EFFECT
─────────────────────────────────  ─────────────────────────────────────
generate_config_image.sh runs      → install-config.yaml rendered from
                                     .base + pull-secret
                                   → agent-config.yaml copied

generate_machineconfigs.sh runs    → butane compiles each .bu file into
                                     a MachineConfig YAML:
                                     • openperouter-raw.bu
                                       → 99-master-openperouter.yaml
                                     • openperouter-raw-worker.bu
                                       → 99-worker-openperouter.yaml
                                     • registry.bu
                                       → 01-master-registry.yaml
                                     • registry-worker.bu
                                       → 01-worker-registry.yaml
                                   → performance-profile.yaml copied

openshift-install runs             → all manifests + configs packaged
                                     into agentconfig.noarch.iso
```

**Key insight:** The same `extras/` tree is compiled twice — once for the
appliance ISO (as raw ignition via `patch_appliance.sh`) and once for the
config ISO (as MachineConfig manifests). The appliance path provides the
scripts during the live ISO phase (Phase 1); the MachineConfig path ensures
they persist after installation (Phases 2-4).

### Chain 3: Ignition Hack — Why Nodes Can Bootstrap Without SRv6

```
CAUSE                              EFFECT
─────────────────────────────────  ─────────────────────────────────────
Node boots appliance ISO in        → assisted-installer starts
live environment                   → ignition-hack.service triggers

ignition-hack.sh masks             → prevents premature reboot before
reboot.target                        ignition is rewritten

hack fetches MCS ignition from     → gets the "real" ignition that the
bootstrap (192.168.110.2:22623)      node would normally pull from the
                                     Machine Config Server

hack merges local + MCS            → combined ignition has both the
ignition                             cluster config (MCS) and local
                                     OpenPERouter customizations

hack strips ignition               → node will NOT try to fetch from
merge/replace directives             production MCS at boot (which is
                                     unreachable — SRv6 fabric isn't
                                     up yet at that point)

hack writes final ignition to      → when node reboots, CoreOS reads
boot partition                       the pre-written ignition instead
                                     of trying to contact MCS

hack resizes partitions            → large disks (>2.5TB) get sda4
(large disks only)                   capped at 2TiB + sda5 for the
                                     rest (keeps XFS agcount < 400)
```

**Key insight:** This is a chicken-and-egg problem. The MCS (Machine Config
Server) runs on the cluster network, but the cluster network depends on
SRv6, which hasn't been set up yet at first boot. The hack intercepts the
bootstrap process, grabs the ignition during the live ISO phase (when the
bootstrap node is reachable on the local network), and writes it directly
to disk so the node never needs to contact MCS over the cluster network.

### Chain 4: Grout Dataplane

```
CAUSE                              EFFECT
─────────────────────────────────  ─────────────────────────────────────
grout-bind@.service                → grout-bind.sh runs for each NIC
                                     (underlay + trunk)
                                   → NIC unbound from kernel driver
                                   → NIC bound to vfio-pci (Intel)
                                     or moved to perouter netns (Mellanox)
                                   → state file at /run/grout-bind/<nic>

routerpod.pod creates perouter     → isolated network namespace for
network namespace                    grout + FRR

grout.container starts in          → DPDK dataplane running with
routerpod, privileged, hugepages     hugepage memory, vfio access

frr.container starts with          → FRR uses grout as its dataplane
-M dplane_grout                      instead of kernel networking
                                   → packets forwarded via DPDK
                                     (high performance)

setup-underlay.sh reads            → configures underlay + trunk NICs
/run/grout-bind/<nic>                via grcli (grout CLI)
                                   → assigns IPv6, VTEP, loopback,
                                     SRv6 source addresses
```

**Key insight:** All nodes use DPDK (grout) for high-performance packet
forwarding. The `grout-bind@.service` template is instantiated for both the
underlay NIC and the trunk NIC. The separate `.bu` files for masters vs
workers exist to differentiate quadlet configurations and systemd unit
ordering.

### Chain 5: SRv6/EVPN Fabric Bringup

```
CAUSE                              EFFECT
─────────────────────────────────  ─────────────────────────────────────
can_start.sh passes                → OVS migration complete, br0 active
(ExecStartPre for setup-underlay     with IP address
 and controller)

openperouter-node-index.sh         → node-config.yaml written with
reads br0 last octet                 nodeIndex (used later for
                                     addressing)

setup-underlay.sh runs             → FRR is ready (bgpd + isisd alive)
                                   → all IPv4/IPv6 addresses derived
                                     from br0 last octet:
                                     • Router ID:  10.0.0.N
                                     • IPv6 lo:    fc00:0:N::1
                                     • SRv6 src:   fd00:N::1
                                     • SRv6 pfx:   fd00:N::/48
                                     • ISIS NET:   49.0001...N.00
                                   → underlay NIC configured (grout
                                     or kernel path)
                                   → SRv6 source address assigned on
                                     underlay NIC via grcli

setup-network.sh runs              → VRF "red" created via grcli
                                   → VXLAN vni210 created (L2VPN)
                                   → bridge br-pe-210 links VXLAN to VRF
                                   → VLAN sub-interface on trunk NIC
                                     added to bridge domain via grcli
                                   → gateway IPs assigned on bridge

generate-config.sh runs            → FRR config rendered from template
                                   → ISIS + BGP + SRv6 + EVPN configured
                                   → reloader detects new config → FRR
                                     reloads
                                   → ISIS adjacencies form with peers
                                   → SRv6 tunnels established
                                   → BGP EVPN sessions come up
```

### Chain 6: Cluster Integration (post-bootstrap)

```
CAUSE                              EFFECT
─────────────────────────────────  ─────────────────────────────────────
kubeconfig appears at               → apply-manifests.path triggers
/etc/kubernetes/kubeconfig            apply-manifests.service

apply-manifests.sh waits for       → API server reachable (SRv6 fabric
oc get ns to succeed                 is carrying traffic now)

apply-manifests.sh applies         → openperouter-system namespace
manifests                            created
                                   → grout-reservation DaemonSet
                                     deployed (with CPU/hugepage
                                     placeholders substituted)
                                   → node labeled openperouter.io/
                                     role=router

DaemonSet pod scheduled on         → reservation container starts
labeled node                       → requests exclusive CPUs from
                                     kubelet CPU manager
                                   → reads assigned CPUs from cgroup
                                   → updates grout.slice cgroup with
                                     reserved CPUs
                                   → repins grout datapath threads
                                     to dedicated cores
                                   → result: grout runs on isolated
                                     CPUs with no kernel interference

metrics container starts           → socat proxies grout unix socket
                                     metrics to TCP :9111
                                   → Prometheus can scrape grout
                                     performance data
```

### Chain 7: Registry — Disconnected Installation Support

```
CAUSE                              EFFECT
─────────────────────────────────  ─────────────────────────────────────
Node boots with appliance ISO      → mountRegistry.sh finds largest
attached as virtual DVD              ROM device, mounts at /run/media/iso

mount-agent-data.sh runs           → registry data (container images)
                                     mounted at /mnt/agentdata

load-registry-image.sh runs        → registry container image loaded
                                     from dir: format on agent data
                                   → tagged as localhost/registry:latest

setup-local-registry.sh runs       → self-signed TLS certs generated
                                   → certs installed in system trust
                                   → /etc/hosts entry added for
                                     registry.appliance.openshift.com
                                   → local registry container started
                                     serving mirrored OCP images

patch_appliance.sh injected        → registries.conf drop-in tells
registries.conf                      CRI-O to pull from local mirror
                                   → policy.json allows unsigned images
                                   → result: all OCP images served
                                     locally, no internet needed
```

---

## File Map: Where Each extras/ File Lands on the Node

| Source (extras/)                          | Target on Node                                            | Role    |
|------------------------------------------|-----------------------------------------------------------|---------|
| `rawconfig/openperouter-common.sh`       | `/usr/local/bin/openperouter-common.sh`                   | M + W   |
| `rawconfig/setup-underlay.sh`            | `/usr/local/bin/setup-underlay.sh`                        | M + W   |
| `rawconfig/setup-network.sh`             | `/usr/local/bin/setup-network.sh`                         | M + W   |
| `rawconfig/generate-config.sh`           | `/usr/local/bin/generate-config.sh`                       | M + W   |
| `rawconfig/grout-bind.sh`                | `/usr/local/bin/grout-bind.sh`                            | M + W   |
| `rawconfig/grout-unbind.sh`              | `/usr/local/bin/grout-unbind.sh`                          | M + W   |
| `rawconfig/vpn-setup.env`               | `/etc/openperouter/vpn-setup.env`                         | M + W   |
| `rawconfig/openpe_evpn.yaml.template`   | `/etc/openperouter/templates/openpe_evpn.yaml.template`   | M + W   |
| `rawconfig/openpe_evpn.yaml_rr.template`| `/etc/openperouter/templates/openpe_evpn.yaml_rr.template`| M + W   |
| `quadlets/can_start.sh`                 | `/usr/local/bin/can_start.sh`                             | M + W   |
| `quadlets/controller.container`         | `/etc/containers/systemd/controller.container`            | M + W   |
| `quadlets/controllerpod.pod`            | `/etc/containers/systemd/controllerpod.pod`               | M + W   |
| `quadlets/routerpod.pod`                | `/etc/containers/systemd/routerpod.pod`                   | M + W   |
| `quadlets/frr.container`                | `/etc/containers/systemd/frr.container`                   | M + W   |
| `quadlets/grout.container`              | `/etc/containers/systemd/grout.container`                 | M + W   |
| `quadlets/reloader.container`           | `/etc/containers/systemd/reloader.container`              | M + W   |
| `quadlets/daemons`                      | `/etc/perouter/daemons`                                   | M + W   |
| `common/apply-manifests.sh`             | `/usr/local/bin/apply-manifests.sh`                       | M only  |
| `common/openperouter-node-index.sh`     | `/usr/local/bin/openperouter-node-index.sh`               | M + W   |
| `common/patch-installer-config.sh`      | `/usr/local/bin/patch-installer-config.sh`                | M + W   |
| `manifests/namespace.yaml`              | `/var/lib/openperouter/manifests/namespace.yaml`          | M only  |
| `manifests/grout-daemonset.yaml`        | `/var/lib/openperouter/manifests/grout-daemonset.yaml`    | M only  |
| `registry/registry.env`                | `/etc/assisted/registry.env`                              | M + W   |
| `registry/mountRegistry.sh`            | `/usr/local/bin/mountRegistry.sh`                         | M + W   |
| `registry/setup-local-registry.sh`     | `/usr/local/bin/setup-local-registry.sh`                  | M + W   |
| `registry/mount-agent-data.sh`         | `/usr/local/bin/mount-agent-data.sh`                      | M + W   |
| `registry/load-registry-image.sh`      | `/usr/local/bin/load-registry-image.sh`                   | M + W   |

*M = Master, W = Worker*

---

## Systemd Service Ordering (Phase 2-3)

```
network-online.target + nmstate.service
    │
    ├─► grout-bind@eno12399np0.service  ─┐
    ├─► grout-bind@eno12399v1.service   ─┤ (also require routerpod-pod.service)
    │                                    │
    ├─► routerpod-pod.service ───────────┘
    │       └─► routerpod.pod
    │             ├─► grout.container
    │             ├─► frr.container
    │             └─► reloader.container
    │
    ├─► openperouter-node-index.service

can_start.sh (gate for setup-underlay + controller)
    │
    ├─► setup-underlay.service          (ExecStartPre=can_start.sh)
    │       └─► (waits for FRR ready)
    │
    ├─► setup-network.service
    │       └─► (after setup-underlay)
    │
    ├─► generate-config.service
    │       └─► (after setup-network)
    │
    ├─► controllerpod.pod
    │       └─► controller.container    (ExecStartPre=can_start.sh, conditional)
    │
    └─► apply-manifests.path → apply-manifests.service  (masters only)
            └─► (waits for kubeconfig + API server)
```

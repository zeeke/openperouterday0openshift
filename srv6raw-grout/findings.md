# Codebase Validation Findings

Review of srv6raw-grout against architecture.md and internal consistency.

---

## Likely Bugs

### 1. Inconsistent `HOST_VF` defaults across scripts

Three scripts use `HOST_VF` with **different defaults** — they probe different interfaces:

| Script | Default | Interface |
|--------|---------|-----------|
| `can_start.sh:17` | `eno12399np0` | PF (SR-IOV physical function) |
| `setup-underlay.sh:88` | `ens1f0v2` | VF2 (host virtual function) |
| `openperouter-node-index.sh:8` | `ens1f0v2` | VF2 (host virtual function) |

`can_start.sh` checks NM migration on the PF, while the other two look for the host IP on VF2. Since `vpn-setup.env` does **not** define `HOST_VF`, each script falls through to its own default.

### 2. `agent-config.yaml` routes reference non-existent `br0`

All three hosts define default routes via `next-hop-interface: br0`, but `br0` is never defined in the nmstate `networkConfig`. The only bridge created later by `setup-network.sh` is `br-pe-210`. If nmstate tries to apply these routes during the agent-based installer's discovery phase, they would fail or be ignored. Looks like a stale reference from a previous iteration.

---

## Documentation vs Code Drift

### 3. Architecture doc still references `sr0 dummy interface` (Chain 5, ~line 406)

The doc says `setup-underlay.sh` creates `sr0 dummy interface created in FRR namespace for SRv6`. The actual code does **not** create any sr0 dummy interface — it configures SRv6 addresses directly on `$UNDERLAY_NIC` via grcli.

### 4. Architecture doc systemd ordering diagram is misleading (~line 530)

The diagram shows `can_start.sh (gate)` directly above `grout-bind@` services, implying it gates them. But `grout-bind@.service` does **not** have `ExecStartPre=/usr/local/bin/can_start.sh`. Only `setup-underlay.service` and the controller container run `can_start.sh`. The grout-bind services depend on `routerpod-pod.service`, `nmstate.service`, and `network-online.target` instead.

---

## Cleanup Needed

### 5. Orphaned worker-specific files

These files in `extras/quadlets/` are no longer referenced by any `.bu` file:
- `routerpod-worker.pod`
- `frr-worker.container`
- `daemons-worker`
- `frr-sockets.volume`

### 6. Unused environment variables in `vpn-setup.env`

Three variables are defined but never consumed by any script:
- `VRF_TABLE=1100` — `setup-network.sh` creates VRF via `grcli interface add vrf red` with no table ID
- `VXLAN_PORT=4789` — never referenced
- `VTEP_INTERFACE=lo` — never referenced

### 7. `FRR_PID` saved to vars file but never consumed downstream

`setup-underlay.sh:268` writes `FRR_PID` to `vpn-setup.vars`, but neither `setup-network.sh` nor `generate-config.sh` uses it. Also, if FRR restarts between phases, the cached PID would be stale.

### 8. `apply-manifests.sh` applies `namespace.yaml` twice

Line 42 applies `namespace.yaml` explicitly, then line 44 applies everything in the directory (including `namespace.yaml` again). Idempotent but redundant.

---

## Fragile Design

### 9. `BR0_SUBNET_V6` sed computation (`setup-underlay.sh:232`)

```bash
BR0_SUBNET_V6="$(echo "$BR0_IP_V6" | sed 's/:[^:]*$//' | sed 's/:*$//')::/64"
```

For addresses where `::` appears before the last group (e.g. `fd00:110::1:2`), this produces `fd00:110::1::/64` — an invalid IPv6 address with two `::` sequences. Works for expected addresses but breaks with less common formats.

### 10. Hardcoded NIC names across .bu files and service units

Both `.bu` files hardcode `grout-bind@eno12399np0.service`, `grout-bind@eno12399v1.service`, and `AllowedCPUs=0-19`. Scripts default to `eno12399np0`, `eno12399v1`, `ens1f0v2`. The mix of NIC names being hardcoded in service units and defaulted-via-env in scripts creates a fragile surface for porting to different hardware.

### 11. `daemons-worker` misses `zebra_options` line

The master `daemons` file has `zebra_options="-s 90000000 -M dplane_grout"`. The `daemons-worker` file omits this. Since workers now use the master's `daemons` file this is not currently a problem, but if someone reverts to worker-specific daemons they'd silently lose the grout dataplane.

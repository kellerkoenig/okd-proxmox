<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Nodes, roles and scaling

## Roles

| Role | Meaning |
|---|---|
| `master` | control plane, 1 or 3 nodes (1 = single node with `platform: none`) |
| `worker` | compute for applications |
| `infra` | ingress routers, monitoring, logging, registry |

On vSphere IPI, infra nodes come from a dedicated `MachineSet`. Proxmox has
no Machine API, so there are no MachineSets and no autoscaling. `okd-pve`
creates infra nodes as regular VMs, installs them as workers and sets the
infra label and taints after they joined.

The infra role is more than cosmetics: ingress placement and the complete
monitoring configuration (hooks 30 and 40) follow the infra label.

## Roles are a list

`cluster.yaml` describes **node groups**, and every group has a list of
roles. Both layouts are supported:

```yaml
# dedicated infra nodes
- {name: infra,  roles: [infra],         taint_infra: true,  count: 3, ...}
- {name: worker, roles: [worker],                            count: 3, ...}

# combined worker/infra nodes (smaller clusters)
- {name: worker, roles: [worker, infra], taint_infra: false, count: 3, ...}
```

### Rules

- **`taint_infra` decides everything.** A tainted node only runs pods that
  tolerate the taint. A combined node with the taint is therefore a
  dedicated infra node in practice, and its worker label changes nothing.
  The combination only makes sense with `taint_infra: false`. `okd-pve`
  warns loudly when a group has both roles *and* the taint. The default is
  `true` for dedicated and `false` for combined groups.
- **No separate MachineConfigPool for combined roles.** A custom `infra`
  pool is created (Pre-Boot) only when *every* group with the infra role is
  dedicated. A custom pool then takes precedence over the worker pool. A
  node that matches *two* custom pools, however, goes `Degraded` and accepts
  no MachineConfig at all. So combined nodes stay in the worker pool.
  The infra pool inherits all worker MachineConfigs; moving a node from
  the worker pool into it does not reboot it as long as nothing
  infra-specific is configured.
- **Sizing for combined roles.** Prometheus and the routers are memory
  hungry. Sharing nodes with applications, the OOM killer may hit
  monitoring. Preflight warns below `infra.combined_min_memory_gib`.
- **Taint values in one place.** `infra.taint_key`, `taint_value` and
  `taint_effects` are set once in `cluster.yaml` and rendered into every
  taint, toleration and manifest (hooks read them from
  `OKD_PVE_INFRA_TAINT_*`).
- Dedicated infra nodes keep the `node-role.kubernetes.io/worker` label
  they joined with; `oc get nodes` shows `infra,worker`.

## VMIDs, MACs, IPs, disks

Everything is derived deterministically, so rebuilds give identical VMs:

| Value | Rule |
|---|---|
| hostname | `hostname_format`, default `<cluster>-<group>-<index>`; also Kubernetes node name and Proxmox VM name |
| VMID | `proxmox.vmid_start` + group offset + index; group offset = `vmid_offset` or position × `vmid_block`. Add new groups at the end of the list. |
| MAC | `proxmox.mac_prefix` followed by the VMID (e.g. `02:00:00` + 4100 → `02:00:00:00:10:04`) |
| IP | `node_groups[].ips[index]` (ranges allowed) |
| disk serials | `okd<vmid>d0` (boot), `okd<vmid>d1...` (data disks) |
| Proxmox host | round-robin over `proxmox.nodes` (or the group's `proxmox_nodes`), `spread: false` puts everything on the first |

`okd-pve node list` shows all of it next to the live status.

## Adding nodes

```bash
okd-pve node add --role worker --count 2
okd-pve node add --role infra --count 1 --group infra
```

1. picks free slots in the group (lowest free index) and validates IPs and
   VMIDs,
2. renders `nodes-config.yaml` and runs `oc adm node-image create` (needs
   OKD ≥ 4.17), which builds a node ISO inside the cluster,
3. uploads the ISO and creates only the new VMs; existing VMs are not
   touched,
4. approves the kubelet CSRs of exactly these nodes and waits for `Ready`,
5. detaches and deletes the ISO, sets infra labels/taints,
6. writes the new `count` back to `cluster.yaml` (backup `cluster.yaml.bak`)
   so a rebuild reproduces the topology.

Spare addresses must already be listed in the group's `ips`.

## Removing nodes

```bash
okd-pve node remove lab-worker-4 --drain-timeout 15m
```

`oc adm cordon` → `oc adm drain` (with timeout) → `oc delete node` → only
then `tofu destroy` of exactly this VM. The slot becomes free and is reused
by the next `node add`; the other nodes keep their VMIDs, MACs and IPs.

- Control-plane nodes are refused unless `--force-control-plane` is given.
  Even then the etcd member is not removed for you.
- Removing the last infra node is warned about: ingress and monitoring are
  pinned to infra nodes and would have nowhere to run.

## Migrating from combined to dedicated infra nodes

Tainting too early leaves ingress and monitoring without a place to run.
The order matters:

1. Append a dedicated group **at the end** of `node_groups`, initially
   **untainted** and empty (a group inserted before others would shift
   their VMIDs; `okd-pve` refuses changes that would recreate existing VMs):
   ```yaml
   - {name: infra, roles: [infra], taint_infra: false, count: 0, cpu: 8, memory_gib: 64, disk_gib: 256,
      ips: ["192.0.2.31-192.0.2.39"]}
   ```
2. `okd-pve node add --role infra --count 3` (the new nodes get the infra
   label). `node add --role infra` detects the combined layout and prints
   these steps.
3. Remove `infra` from the roles of the combined group and run
   `okd-pve node reconcile`. The old nodes lose the infra label, and ingress,
   monitoring and registry move to the new nodes (`okd-pve verify` shows
   where the routers run). Now that all infra groups are dedicated,
   `reconcile` also creates the infra MachineConfigPool.
4. Set `taint_infra: true` on the new group and run `okd-pve node reconcile`
   again.

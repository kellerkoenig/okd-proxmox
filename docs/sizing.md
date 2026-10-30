<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Sizing

## Starting values per role

| Role | vCPU | RAM | Boot disk |
|---|---|---|---|
| master | 8 | 32 GiB | 120 GiB |
| worker | 8 | 36 GiB | 128 GiB |
| worker + infra (combined) | 8 | 64 GiB | 256 GiB |
| infra (dedicated) | 8 | 64 GiB | 256 GiB |

The installer's hardware validation requires at least 4 vCPU / 16 GiB for
control-plane nodes, 2 vCPU / 8 GiB for others and 100 GiB of disk;
`okd-pve` rejects smaller values.

**Control-plane disks do not need 500 GiB**, provided image garbage
collection is configured for the master pool too. Without it the masters
run on the kubelet defaults (GC starts at 85 % usage) and their disks hover
just below that threshold. `okd-pve` configures GC for master and worker by
default (`kubelet:` in cluster.yaml, Pre-Boot), and 120 GiB is plenty.

Infra nodes run the ingress routers, Prometheus (two replicas, the
largest memory consumer), Alertmanager, Thanos and, if enabled, the
registry and logging. With combined worker/infra nodes these share memory
with your applications; `okd-pve` warns when such nodes have less than
`infra.combined_min_memory_gib` (48 GiB by default), because the OOM killer
may otherwise hit monitoring.

## How to size your own cluster

**Size by requests, not by utilisation.** The scheduler places pods by
their *requests*. Live usage plays no role in that decision. Look at

```bash
oc describe node <node> | sed -n '/Allocated resources/,/Events/p'
```

on an existing cluster (for example your current vSphere cluster). The
"Requests" column shows how full a node really is from the scheduler's
point of view. Production OKD clusters typically show a few percent CPU
*usage* while the CPU *requests* already block new pods. Size by live
usage and you build a cluster that accepts nothing.

A practical approach:

1. Sum the CPU and memory requests of all application workloads per
   namespace (`oc get pods -A -o json` + jq, or the "Requests" columns of
   the nodes).
2. Add 20–30 % headroom for rolling updates (surge pods), node failures
   (the pods of one node must fit on the others) and growth.
3. Divide by the allocatable resources per node. Allocatable is node
   capacity minus system reserved and eviction thresholds; with
   `autoSizingReserved` the reserve grows with node size (about 0.1 vCPU
   and 3.8 GiB on an 8 vCPU / 36 GiB worker). `oc describe node` shows the
   allocatable values.
4. Keep at least one node of headroom per group so draining a node for
   maintenance never blocks.

## Proxmox side

- **RAM is not overcommitted.** Ballooning is off for OKD nodes, and
  preflight fails when VM memory plus running VMs plus
  `proxmox.host_memory_reserve_gib` exceed a host's RAM.
- **CPU may be overcommitted moderately.** OKD nodes usually run far below
  their vCPU allocation, so 2:1 is common. Preflight warns above 1:1 and
  warns explicitly above 4:1, where control-plane latency starts to suffer.
- **etcd disks** need low latency: `okd-pve` configures control-plane
  disks with `iothread`, `discard` and no write cache. Put them on SSD/NVMe
  storage; slow disks cause sporadic leader elections that are hard to
  diagnose later.
- **Spread the control plane**: with several Proxmox hosts, the three
  masters land on different hosts (`proxmox.spread: true`).

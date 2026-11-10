<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Pre-Boot or Post-Install?

There are exactly two ways to get configuration into an OKD cluster. This
page helps you decide where a new piece of configuration belongs.

Other sources on the same topic, including the Red Hat documentation,
call these phases "Day 1" and "Day 2". Where those phases begin and end
differs from source to source, and the labels say nothing about what
actually happens. This project therefore talks about Pre-Boot and
Post-Install.

## Pre-Boot

Everything that is fixed before the ISO is built and is in effect the first
time a node starts:

- `install-config.yaml` and `agent-config.yaml`: network, VIPs, nodes, pull
  secret.
- Additional manifests in `<install-dir>/openshift/`. The agent-based
  installer bakes them into the Ignition configs. The OKD documentation
  calls these files **extra manifests**.

`okd-pve` renders built-in Pre-Boot manifests from
[templates/preboot/](../templates/preboot/), with values from `cluster.yaml`:

| Manifest | Pools | Purpose |
|---|---|---|
| chrony (`/etc/chrony.conf`) | master, worker (infra only if overridden) | NTP servers, `makestep`, `rtcsync`, driftfile |
| KubeletConfig | master **and** worker | image GC thresholds, eviction, `autoSizingReserved` |
| kernel arguments | master, worker, infra (additive) | e.g. serial console |
| CA trust | master, worker | extra CA for CRI-O/chrony, see `preboot.ca_bundle_file` |
| infra MachineConfigPool | – | only for dedicated infra groups |

Add your own manifests to `<cluster>/preboot/`: Butane (`.bu`, rendered
with `butane`) or plain YAML (copied unchanged). Before the ISO is built,
everything is checked for valid YAML, `apiVersion`, `kind`, `metadata.name`
and the role label on MachineConfigs.

## Post-Install

Everything applied against the running API: operator installations,
patches to cluster resources (IngressController, monitoring ConfigMaps,
OperatorHub), node labels and taints, secrets. In `okd-pve` these are the
[hooks](hooks.md).

## Rule of thumb

> **Everything that produces a `MachineConfig` or `KubeletConfig` belongs to
> Pre-Boot.**

Each such resource applied after installation makes the Machine Config
Operator drain and reboot every node of the affected pool, one at a time.
Three KubeletConfigs applied one after another mean three complete reboot
cycles through the master and worker pools, which costs more than an hour on
every rebuild. As a Pre-Boot manifest the same configuration costs nothing,
because the nodes boot with it.

NTP shows that it is not only about time. As a Pre-Boot manifest, the nodes
never boot with the OKD default NTP servers, which are unreachable in
isolated networks and produce the typical
`Can't synchronise: no majority` errors on first boot.

## Decision table

| You want to... | Where | Why |
|---|---|---|
| change NTP servers, kernel arguments, sysctls, files on the host | Pre-Boot (Butane in `preboot/`) | MachineConfig → reboot later |
| tune kubelet (GC, eviction, max pods, system reserved) | Pre-Boot (`kubelet:` in cluster.yaml or own KubeletConfig) | KubeletConfig → reboot later |
| trust an internal CA on the hosts | Pre-Boot (`preboot.ca_bundle_file`) | MachineConfig |
| trust an internal CA cluster-wide (proxy, builds) | `additionalTrustBundle` in install-config.yaml | Pre-Boot, part of the install config |
| install an operator, create its custom resource | Post-Install hook | needs the running API and OLM |
| place ingress/monitoring on infra nodes | Post-Install hook | labels exist only after the nodes joined |
| label or taint nodes | Post-Install (`okd-pve` does it for infra) | nodes may not set role labels themselves |
| secrets for webhooks, OAuth, ... | Post-Install hook, values from the environment | never in a repository |
| ContainerRuntimeConfig, ImageDigestMirrorSet | Pre-Boot | rendered into MachineConfigs |
| pull images through a local cache | `registry_mirrors` in cluster.yaml (Pre-Boot); `okd-pve mirrors apply` for a running cluster | see [registry-mirrors.md](registry-mirrors.md) |

When you are unsure: if `oc get machineconfig` would show a new entry after
applying it, it belongs to Pre-Boot.

## What if it has to happen after installation?

Sometimes it does, for example when a dedicated infra group is added later.
Then apply the MachineConfig in a hook and call `wait_for_mcp <pool>`
afterwards (see [hooks.md](hooks.md)), so the next hook does not run into a
pool in the middle of rebooting.

<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Examples

Two complete configurations. All names, domains and addresses are
placeholders (`example.com`, RFC 5737 networks).

| Example | Topology | Storage |
|---|---|---|
| [small](small/) | 3 control plane + 3 combined worker/infra nodes, untainted | NFS (subdir provisioner) |
| [large](large/) | 3 control plane + 3 dedicated, tainted infra nodes + 6 workers with data disks | Proxmox CSI on Ceph, Red Hat catalog |

To try one:

```bash
mkdir -p clusters
cp -r examples/small clusters/small
cp clusters/small/proxmox.conf.example clusters/small/proxmox.conf
chmod 600 clusters/small/proxmox.conf   # then fill in the token
okd-pve preflight --dir clusters/small
```

`large` refers to files that are not part of the repository on purpose:
`pull-secret.json`, `internal-ca.pem`, `proxmox-csi.conf` and a private hooks
directory.

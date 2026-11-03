<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Proxmox permissions

`okd-pve` works with an API token of an unprivileged Proxmox user. It needs
neither `root@pam` nor SSH access to the Proxmox nodes: the agent ISO carries
the Ignition configuration, so there are no snippets, no `fw_cfg` and no
`qm set --args`.

The commands below work on Proxmox VE 8 and 9. Replace the placeholders:

| Placeholder | Meaning |
|---|---|
| `okd-lab` | resource pool of the cluster (`proxmox.pool`) |
| `local-lvm` | VM disk storage (`proxmox.vm_storage`, plus every `data_disks[].storage`) |
| `local` | ISO storage (`proxmox.iso_storage`) |
| `vmbr0` | bridge (`proxmox.bridge`) |

## 1. Role for the installer

```bash
pveum role add OKDInstaller -privs "\
VM.Allocate VM.Audit VM.PowerMgmt \
VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType \
VM.Config.Memory VM.Config.Network VM.Config.Options \
Pool.Audit \
Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit"
```

| Privilege | Why |
|---|---|
| `VM.Allocate` on the pool | create and delete VMs in the pool |
| `VM.Config.*`, `VM.PowerMgmt`, `VM.Audit` | disks, CPU, memory, NIC, CD-ROM, serial console (`HWType`), boot order (`Options`), start/stop, reset of a stuck rendezvous node (`install.recover_rendezvous`), read status |
| `Pool.Audit` | preflight: check that the pool exists |
| `Datastore.AllocateSpace`, `Datastore.Audit` | create disks, read free space |
| `Datastore.AllocateTemplate` | upload the ISO |
| `Datastore.Allocate` (ISO storage only) | Proxmox requires it to **delete** an ISO again (after installation and on destroy) |
| `Sys.Audit` on the nodes | preflight: CPU/RAM capacity, CPU flags, bridges (via the built-in `PVEAuditor` role below) |
| `SDN.Use` on the bridge | attach NICs to the bridge/VLAN (built-in `PVESDNUser` role) |

Proxmox tags on the VMs (`proxmox.tags: true`) need `VM.Config.Options` on
`/vms` as well: when a VM is created with tags, Proxmox checks that privilege
on `/vms/<vmid>` and ignores the pool ACL. Tags are off by default.

Proxmox HA (`proxmox.ha.enabled: true`) needs `Sys.Audit` and `Sys.Console`
on `/`: Proxmox checks the HA API (resources and rules) on the root path
only, no matter which pool the VM is in. Without propagation the ACL grants
nothing below `/`, so the token gets no node shell (`Sys.Console` on
`/nodes/<node>`):

```bash
pveum role add OKDHA -privs "Sys.Audit Sys.Console"
for who in "--users terraform-okd@pve" "--tokens terraform-okd@pve!okd"; do
  pveum acl modify / $who --roles OKDHA --propagate 0
done
```

`Datastore.Allocate` also allows changing the configuration of *that*
storage. Grant it only on the ISO storage; a dedicated directory storage for
installer ISOs keeps the blast radius small.

## 2. User, pool, token

```bash
pveum user add terraform-okd@pve --comment "okd-pve installer"
pveum pool add okd-lab --comment "OKD cluster lab (okd-pve)"
pveum user token add terraform-okd@pve okd --privsep 1 --comment "okd-pve"
```

The last command prints the token secret once. Put it into
`clusters/<name>/proxmox.conf` (mode 600):

```bash
PROXMOX_VE_ENDPOINT="https://pve.example.com:8006/"
PROXMOX_VE_API_TOKEN="terraform-okd@pve!okd=<secret>"
PROXMOX_VE_INSECURE="false"   # "true" only for self-signed certificates
```

## 3. ACLs

With privilege separation (`--privsep 1`) a token has only the permissions
granted to the token itself, and never more than its user. Grant both:

```bash
for who in "--users terraform-okd@pve" "--tokens terraform-okd@pve!okd"; do
  pveum acl modify /pool/okd-lab                 $who --roles OKDInstaller
  pveum acl modify /storage/local-lvm            $who --roles OKDInstaller
  pveum acl modify /storage/local                $who --roles OKDInstaller
  pveum acl modify /nodes                        $who --roles PVEAuditor
  pveum acl modify /sdn/zones/localnetwork/vmbr0 $who --roles PVESDNUser
done
```

Notes:

- The role on `/storage/local-lvm` includes `Datastore.Allocate`. If you
  want to avoid that on the VM storage, create a second role without it for
  the VM storage:
  `pveum role add OKDInstallerDisk -privs "Datastore.AllocateSpace Datastore.Audit"`.
- For an SDN VNet instead of a Linux bridge use
  `/sdn/zones/<zone>/<vnet>`.
- `okd-pve preflight` checks every privilege on every path and names the
  missing ones.

## 4. Separate token for the Proxmox CSI driver

The CSI driver (`storage.backend: proxmox-csi`) must not use the installer
token. It runs inside the cluster for its whole life and needs other rights:

```bash
pveum role add OKDCSI -privs "VM.Audit VM.Config.Disk Datastore.Allocate Datastore.AllocateSpace Datastore.Audit"
pveum user add kubernetes-csi@pve --comment "Proxmox CSI for OKD"
pveum user token add kubernetes-csi@pve csi --privsep 1
for who in "--users kubernetes-csi@pve" "--tokens kubernetes-csi@pve!csi"; do
  pveum acl modify /pool/okd-lab      $who --roles OKDCSI
  pveum acl modify /storage/local-lvm $who --roles OKDCSI
done
```

Store it in `clusters/<name>/proxmox-csi.conf` (mode 600):

```bash
PROXMOX_CSI_TOKEN="kubernetes-csi@pve!csi=<secret>"
# PROXMOX_CSI_ENDPOINT defaults to PROXMOX_VE_ENDPOINT
```

`okd-pve storage install` refuses to run when both tokens are the same.

## Removing everything again

```bash
pveum user token remove terraform-okd@pve okd
pveum user delete terraform-okd@pve
pveum pool delete okd-lab          # pool must be empty
pveum role delete OKDInstaller
```

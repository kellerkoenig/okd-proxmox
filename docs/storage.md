<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Storage

`okd-pve storage install` (also run by `create` before the hooks) deploys
one storage backend, chosen with `storage.backend`. Every backend ends the
same way:

1. a StorageClass named `storage.storage_class`,
2. optionally a second class `<name>-retain` with `reclaimPolicy: Retain`
   for data that must survive the deletion of its PVC (`retain_class: true`),
3. optionally the default-class annotation (`default: true`),
4. a test: a 1 GiB PVC and a pod that writes to it, deleted afterwards
   (`test: true`).

Point `monitoring.storage_class` at the class Prometheus and Alertmanager
should use.

## proxmox-csi

[sergelogvinov/proxmox-csi-plugin](https://github.com/sergelogvinov/proxmox-csi-plugin)
creates Proxmox disks and hot-plugs them into the node VMs.

```yaml
storage:
  backend: proxmox-csi
  storage_class: proxmox
  proxmox_csi:
    storage: local-lvm     # Proxmox storage for the volumes (default: proxmox.vm_storage)
    region: ""             # default: cluster name
    fstype: xfs
```

- Uses its **own token** (`PROXMOX_CSI_TOKEN` in
  `<cluster>/proxmox-csi.conf`, mode 600, or in the environment). Creating it
  is described in [proxmox-permissions.md](proxmox-permissions.md). The
  installer token is refused.
- `okd-pve` labels every node with `topology.kubernetes.io/region` and
  `topology.kubernetes.io/zone=<Proxmox node>`. After migrating a VM to
  another host, run `okd-pve storage install` again to update the labels.
- With local (non-shared) Proxmox storage a volume is bound to the host
  it was created on (`WaitForFirstConsumer`).

## ceph-external

ceph-csi (RBD) against a Ceph cluster outside OKD, typically the Ceph of the
Proxmox hosts.

```yaml
storage:
  backend: ceph-external
  ceph:
    cluster_id: 00000000-0000-0000-0000-000000000000   # ceph fsid
    monitors: ["192.0.2.71:6789", "192.0.2.72:6789", "192.0.2.73:6789"]
    pool: okd
    user: okd
```

Prepare on a Proxmox host:

```bash
ceph osd pool create okd && rbd pool init okd
ceph auth get-or-create client.okd mon 'profile rbd' osd 'profile rbd pool=okd' mgr 'profile rbd pool=okd'
ceph fsid; ceph mon dump
```

Put the key into `<cluster>/ceph-csi.conf` (mode 600) as
`CEPH_USER_KEY=<key>` or export it.

## lso (Local Storage Operator, optional ODF)

Uses the raw `data_disks` of worker nodes. Because every disk has a stable
serial, the operator finds it as
`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_okd<vmid>d<n>`, reliably across
reboots (on vSphere this is what `disk.EnableUUID=TRUE` is for).

```yaml
node_groups:
  - name: worker
    roles: [worker]
    data_disks: [200]
storage:
  backend: lso
  storage_class: local-disks
  lso:
    node_groups: [worker]   # default: every worker group with data_disks
    volume_mode: Filesystem
    fstype: xfs
    odf: false              # true: ODF on top (block mode, needs >= 3 disks on 3 nodes)
```

The operator comes from the catalog profile (`hooks.env.OKD_PVE_CATALOG_PROFILE`).
No `-retain` class is created for plain LSO: it binds pre-created local PVs,
and a second class would get none. With `odf: true` the class used for the
default flag and the test is `ocs-storagecluster-ceph-rbd`.

## nfs

[nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner):
one subdirectory per PVC on an existing export. Simple, no snapshots, no
quotas.

```yaml
storage:
  backend: nfs
  storage_class: nfs
  nfs:
    server: 192.0.2.200
    path: /export/okd
    archive_on_delete: true   # keep data as archived-<dir> after PVC deletion
```

The export must be writable by the nodes (`no_root_squash` or matching
ownership).

## Warning: default StorageClass and pre-created NFS PVs

A default StorageClass changes how PVCs **without** `storageClassName`
behave: they get the default class and are provisioned dynamically. A PVC
that was meant to bind to a PV you created by hand (for example for an NFS
share with existing data) then gets a new, empty volume instead.

If you maintain NFS PVs manually, either do not set a default class
(`storage.default: false`), or set `storageClassName: ""` explicitly in
those PVCs:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: legacy-data
spec:
  storageClassName: ""        # bind only to a pre-created PV
  volumeName: legacy-data-pv
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 100Gi
```

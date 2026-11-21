<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# etcd backup and restore

etcd holds the complete state of the cluster: every object, every secret.
`okd-pve` takes regular backups with the documented
`/usr/local/bin/cluster-backup.sh` and restores them with the documented
procedure "Restoring to an earlier cluster state for more than one node".

A rebuild with `okd-pve destroy` and `create` remains the fastest way back
for a cluster whose applications come from Git or Puppet. A restore is for
the cases where a rebuild would lose something: objects created by hand,
data of operators, a cluster that cannot be rebuilt right now. Both paths
need practice before the emergency.

## Backup: hook 56-etcd-backup

```yaml
# cluster.yaml
hooks:
  builtin: [..., 56-etcd-backup]
  env:
    ETCD_BACKUP_SCHEDULE: "15 2 * * *"   # default
    ETCD_BACKUP_TIMEZONE: Europe/Berlin  # default: UTC
    ETCD_BACKUP_KEEP: "7"                # default
```

The hook creates, in namespace `openshift-etcd-backup`:

- a PVC `etcd-backup` (20 GiB) of the class `<default class>-retain` if it
  exists, else the default class (`ETCD_BACKUP_STORAGE_CLASS` overrides
  it). The Retain class keeps the Proxmox disk when the PVC is deleted.
- a CronJob that runs on a control plane node: `cluster-backup.sh` writes the
  etcd snapshot and the static pod resources, the job copies them into
  `<UTC time>_<cluster version>/` on the volume and keeps the newest
  `ETCD_BACKUP_KEEP` backups. The cluster-wide proxy is passed to the job.
- a PrometheusRule: `EtcdBackupMissing` fires when the last successful backup
  is older than `ETCD_BACKUP_MAX_AGE_HOURS` (26). A failed run raises the
  standard alert `KubeJobFailed`.

It takes a first backup right away and waits for it (`ETCD_BACKUP_NOW=false`
skips that).

The volume is mounted on a control plane node, so the CSI node plugin must
run there. `okd-pve storage install` deploys the node plugins of Proxmox CSI
and Ceph CSI with a toleration for the control plane taint (since 0.2.0; run
`okd-pve storage install` once on older clusters). NFS needs no node plugin.
Plain LSO volumes live on worker disks and do not work here; set
`ETCD_BACKUP_STORAGE_CLASS` to another class.

## Working with backups

```bash
okd-pve etcd list               # backups in the cluster and local copies
okd-pve etcd backup             # one now (e.g. before a risky change)
okd-pve etcd fetch --latest     # copy the newest to <cluster>/backups/etcd/<name>
okd-pve etcd fetch 2026-11-21_011500_4.22.0-okd-scos.10
```

A backup on the cluster's own storage does not help when that storage is
gone. Copy backups out of the cluster regularly with `okd-pve etcd fetch`
and keep them as safe as the kubeconfig: they contain every secret of the
cluster. `<cluster>/backups/` is mode 700 and in the cluster `.gitignore`.
`okd-pve destroy` keeps it. A backup restores only the cluster it was taken
from: after `destroy` and `create` it is a new cluster, and the old backups
are of no use for it.

## Restore

```bash
okd-pve etcd restore --latest                    # newest backup (fetched first if needed)
okd-pve etcd restore 2026-11-21_011500_4.22.0-okd-scos.10 --recovery-host okd-pve-01-master-1
```

What it does, following the OKD/OpenShift documentation of 4.18 and newer
(4.17 lacks `disable-etcd.sh`; there `etcd restore` refuses to run):

1. Uses the local copy in `<cluster>/backups/etcd/<name>`; while the API
   still answers, it fetches the backup first.
2. Refuses a backup of another release than the cluster runs (the
   documentation requires the same z-stream release; `--force` overrides).
3. Checks SSH (`core@<node IP>`) to every control plane node. A node without
   SSH must be powered off, which it checks through the Proxmox API, so its
   etcd cannot keep a quorum.
4. Asks for the cluster name (`--yes` skips the question).
5. Copies the backup to the recovery host (default: the first control plane
   node), runs `disable-etcd.sh` on the other control plane nodes and
   `cluster-restore.sh` on the recovery host. Before that it moves leftovers
   in `/var/lib/etcd` of the recovery host (the etcd operator leaves
   `member-removed-archive-*` there when a node rejoins after a restore) to
   `/var/lib/etcd-backup/extra-data-dir-contents/`, as newer versions of
   `cluster-restore.sh` do themselves; older ones refuse with "folder
   /var/lib/etcd is not empty".
6. Waits until the API answers from the restored etcd, turns the etcd quorum
   guard off, approves kubelet CSRs of the control plane nodes and waits
   until the regular etcd pod runs on every control plane node and the
   cluster operators are stable (`oc adm wait-for-stable-cluster`), then
   turns the quorum guard on again. The restored etcd operator status may
   claim that every node is at the current revision, so that nothing rolls
   out; after 10 minutes without all etcd members it applies the documented
   `forceRedeploymentReason` once.

Everything created after the backup is lost, and nodes added after it have
to join again (`okd-pve node add --resume`, or remove them). Run
`okd-pve verify` afterwards.

SSH uses `OKD_PVE_SSH_PRIVATE_KEY_FILE`, else the private key next to the
public key of the installation (`install.ssh_public_key_file`,
`~/.ssh/id_ed25519.pub`, ...), else your ssh agent and `~/.ssh/config`.
Host keys are kept in `<cluster>/.state/known_hosts`.

Single-node clusters are not supported by `etcd restore`; use the documented
single-node procedure. When only the quorum is lost (two control plane
nodes broken, data intact on the third), the documented `quorum-restore.sh`
without a backup is the better tool.

### When the restore stops

- **cluster-restore.sh failed:** etcd is stopped on the control plane nodes
  and the API is down. Fix the cause from the output, run the script again
  on the recovery host
  (`ssh core@<ip> sudo -E /usr/local/bin/cluster-restore.sh /home/core/okd-pve-restore-<name>`),
  then let `okd-pve etcd restore --continue` do the rest: wait for the API,
  quorum guard off, stable control plane, quorum guard on.
- **disable-etcd.sh failed on a node:** nothing is restored yet. etcd on that
  node starts again with
  `sudo mv /home/core/assets/manifests-stopped/etcd-pod.yaml /etc/kubernetes/manifests/`.
- **The control plane does not become stable:** if the etcd pods do not roll
  out, force a redeployment, then wait again:
  `oc patch etcd cluster --type=merge -p '{"spec": {"forceRedeploymentReason": "recovery-'"$(date --rfc-3339=ns)"'"}}'`.
  When it is stable, turn the quorum guard on again:
  `oc patch etcd/cluster --type=merge -p '{"spec": {"unsupportedConfigOverrides": null}}'`.

Practise the restore on a test cluster: take a backup, delete a namespace,
restore, and check that it is back.

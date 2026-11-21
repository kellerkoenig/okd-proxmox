#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Scheduled etcd backup: a CronJob on a control plane node runs the
# documented /usr/local/bin/cluster-backup.sh (etcd snapshot plus the static
# pod resources) and keeps the newest backups on a PVC. A first backup is
# taken right away. Alerts: KubeJobFailed for a failed run, EtcdBackupMissing
# when the last successful backup is too old.
#
# List, copy and restore backups with `okd-pve etcd list|backup|fetch|restore`
# (docs/etcd-backup.md). Keep copies outside the cluster: `okd-pve etcd fetch`.
#
#   ETCD_BACKUP_SCHEDULE       cron schedule; default: "15 2 * * *"
#   ETCD_BACKUP_TIMEZONE       time zone of the schedule, e.g. Europe/Berlin; default: UTC
#   ETCD_BACKUP_KEEP           backups kept on the volume; default: 7
#   ETCD_BACKUP_STORAGE_CLASS  default: "<default class>-retain" if it exists, else
#                              the default StorageClass
#   ETCD_BACKUP_SIZE           volume size; default: 20Gi
#   ETCD_BACKUP_MAX_AGE_HOURS  EtcdBackupMissing fires after this; default: 26
#   ETCD_BACKUP_NOW            true (default): take a backup now and wait for it
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"

ns=openshift-etcd-backup
keep=${ETCD_BACKUP_KEEP:-7}
[[ ${keep} =~ ^[1-9][0-9]*$ ]] || {
	echo "ETCD_BACKUP_KEEP must be a positive number, not '${keep}'." >&2
	exit 1
}

# Storage: the volume is mounted on a control plane node, so the CSI node
# plugin must run there (okd-pve storage install takes care of that).
sc=${ETCD_BACKUP_STORAGE_CLASS:-}
if [[ -z ${sc} ]]; then
	classes=$(oc get storageclass -o json)
	default=$(jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name][0] // ""' <<<"${classes}")
	if [[ -z ${default} ]]; then
		echo "No default StorageClass and no ETCD_BACKUP_STORAGE_CLASS: no etcd backup." >&2
		exit 2
	fi
	sc=${default}
	jq -e --arg n "${default}-retain" 'any(.items[]; .metadata.name == $n)' <<<"${classes}" >/dev/null && sc=${default}-retain
fi
provisioner=$(oc get storageclass "${sc}" -o jsonpath='{.provisioner}' 2>/dev/null) || {
	echo "StorageClass ${sc} does not exist." >&2
	exit 1
}
if [[ ${provisioner} == kubernetes.io/no-provisioner ]]; then
	echo "StorageClass ${sc} has no provisioner (local disks on workers); set ETCD_BACKUP_STORAGE_CLASS to a class that can attach to control plane nodes." >&2
	exit 2
fi

# The cli image of the running release; it has oc, bash and coreutils.
image=$(oc get istag cli:latest -n openshift -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)
[[ -n ${image} ]] || image=$(oc adm release info --image-for=cli)

# cluster-backup.sh pulls the etcd image when the node lacks etcdctl: give
# it the cluster-wide proxy.
proxy=$(oc get proxy cluster -o json | jq -c '[(.status // {}) | to_entries[]
	| select(.value != null and .value != "" and (.key | test("^(httpProxy|httpsProxy|noProxy)$")))
	| {name: ({httpProxy: "HTTP_PROXY", httpsProxy: "HTTPS_PROXY", noProxy: "NO_PROXY"}[.key]), value}]')

apply_idempotent - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    openshift.io/cluster-monitoring: "true"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
    app.kubernetes.io/managed-by: okd-pve
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: etcd-backup
  namespace: ${ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: etcd-backup-privileged
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: etcd-backup
    namespace: ${ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: okd-pve-etcd-backup
rules:
  - apiGroups: [config.openshift.io]
    resources: [clusterversions]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: okd-pve-etcd-backup
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: okd-pve-etcd-backup
subjects:
  - kind: ServiceAccount
    name: etcd-backup
    namespace: ${ns}
YAML

if ! oc -n "${ns}" get pvc etcd-backup >/dev/null 2>&1; then
	apply_idempotent - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: etcd-backup
  namespace: ${ns}
spec:
  storageClassName: ${sc}
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${ETCD_BACKUP_SIZE:-20Gi}
YAML
fi

apply_idempotent - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: etcd-backup
  namespace: openshift-etcd-backup
data:
  backup.sh: |
    #!/bin/bash
    # One backup directory per run: <UTC time>_<cluster version>, with the
    # files of cluster-backup.sh plus "version" and "node". Written under a
    # temporary name first, so an interrupted run never looks complete.
    set -euo pipefail
    version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    name=$(date -u +%Y-%m-%d_%H%M%S)_${version}
    work=/var/tmp/okd-pve-etcd-backup
    rm -rf "/host${work}" /backup/.incomplete-*
    chroot /host /usr/local/bin/cluster-backup.sh "${work}"
    tmp=/backup/.incomplete-${name}
    mkdir -p "${tmp}"
    cp "/host${work}"/* "${tmp}/"
    printf '%s\n' "${version}" >"${tmp}/version"
    printf '%s\n' "${NODE_NAME}" >"${tmp}/node"
    chmod 600 "${tmp}"/*
    chmod 700 "${tmp}"
    sync
    mv "${tmp}" "/backup/${name}"
    rm -rf "/host${work}"
    echo "backup ${name} complete: $(du -sh "/backup/${name}" | cut -f1)"
    mapfile -t all < <(find /backup -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' | sort)
    for ((i = 0; i < ${#all[@]} - KEEP; i++)); do
      echo "removing old backup ${all[i]}"
      rm -rf "/backup/${all[i]}"
    done
YAML

cronjob=$(jq -n --arg ns "${ns}" --arg image "${image}" --arg schedule "${ETCD_BACKUP_SCHEDULE:-15 2 * * *}" \
	--arg tz "${ETCD_BACKUP_TIMEZONE:-}" --arg keep "${keep}" --argjson proxy "${proxy}" '{
	apiVersion: "batch/v1", kind: "CronJob",
	metadata: {name: "etcd-backup", namespace: $ns, labels: {"app.kubernetes.io/managed-by": "okd-pve"}},
	spec: ({schedule: $schedule} + (if $tz != "" then {timeZone: $tz} else {} end) + {
		concurrencyPolicy: "Forbid",
		successfulJobsHistoryLimit: 3,
		failedJobsHistoryLimit: 3,
		jobTemplate: {spec: {backoffLimit: 1, activeDeadlineSeconds: 1800, template: {
			metadata: {labels: {app: "etcd-backup"}},
			spec: {
				serviceAccountName: "etcd-backup",
				restartPolicy: "Never",
				hostNetwork: true,
				nodeSelector: {"node-role.kubernetes.io/control-plane": ""},
				tolerations: [
					{key: "node-role.kubernetes.io/master", operator: "Exists", effect: "NoSchedule"},
					{key: "node-role.kubernetes.io/control-plane", operator: "Exists", effect: "NoSchedule"}],
				containers: [{
					name: "backup", image: $image,
					command: ["/bin/bash", "/scripts/backup.sh"],
					env: ([{name: "KEEP", value: $keep},
						{name: "NODE_NAME", valueFrom: {fieldRef: {fieldPath: "spec.nodeName"}}}] + $proxy),
					resources: {requests: {cpu: "10m", memory: "64Mi"}},
					securityContext: {privileged: true, runAsUser: 0},
					volumeMounts: [
						{name: "host", mountPath: "/host"},
						{name: "backup", mountPath: "/backup"},
						{name: "scripts", mountPath: "/scripts"}]}],
				volumes: [
					{name: "host", hostPath: {path: "/", type: "Directory"}},
					{name: "backup", persistentVolumeClaim: {claimName: "etcd-backup"}},
					{name: "scripts", configMap: {name: "etcd-backup"}}]}}}}})}')
apply_idempotent - <<<"${cronjob}"

max_age=$((${ETCD_BACKUP_MAX_AGE_HOURS:-26} * 3600))
apply_idempotent - <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: etcd-backup
  namespace: ${ns}
spec:
  groups:
    - name: okd-pve-etcd-backup
      rules:
        - alert: EtcdBackupMissing
          expr: time() - kube_cronjob_status_last_successful_time{namespace="${ns}", cronjob="etcd-backup"} > ${max_age}
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: No successful etcd backup for more than ${ETCD_BACKUP_MAX_AGE_HOURS:-26} hours.
            description: The last etcd backup of CronJob ${ns}/etcd-backup is too old. Check the jobs with 'oc -n ${ns} get jobs' and their logs.
YAML

echo "etcd backup: schedule '${ETCD_BACKUP_SCHEDULE:-15 2 * * *}'${ETCD_BACKUP_TIMEZONE:+ (${ETCD_BACKUP_TIMEZONE})}, keeps ${keep}, StorageClass ${sc}."
[[ ${ETCD_BACKUP_NOW:-true} == true ]] || exit 0

job=etcd-backup-okd-pve-$(date -u +%Y%m%d%H%M%S)
oc -n "${ns}" create job "${job}" --from=cronjob/etcd-backup >/dev/null
done_or_failed() {
	local s
	s=$(oc -n "${ns}" get job "${job}" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null)
	[[ ${s} =~ (Complete|Failed) ]]
}
oc_wait 1800 "first etcd backup (job ${job})" done_or_failed
if oc -n "${ns}" get job "${job}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' | grep -q True; then
	oc -n "${ns}" logs "job/${job}" --tail=20 2>/dev/null | grep -E '^(backup|removing)' || true
	exit 0
fi
echo "The first etcd backup failed; last log lines:" >&2
oc -n "${ns}" logs "job/${job}" --tail=15 >&2 2>/dev/null || true
exit 2

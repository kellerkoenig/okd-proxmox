# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# etcd backups made by hook 56-etcd-backup: list, take, fetch, restore
# (okd-pve etcd ...). The restore follows the documented procedure
# "Restoring to an earlier cluster state for more than one node"
# (OKD/OpenShift 4.18 and newer): disable etcd on the other control plane
# nodes, run cluster-restore.sh on the recovery host, wait for a stable
# cluster with the quorum guard turned off.

[[ -n ${_OKD_PVE_ETCD_LOADED:-} ]] && return 0
_OKD_PVE_ETCD_LOADED=1

ETCD_BACKUP_NS=openshift-etcd-backup
ETCD_BROWSER_POD=etcd-backup-browser
ETCD_RESTORE_TIMEOUT=${OKD_PVE_ETCD_RESTORE_TIMEOUT:-3600}
ETCD_MASTERS=()
ETCD_RESTORE_CLEANUP_IPS=()
# Runs on the recovery host: everything in /var/lib/etcd except member/ and
# revision.json (cluster-restore.sh handles those) moves to
# /var/lib/etcd-backup/extra-data-dir-contents/.
ETCD_DATA_DIR_TIDY='sudo bash -c '\''x=/var/lib/etcd-backup/extra-data-dir-contents; shopt -s nullglob dotglob; for e in /var/lib/etcd/*; do b=${e##*/}; [[ $b == member || $b == revision.json ]] && continue; mkdir -p "$x"; rm -rf "${x:?}/$b"; echo "moving $e to $x/"; mv "$e" "$x/"; done'\'''

etcd_local_dir() {
	printf '%s/backups/etcd' "${CLUSTER_DIR}"
}

# etcd_backup_valid <dir>: a backup directory has both files of
# cluster-backup.sh.
etcd_backup_valid() {
	compgen -G "$1/snapshot_*.db" >/dev/null && compgen -G "$1/static_kuberesources_*.tar.gz" >/dev/null
}

_etcd_require_cronjob() {
	oc -n "${ETCD_BACKUP_NS}" get cronjob etcd-backup >/dev/null 2>&1 ||
		die "${EXIT_CONFIG}" "No etcd backup is set up in this cluster." \
			"Add 56-etcd-backup to hooks.builtin in cluster.yaml and run 'okd-pve hooks run 56-etcd-backup'."
}

# _etcd_browser_start: a pod that mounts the backup volume, on a control
# plane node like the backup job (the volume is ReadWriteOnce). Privileged
# like the job: the files carry the SELinux label of the job's writes, and a
# read-only volume is not relabeled for a confined pod.
_etcd_browser_start() {
	local image
	image=$(oc -n "${ETCD_BACKUP_NS}" get cronjob etcd-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')
	oc -n "${ETCD_BACKUP_NS}" delete pod "${ETCD_BROWSER_POD}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	jq -n --arg ns "${ETCD_BACKUP_NS}" --arg name "${ETCD_BROWSER_POD}" --arg image "${image}" '{
		apiVersion: "v1", kind: "Pod",
		metadata: {name: $name, namespace: $ns, labels: {"app.kubernetes.io/managed-by": "okd-pve"}},
		spec: {
			serviceAccountName: "etcd-backup",
			restartPolicy: "Never",
			activeDeadlineSeconds: 3600,
			nodeSelector: {"node-role.kubernetes.io/control-plane": ""},
			tolerations: [
				{key: "node-role.kubernetes.io/master", operator: "Exists", effect: "NoSchedule"},
				{key: "node-role.kubernetes.io/control-plane", operator: "Exists", effect: "NoSchedule"}],
			containers: [{name: "browser", image: $image, command: ["sleep", "3600"],
				securityContext: {privileged: true, runAsUser: 0},
				volumeMounts: [{name: "backup", mountPath: "/backup", readOnly: true}]}],
			volumes: [{name: "backup", persistentVolumeClaim: {claimName: "etcd-backup", readOnly: true}}]}}' |
		oc apply -f - >/dev/null
	if ! oc -n "${ETCD_BACKUP_NS}" wait --for=condition=Ready "pod/${ETCD_BROWSER_POD}" --timeout=300s >/dev/null 2>&1; then
		_etcd_browser_stop
		die "${EXIT_ERROR}" "Could not mount the etcd backup volume." \
			"A backup job may be running right now (the volume attaches to one node only): oc -n ${ETCD_BACKUP_NS} get pods,events"
	fi
}

_etcd_browser_stop() {
	oc -n "${ETCD_BACKUP_NS}" delete pod "${ETCD_BROWSER_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# _etcd_remote_list: name, size, version of every complete backup on the
# volume (needs the browser pod), oldest first.
_etcd_remote_list() {
	local out
	# shellcheck disable=SC2016
	out=$(oc -n "${ETCD_BACKUP_NS}" exec "${ETCD_BROWSER_POD}" -- bash -c '
		cd /backup && for d in 2*/; do
			[[ -d ${d} ]] || continue
			d=${d%/}
			printf "%s\t%s\t%s\n" "${d}" "$(du -sh "${d}" | cut -f1)" "$(cat "${d}/version" 2>/dev/null || echo -)"
		done') || {
		_etcd_browser_stop
		die "${EXIT_ERROR}" "Could not read the etcd backup volume." "oc -n ${ETCD_BACKUP_NS} get pods,events"
	}
	[[ -z ${out} ]] || sort <<<"${out}"
}

# _etcd_local_list: the same for the copies in <cluster>/backups/etcd.
_etcd_local_list() {
	local d dir
	dir=$(etcd_local_dir)
	[[ -d ${dir} ]] || return 0
	for d in "${dir}"/2*/; do
		[[ -d ${d} ]] || continue
		d=${d%/}
		etcd_backup_valid "${d}" || continue
		printf '%s\t%s\t%s\n' "${d##*/}" "$(du -sh "${d}" | cut -f1)" "$(cat "${d}/version" 2>/dev/null || echo -)"
	done | sort
}

_etcd_api_up() {
	[[ -f ${KUBECONFIG_FILE} ]] && oc get --raw /readyz --request-timeout=10s >/dev/null 2>&1
}

# _etcd_api_serving: a read that needs etcd. Right after cluster-restore.sh
# /readyz may still answer from the old kube-apiserver while etcd restarts.
_etcd_api_serving() {
	oc get etcd cluster -o name --request-timeout=15s >/dev/null 2>&1
}

# _etcd_retry <seconds> <cmd...>: retry while the API settles after the restore.
_etcd_retry() {
	local timeout=$1 t0=${SECONDS}
	shift
	until "$@" >/dev/null 2>&1; do
		((SECONDS - t0 < timeout)) || return 1
		sleep 15
	done
}

ETCD_GUARD_OFF='{"spec": {"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}'
ETCD_GUARD_ON='{"spec": {"unsupportedConfigOverrides": null}}'

# _etcd_backup_time <name>: "2026-11-21 10:36:03 UTC" from the backup name.
_etcd_backup_time() {
	local n=$1
	if [[ ${n} =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
		printf '%s %s:%s:%s UTC' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
	else
		printf '%s' "${n}"
	fi
}

cmd_etcd_list() {
	local remote='' local_list
	local_list=$(_etcd_local_list)
	if _etcd_api_up && oc -n "${ETCD_BACKUP_NS}" get cronjob etcd-backup >/dev/null 2>&1; then
		_etcd_browser_start
		remote=$(_etcd_remote_list) || exit "${EXIT_ERROR}"
		_etcd_browser_stop
	else
		log_warn "Cluster or etcd backup not reachable: showing the local copies only."
	fi
	{
		echo "NAME|VERSION|SIZE|IN CLUSTER|LOCAL COPY"
		jq -rn --rawfile r <(printf '%s' "${remote}") --rawfile l <(printf '%s' "${local_list}") '
			def rows($s): $s | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: {size: .[1], version: .[2]}}) | from_entries;
			rows($r) as $r | rows($l) as $l
			| ($r + $l | keys | sort)[] as $n
			| [$n, ($r[$n].version // $l[$n].version), ($r[$n].size // $l[$n].size),
			   (if $r[$n] then "yes" else "-" end), (if $l[$n] then "yes" else "-" end)] | join("|")'
	} | column -t -s '|'
	log_info "Local copies: $(etcd_local_dir)"
}

cmd_etcd_backup() {
	_etcd_require_cronjob
	dry_run_note "would start a job from cronjob ${ETCD_BACKUP_NS}/etcd-backup and wait for it" && return 0
	local job
	job=etcd-backup-okd-pve-$(date -u +%Y%m%d%H%M%S)
	oc -n "${ETCD_BACKUP_NS}" create job "${job}" --from=cronjob/etcd-backup >/dev/null
	log_info "Backup job ${job} started"
	_etcd_job_done() {
		[[ $(oc -n "${ETCD_BACKUP_NS}" get job "${job}" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null) =~ (Complete|Failed) ]]
	}
	oc_wait 1800 "etcd backup job ${job}" _etcd_job_done
	if [[ $(oc -n "${ETCD_BACKUP_NS}" get job "${job}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}') == True ]]; then
		oc -n "${ETCD_BACKUP_NS}" logs "job/${job}" --tail=20 2>/dev/null | grep -E '^(backup|removing)' | sed 's/^/    /' || true
		log_ok "etcd backup complete. Copy it out of the cluster with 'okd-pve etcd fetch --latest'."
	else
		oc -n "${ETCD_BACKUP_NS}" logs "job/${job}" --tail=15 2>/dev/null | sed 's/^/       | /' >&2 || true
		die "${EXIT_ERROR}" "The etcd backup failed." "oc -n ${ETCD_BACKUP_NS} logs job/${job}"
	fi
}

# cmd_etcd_fetch [name | --latest]: copy a backup from the cluster into
# <cluster>/backups/etcd/<name> (mode 700; it contains every secret of the
# cluster).
cmd_etcd_fetch() {
	local name=${1:---latest} dir target try
	_etcd_require_cronjob
	dir=$(etcd_local_dir)
	_etcd_browser_start
	if [[ ${name} == --latest ]]; then
		name=$(_etcd_remote_list | tail -n 1 | cut -f1) || exit "${EXIT_ERROR}"
		[[ -n ${name} ]] || {
			_etcd_browser_stop
			die "${EXIT_ERROR}" "There is no backup on the volume yet." "okd-pve etcd backup"
		}
	elif ! { _etcd_remote_list || exit "${EXIT_ERROR}"; } | cut -f1 | grep -xF -- "${name}" >/dev/null; then
		_etcd_browser_stop
		die "${EXIT_CONFIG}" "No backup named ${name} in the cluster." "okd-pve etcd list"
	fi
	target=${dir}/${name}
	if etcd_backup_valid "${target}"; then
		_etcd_browser_stop
		log_ok "${name} is already here: ${target}"
		return 0
	fi
	if dry_run_note "would copy ${name} to ${target}"; then
		_etcd_browser_stop
		return 0
	fi
	(umask 077 && mkdir -p "${dir}")
	chmod 700 "${CLUSTER_DIR}/backups" "${dir}"
	# oc exec streams can break on a flaky connection (VPN): retry the copy
	for try in 1 2 3; do
		rm -rf "${target}.incomplete"
		(umask 077 && mkdir "${target}.incomplete")
		if oc -n "${ETCD_BACKUP_NS}" exec "${ETCD_BROWSER_POD}" -- tar -C "/backup/${name}" -cf - . |
			tar -C "${target}.incomplete" --no-same-owner -xf -; then
			break
		fi
		if ((try == 3)); then
			_etcd_browser_stop
			rm -rf "${target}.incomplete"
			die "${EXIT_ERROR}" "Copying ${name} failed."
		fi
		log_warn "Copying ${name} was interrupted; trying again (${try}/3)"
		sleep "${ETCD_FETCH_RETRY_DELAY:-5}"
	done
	_etcd_browser_stop
	chmod 600 "${target}.incomplete"/*
	etcd_backup_valid "${target}.incomplete" || die "${EXIT_ERROR}" "${name} is incomplete (snapshot or static pod resources missing)."
	mv "${target}.incomplete" "${target}"
	log_ok "Fetched ${name} ($(du -sh "${target}" | cut -f1)) to ${target}"
	log_hint "It contains every secret of the cluster: keep it as safe as the kubeconfig."
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

# etcd_ssh_opts: options for ssh/scp to core@<node>. The private key is
# OKD_PVE_SSH_PRIVATE_KEY_FILE, else the key next to the public key file of
# the installation, else whatever ssh would use (agent, ~/.ssh/config).
ETCD_SSH_OPTS=()
etcd_ssh_opts() {
	local key=${OKD_PVE_SSH_PRIVATE_KEY_FILE:-} pub
	if [[ -z ${key} ]] && pub=$(ssh_key_file 2>/dev/null) && [[ ${pub} == *.pub && -f ${pub%.pub} ]]; then
		key=${pub%.pub}
	fi
	mkdir -p "${STATE_DIR}"
	ETCD_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
		-o "UserKnownHostsFile=${STATE_DIR}/known_hosts" -o LogLevel=ERROR)
	[[ -n ${key} ]] && ETCD_SSH_OPTS+=(-i "${key}" -o IdentitiesOnly=yes)
	return 0
}

# etcd_ssh <ip> <command>: run a command as core on a node.
etcd_ssh() {
	local ip=$1
	shift
	# shellcheck disable=SC2029 # the command runs on the node, quoted by the callers
	ssh "${ETCD_SSH_OPTS[@]}" "core@${ip}" "$@"
}

# _etcd_proxy_env: "HTTP_PROXY=... HTTPS_PROXY=... NO_PROXY=..." from
# install-config.yaml, shell-quoted, for sudo env on the nodes (the restore
# script may pull the etcd image).
_etcd_proxy_env() {
	local k v out=()
	for k in httpProxy:HTTP_PROXY httpsProxy:HTTPS_PROXY noProxy:NO_PROXY; do
		v=$(ic ".proxy.${k%%:*}" 2>/dev/null || true)
		[[ -n ${v} ]] && out+=("$(printf '%s=%q' "${k#*:}" "${v}")")
	done
	printf '%s' "${out[*]}"
}

# _etcd_cluster_version: the running version, or okd.version without API.
_etcd_cluster_version() {
	local v=''
	_etcd_api_up && v=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
	printf '%s' "${v:-$(cfg '.okd.version')}"
}

# _etcd_vm_stopped <name>: the node's VM is not running (Proxmox API).
_etcd_vm_stopped() {
	local vmid
	vmid=$(nodes_query --arg n "$1" '.[] | select(.name == $n) | .vmid')
	[[ $(pve_cluster_vms | jq -r --argjson id "${vmid}" '.[] | select(.vmid == $id) | .status') == stopped ]]
}

# _etcd_members_count: regular etcd pods (with the etcdctl container, unlike
# the restore pod) that run and are ready.
_etcd_members_count() {
	oc -n openshift-etcd get pods -l app=etcd -o json --request-timeout=20s 2>/dev/null | jq '[.items[]
		| select((.spec.containers | map(.name) | index("etcdctl")) and .status.phase == "Running"
			and ([.status.containerStatuses[]?.ready] | all))] | length' 2>/dev/null || echo 0
}

_etcd_members_ready() {
	(($(_etcd_members_count) >= ${#ETCD_MASTERS[@]}))
}

# _etcd_masters: control plane node names into ETCD_MASTERS (several needed).
_etcd_masters() {
	mapfile -t ETCD_MASTERS < <(nodes_query '.[] | select(.agent_role == "master") | .name')
	((${#ETCD_MASTERS[@]} > 1)) || die "${EXIT_CONFIG}" "etcd restore supports clusters with several control plane nodes." \
		"Single node: follow the documented single-node procedure (docs/etcd-backup.md)."
}

# _etcd_restore_finish <recovery-ip> <start-seconds> [label]: the steps after
# cluster-restore.sh (also for 'etcd restore --continue'): wait for the API,
# quorum guard off, stable control plane, quorum guard on, clean up.
# Uses ETCD_MASTERS and ETCD_RESTORE_CLEANUP_IPS.
_etcd_restore_finish() {
	local rip=$1 start=$2 label=${3:-}
	log_step "Waiting for the API"
	local t0=${SECONDS}
	until _etcd_api_serving; do
		((SECONDS - t0 < 1800)) || die "${EXIT_ERROR}" "The API did not come back within 30 minutes." \
			"ssh core@${rip} 'sudo crictl ps --name etcd'; docs/etcd-backup.md"
		sleep 20
	done
	log_ok "API answers ($(elapsed "${t0}"))"

	log_step "Waiting for a stable control plane (quorum guard off)"
	_etcd_retry 900 oc patch etcd/cluster --type=merge -p "${ETCD_GUARD_OFF}" ||
		die "${EXIT_ERROR}" "Could not turn the etcd quorum guard off." \
			"oc patch etcd/cluster --type=merge -p '${ETCD_GUARD_OFF}', then: oc adm wait-for-stable-cluster; and turn it on again (docs/etcd-backup.md)"
	t0=${SECONDS}
	local stable=0 forced=0
	while ((SECONDS - t0 < ETCD_RESTORE_TIMEOUT)); do
		csr_approve_for "${ETCD_MASTERS[@]}" 2>/dev/null || true
		if _etcd_members_ready; then
			if oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=5m >/dev/null 2>&1; then
				stable=1
				break
			fi
		else
			# The restored operator status can claim every node is at the
			# current revision, so nothing rolls out: the documented
			# troubleshooting step forces a new revision.
			if ((! forced && SECONDS - t0 >= 600)); then
				log_info "etcd does not run on every control plane node yet: forcing an etcd redeployment"
				_etcd_retry 300 oc patch etcd cluster --type=merge \
					-p "{\"spec\": {\"forceRedeploymentReason\": \"recovery-$(date -u +%Y%m%dT%H%M%S)\"}}" && forced=1
			fi
			sleep 30
		fi
		log_info "Control plane not stable yet: $(_etcd_members_count)/${#ETCD_MASTERS[@]} etcd members running ($(elapsed "${t0}"))"
	done
	if ! ((stable)); then
		log_hint "If the etcd pods do not roll out: oc patch etcd cluster --type=merge -p '{\"spec\": {\"forceRedeploymentReason\": \"recovery-'\"\$(date --rfc-3339=ns)\"'\"}}'"
		log_hint "When the control plane is stable, turn the quorum guard on again: oc patch etcd/cluster --type=merge -p '{\"spec\": {\"unsupportedConfigOverrides\": null}}'"
		die "${EXIT_ERROR}" "The control plane did not become stable within $((ETCD_RESTORE_TIMEOUT / 60)) minutes."
	fi
	_etcd_retry 600 oc patch etcd/cluster --type=merge -p "${ETCD_GUARD_ON}" ||
		die "${EXIT_ERROR}" "Could not turn the etcd quorum guard on again." \
			"oc patch etcd/cluster --type=merge -p '${ETCD_GUARD_ON}'"
	local ip
	for ip in "${ETCD_RESTORE_CLEANUP_IPS[@]}"; do
		etcd_ssh "${ip}" "sudo rm -rf /home/core/okd-pve-restore-*" 2>/dev/null || log_warn "Could not delete /home/core/okd-pve-restore-* on ${ip}."
	done
	log_ok "etcd restored${label:+ from ${label}} in $(elapsed "${start}")"
	log_hint "Check the cluster with 'okd-pve verify'. Nodes created after the backup must join again (okd-pve node add --resume or node remove)."
}

# cmd_etcd_restore <name | --latest> [--recovery-host <node>] [--force]
#                  | --continue
cmd_etcd_restore() {
	local name='' recovery='' force=0 cont=0
	while (($#)); do
		case $1 in
		--latest) name=--latest && shift ;;
		--continue) cont=1 && shift ;;
		--recovery-host) recovery=${2:?--recovery-host needs a node name} && shift 2 ;;
		--force) force=1 && shift ;;
		-*) die "${EXIT_CONFIG}" "etcd restore: unknown argument $1" "okd-pve etcd restore <name|--latest> [--recovery-host <node>] [--force] | --continue" ;;
		*) name=$1 && shift ;;
		esac
	done
	[[ -n ${name} || ${cont} == 1 ]] || die "${EXIT_CONFIG}" "etcd restore needs a backup name or --latest." "okd-pve etcd list"
	# disable-etcd.sh and this procedure exist since 4.18.
	version_ge "$(okd_minor).0" 4.18.0 || die "${EXIT_CONFIG}" "etcd restore needs OKD 4.18 or newer (this cluster: $(okd_minor))." \
		"Follow the documented restore procedure of your release (docs/etcd-backup.md)."

	if ((cont)); then
		_etcd_masters
		etcd_ssh_opts
		log_step "Continuing the etcd restore after cluster-restore.sh"
		local n
		ETCD_RESTORE_CLEANUP_IPS=()
		for n in "${ETCD_MASTERS[@]}"; do ETCD_RESTORE_CLEANUP_IPS+=("$(nodes_query --arg n "${n}" '.[] | select(.name == $n) | .ip')"); done
		_etcd_restore_finish "${ETCD_RESTORE_CLEANUP_IPS[0]}" "${SECONDS}"
		return 0
	fi

	# 1. The backup, locally (copied from the cluster if the API still works).
	local dir
	dir=$(etcd_local_dir)
	if [[ ${name} == --latest ]]; then
		if _etcd_api_up && oc -n "${ETCD_BACKUP_NS}" get cronjob etcd-backup >/dev/null 2>&1; then
			cmd_etcd_fetch --latest
		fi
		name=$(_etcd_local_list | tail -n 1 | cut -f1)
		[[ -n ${name} ]] || die "${EXIT_ERROR}" "No local etcd backup in ${dir}." "okd-pve etcd fetch <name> while the API still answers"
	elif ! etcd_backup_valid "${dir}/${name}"; then
		_etcd_api_up || die "${EXIT_ERROR}" "${name} is not in ${dir} and the API does not answer, so it cannot be fetched." \
			"Copy the backup directory (snapshot_*.db and static_kuberesources_*.tar.gz) to ${dir}/${name}."
		cmd_etcd_fetch "${name}"
	fi
	local backup=${dir}/${name}
	etcd_backup_valid "${backup}" || die "${EXIT_ERROR}" "${backup} lacks snapshot_*.db or static_kuberesources_*.tar.gz."

	# 2. Same z-stream release as the cluster (documented requirement).
	local bver cver
	bver=$(cat "${backup}/version" 2>/dev/null || true)
	cver=$(_etcd_cluster_version)
	if [[ -n ${bver} && ${bver} != "${cver}" ]]; then
		((force)) || die "${EXIT_CONFIG}" "Backup ${name} is from ${bver}, the cluster runs ${cver}." \
			"A restore needs a backup of the same release. Use --force only if you know the cluster version is wrong."
		log_warn "Backup from ${bver}, cluster ${cver}: continuing because of --force."
	fi

	# 3. Control plane nodes and SSH.
	_etcd_masters
	local -a masters=("${ETCD_MASTERS[@]}")
	local -A ip_of=()
	local n ip
	while IFS=$'\t' read -r n ip; do
		ip_of[${n}]=${ip}
	done < <(nodes_query '.[] | select(.agent_role == "master") | "\(.name)\t\(.ip)"')
	recovery=${recovery:-${masters[0]}}
	[[ -n ${ip_of[${recovery}]:-} ]] || die "${EXIT_CONFIG}" "${recovery} is not a control plane node." "Choose one of: ${masters[*]}"

	etcd_ssh_opts
	local -a reachable=() unreachable=()
	local -A ssh_err=()
	for n in "${masters[@]}"; do
		if ((DRY_RUN)) || ssh_err[${n}]=$(etcd_ssh "${ip_of[${n}]}" true 2>&1); then
			reachable+=("${n}")
		else
			unreachable+=("${n}")
			ssh_err[${n}]=$(grep -v '^\s*$' <<<"${ssh_err[${n}]}" | head -n 1)
		fi
	done
	if [[ " ${reachable[*]} " != *" ${recovery} "* ]]; then
		local hint="Set OKD_PVE_SSH_PRIVATE_KEY_FILE to the key of install-config sshKey, or choose another host with --recovery-host."
		[[ ${ssh_err[${recovery}]} == *IDENTIFICATION* || ${ssh_err[${recovery}]} == *"Host key verification failed"* ]] &&
			hint="The node has a new host key (cluster rebuilt?): ssh-keygen -R ${ip_of[${recovery}]} -f ${STATE_DIR}/known_hosts"
		die "${EXIT_ERROR}" "No SSH to the recovery host ${recovery} (core@${ip_of[${recovery}]}): ${ssh_err[${recovery}]:-no answer}" "${hint}"
	fi
	# etcd must not keep a quorum elsewhere: a node without SSH must be off.
	if ((${#unreachable[@]})); then
		proxmox_require
		for n in "${unreachable[@]}"; do
			_etcd_vm_stopped "${n}" || die "${EXIT_ERROR}" "No SSH to ${n} (${ssh_err[${n}]:-no answer}), and its VM is running: etcd there could keep a quorum." \
				"Fix SSH to ${n}, or power the VM off in Proxmox, then run the restore again."
			log_warn "${n}: no SSH, VM is stopped. Start it after the restore; it rejoins on its own."
		done
	fi

	log_step "etcd restore from ${name}"
	log_info "Recovery host: ${recovery} (${ip_of[${recovery}]})"
	local -a others=()
	for n in "${reachable[@]}"; do [[ ${n} == "${recovery}" ]] || others+=("${n}"); done
	log_info "etcd is disabled first on: $(join_by ', ' "${others[@]}")"
	log_warn "This replaces the whole cluster state with the backup: everything changed after $(_etcd_backup_time "${name}") is lost."
	log_warn "The API is unavailable for up to 15 minutes or more."
	if dry_run_note "would copy ${name} to ${recovery}, run disable-etcd.sh on the other control plane nodes, cluster-restore.sh on ${recovery}, wait for a stable cluster"; then
		return 0
	fi
	confirm_typed "${CLUSTER_NAME}" "Type the cluster name (${CLUSTER_NAME}) to restore etcd" ||
		die "${EXIT_ERROR}" "Restore cancelled."

	local start=${SECONDS} remote=/home/core/okd-pve-restore-${name} env sudo
	env=$(_etcd_proxy_env)
	sudo="sudo -E${env:+ env ${env}}"

	log_step "Copying ${name} to ${recovery}"
	etcd_ssh "${ip_of[${recovery}]}" "rm -rf ${remote@Q} && mkdir -m 700 ${remote@Q}"
	scp -q "${ETCD_SSH_OPTS[@]}" "${backup}"/snapshot_*.db "${backup}"/static_kuberesources_*.tar.gz \
		"core@${ip_of[${recovery}]}:${remote}/" || die "${EXIT_ERROR}" "Copying the backup to ${recovery} failed."

	log_step "Disabling etcd on the other control plane nodes"
	for n in "${reachable[@]}"; do
		[[ ${n} == "${recovery}" ]] && continue
		run_visible "      | " etcd_ssh "${ip_of[${n}]}" "${sudo} /usr/local/bin/disable-etcd.sh" ||
			die "${EXIT_ERROR}" "disable-etcd.sh failed on ${n}." \
				"Nothing is restored yet. Check ${n} (ssh core@${ip_of[${n}]}); etcd comes back with: sudo mv /home/core/assets/manifests-stopped/etcd-pod.yaml /etc/kubernetes/manifests/"
	done

	log_step "Restoring on ${recovery}"
	# Older cluster-restore.sh versions refuse a data dir with anything but
	# member/ (the etcd operator leaves member-removed-archive-* there when a
	# node rejoins after a restore); newer ones move it aside like this.
	etcd_ssh "${ip_of[${recovery}]}" "${ETCD_DATA_DIR_TIDY}" ||
		die "${EXIT_ERROR}" "Could not tidy /var/lib/etcd on ${recovery}."
	run_visible "      | " etcd_ssh "${ip_of[${recovery}]}" "${sudo} /usr/local/bin/cluster-restore.sh ${remote@Q}" ||
		die "${EXIT_ERROR}" "cluster-restore.sh failed on ${recovery}; etcd is stopped on the control plane nodes." \
			"Fix the cause from the output above, run it again (ssh core@${ip_of[${recovery}]} sudo -E /usr/local/bin/cluster-restore.sh ${remote}), then: okd-pve etcd restore --continue"

	ETCD_RESTORE_CLEANUP_IPS=("${ip_of[${recovery}]}")
	_etcd_restore_finish "${ip_of[${recovery}]}" "${start}" "${name}"
}

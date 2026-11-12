# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# openshift-install agent workflow.
#
# `openshift-install agent create image` consumes and deletes the config
# files in its directory. The source files in the cluster directory are never
# handed to it: everything is rendered into a staging directory and copied
# into a fresh .generated/ right before the ISO is built. After that build,
# .generated/ holds the cluster's CA and must never be regenerated while the
# cluster exists.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_INSTALLER_LOADED:-} ]] && return 0
_OKD_PVE_INSTALLER_LOADED=1

AGENT_ISO_NAME=agent.x86_64.iso

# render_install_config <out-file>: install-config.yaml with replicas, pull
# secret and SSH key filled in. The source file is not modified.
render_install_config() {
	local out=$1 masters workers ps key
	masters=$(nodes_query '[.[] | select(.agent_role == "master")] | length')
	workers=$(nodes_query '[.[] | select(.agent_role == "worker")] | length')
	ps=$(pull_secret_value)
	# Only the first key: further keys break Ironic on baremetal (see
	# templates/preboot/ssh-keys.yaml.tpl); they are rolled out as Pre-Boot
	# MachineConfigs instead.
	key=$(ssh_keys_all | head -n 1)
	[[ -n ${key} ]] || die "${EXIT_CONFIG}" "No SSH public key found." \
		"Set sshKey in install-config.yaml or install.ssh_public_key_file in cluster.yaml."
	# Set compute[0].replicas by its full path: older yq (4.45) drops an
	# assignment inside "(.compute // [...]) | .[0].replicas = ...".
	PS=${ps} KEY=${key} MASTERS=${masters} WORKERS=${workers} yq '
		.controlPlane.name = (.controlPlane.name // "master") |
		.controlPlane.replicas = env(MASTERS) |
		.compute = (.compute // [{"name": "worker"}]) |
		.compute[0].replicas = env(WORKERS) |
		.pullSecret = strenv(PS) |
		.sshKey = strenv(KEY)
	' "${INSTALL_CONFIG_FILE}" >"${out}"
	chmod 600 "${out}"
	mirrors_render_install_config "${out}"
}

# render_agent_config <out-file>: agent-config.yaml generated from the node
# model (static IPs via nmstate, deterministic MACs, root device hints).
render_agent_config() {
	local out=$1
	nodes_json | jq_lib --slurpfile c "${CONFIG_JSON}" --arg cluster "${CLUSTER_NAME}" '
		include "nodes";
		$c[0] as $c
		| {
			apiVersion: "v1beta1",
			kind: "AgentConfig",
			metadata: {name: $cluster},
			rendezvousIP: $c.network.rendezvous_ip,
			additionalNTPSources: $c.network.ntp_servers,
			hosts: [.[] | {hostname: .name, role: .agent_role} + agent_host($c)]
		}' | yq -P '.' >"${out}"
}

# installer_stage <dir>: render all installer inputs into dir.
installer_stage() {
	local dir=$1
	rm -rf "${dir}"
	mkdir -p "${dir}/openshift"
	chmod 700 "${dir}"
	render_install_config "${dir}/install-config.yaml"
	render_agent_config "${dir}/agent-config.yaml"
	manifests_render "${dir}/openshift" >/dev/null 2>"${OKD_PVE_TMP}/manifests.err" || {
		cat "${OKD_PVE_TMP}/manifests.err" >&2
		die "${EXIT_CONFIG}" "Rendering Pre-Boot manifests failed." "Fix the manifest reported above."
	}
}

# installer_inputs_hash <dir>: fingerprint of everything that goes into the ISO.
installer_inputs_hash() {
	local dir=$1
	{
		cfg '.okd.version'
		# Only when on: existing clusters keep their hash.
		[[ $(cfg '.install.debug_shell') != true ]] || echo install.debug_shell
		find "${dir}" -type f | LC_ALL=C sort | while IFS= read -r f; do
			printf '%s\n' "${f#"${dir}"/}"
			cat "${f}"
		done
	} | sha256_stdin
}

# installer_create_image <stage-dir>: fresh .generated/ + agent ISO.
installer_create_image() {
	local stage=$1
	rm -rf "${GENERATED_DIR}"
	mkdir -p "${GENERATED_DIR}"
	chmod 700 "${GENERATED_DIR}"
	cp -a "${stage}/." "${GENERATED_DIR}/"
	log_info "openshift-install agent create image (takes a few minutes; downloads the base ISO on first use)"
	local start=${SECONDS}
	installer_run agent create image --dir "${GENERATED_DIR}" ||
		die "${EXIT_ERROR}" "openshift-install agent create image failed." \
			"See the messages above and ${GENERATED_DIR}/.openshift_install.log. Fix the cause and re-run create."
	[[ -f ${GENERATED_DIR}/${AGENT_ISO_NAME} ]] ||
		die "${EXIT_ERROR}" "openshift-install did not produce ${AGENT_ISO_NAME}." "See ${GENERATED_DIR}/.openshift_install.log."
	installer_iso_debug_shell "${GENERATED_DIR}/${AGENT_ISO_NAME}"
	installer_copy_auth
	log_ok "Agent ISO built in $(elapsed "${start}"): $(human_gib "$(wc -c <"${GENERATED_DIR}/${AGENT_ISO_NAME}")")"
}

# installer_iso_debug_shell <iso>: with install.debug_shell, the live ISO
# starts a root shell without password on tty9 (systemd debug-shell.service),
# reachable from the Proxmox console. For debugging an installation that
# hangs on a node without SSH, e.g. bootkube on the rendezvous node.
installer_iso_debug_shell() {
	[[ $(cfg '.install.debug_shell') == true ]] || return 0
	iso_append_karg "$1" systemd.debug_shell
	log_warn "install.debug_shell: every node has a root shell without password on tty9 while it runs from this ISO"
	log_hint "Proxmox console: Ctrl+Alt+F9 (noVNC side panel: toggle Ctrl and Alt, then F9; or on the host: qm sendkey <vmid> ctrl-alt-f9). Set install.debug_shell: false again after debugging."
}

# iso_append_karg <iso> <karg>: append a kernel argument to a CoreOS live
# ISO in place, as "coreos-installer iso kargs modify --append" does. The
# live kernel command line sits in fixed-size embed areas (EFI grub.cfg,
# isolinux.cfg): the arguments, a newline, '#' padding, then the marker
# "# COREOS_KARG_EMBED_AREA". The new argument overwrites the newline and the
# start of the padding, so no file in the ISO changes its size.
iso_append_karg() {
	local iso=$1 karg=$2 marker='# COREOS_KARG_EMBED_AREA' hit off match n=0
	if LC_ALL=C grep -qaF -- " ${karg}" "${iso}"; then
		log_debug "${iso##*/} already has ${karg}"
		return 0
	fi
	# Line mode: the padding starts a line. With -z, GNU grep 3.11 reports
	# wrong byte offsets in a large binary file.
	while IFS= read -r hit; do
		off=${hit%%:*}
		match=${hit#*:}
		# padding must hold " <karg>\n" and keep one '#'
		((${#match} - ${#marker} > ${#karg} + 2)) ||
			die "${EXIT_ERROR}" "The kernel argument area in ${iso##*/} is too small for ${karg}."
		[[ $(dd if="${iso}" bs=1 skip=$((off - 1)) count=1 2>/dev/null | od -An -tx1 | tr -d ' \n') == 0a ]] ||
			die "${EXIT_ERROR}" "Unexpected kernel argument area in ${iso##*/} at byte ${off}."
		printf ' %s\n' "${karg}" | dd of="${iso}" bs=1 seek=$((off - 1)) conv=notrunc 2>/dev/null ||
			die "${EXIT_ERROR}" "Cannot write ${karg} into ${iso##*/}."
		n=$((n + 1))
	done < <(LC_ALL=C grep -oba -- "^#\{16,\}${marker}" "${iso}")
	((n > 0)) || die "${EXIT_ERROR}" "${iso##*/} has no kernel argument area; cannot add ${karg}." \
		"Set install.debug_shell: false."
	log_debug "${karg} appended to ${n} kernel argument area(s) of ${iso##*/}"
}

# installer_iso_age_hours: age of the built agent ISO in full hours.
installer_iso_age_hours() {
	local iso=${GENERATED_DIR}/${AGENT_ISO_NAME}
	[[ -f ${iso} ]] || {
		echo 0
		return
	}
	echo $((($(date +%s) - $(file_mtime "${iso}")) / 3600))
}

installer_copy_auth() {
	[[ -d ${GENERATED_DIR}/auth ]] || return 0
	mkdir -p "${AUTH_DIR}"
	chmod 700 "${AUTH_DIR}"
	cp "${GENERATED_DIR}/auth/"* "${AUTH_DIR}/"
	chmod 600 "${AUTH_DIR}/"*
	[[ -f ${AUTH_DIR}/kubeadmin-password ]] && redact_register "$(cat "${AUTH_DIR}/kubeadmin-password")"
	return 0
}

# installer_run <args...>: openshift-install with readable output. The full
# log goes to the log file; stdout shows the info/warning/error messages.
installer_run() {
	local rc=0
	_log_to_file EXEC "openshift-install $*"
	set +e
	"${OPENSHIFT_INSTALL}" "$@" --log-level info 2>&1 | redact_stream --log "${LOG_FILE}" --echo '' | installer_pretty
	rc=${PIPESTATUS[0]}
	set -e
	return "${rc}"
}

# installer_pretty: turn logrus lines into short, colored progress lines.
installer_pretty() {
	(
		trap '' INT
		local line level msg
		while IFS= read -r line; do
			if [[ ${line} =~ level=([a-z]+)\ msg=\"(.*)\"$ ]]; then
				level=${BASH_REMATCH[1]} msg=${BASH_REMATCH[2]//\\\"/\"}
			elif [[ ${line} =~ level=([a-z]+)\ msg=(.*)$ ]]; then
				level=${BASH_REMATCH[1]} msg=${BASH_REMATCH[2]}
			else
				level=info msg=${line}
			fi
			[[ -n ${msg} ]] || continue
			case ${level} in
			debug | trace) ;;
			warning) printf '      %s! %s%s\n' "${C_YELLOW}" "${msg}" "${C_RESET}" ;;
			error | fatal) printf '      %sx %s%s\n' "${C_RED}" "${msg}" "${C_RESET}" ;;
			*) printf '      | %s\n' "${msg}" ;;
			esac
		done
	)
}

# installer_status_line: one-line cluster status for the long waits (nodes,
# operators, ClusterVersion progress); falls back to ping before the API is up.
installer_status_line() {
	local oc=${OC:-oc} kc=${KUBECONFIG_FILE} nodes cos cv up=0 total ip
	local -a parts=()
	if [[ -f ${kc} ]] && nodes=$(KUBECONFIG=${kc} timeout 15 "${oc}" get nodes -o json 2>/dev/null); then
		parts+=("nodes $(jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"${nodes}")/$(nodes_query 'length') Ready")
		if cos=$(KUBECONFIG=${kc} timeout 15 "${oc}" get clusteroperators -o json 2>/dev/null); then
			parts+=("operators $(jq -r '"\([.items[] | select(any(.status.conditions[]?; .type == "Available" and .status == "True"))] | length)/\(.items | length)"' <<<"${cos}") available")
		fi
		# While the first install is not complete, the CVO reports every
		# operator that is not up yet as "Unable to apply <version>: ...
		# MultipleErrors" and retries. That is normal; the operators it waits
		# for are listed by installer_status_details.
		cv=$(KUBECONFIG=${kc} timeout 15 "${oc}" get clusterversion version -o json 2>/dev/null | jq -r '
			([.status.conditions[]? | select(.type == "Progressing")][0].message // "") as $m
			| (.status.history[0] // {}) as $h
			| if ($m | startswith("Unable to apply")) and $h.state != "Completed"
				then "installing \($h.version // .status.desired.version // "OKD"), operators still starting"
				else $m end' 2>/dev/null || true)
		[[ -n ${cv} ]] && parts+=("${cv:0:110}")
		printf '%(%H:%M)T %s\n' -1 "$(join_by ' · ' "${parts[@]}")"
		installer_status_details "${cos:-}"
		installer_bootstrap_diag "${nodes}"
		return 0
	else
		total=0
		while IFS= read -r ip; do
			((++total))
			ping -c 1 -W 1 "${ip}" >/dev/null 2>&1 && ((++up))
		done < <(nodes_query '.[].ip')
		parts+=("API not reachable yet" "${up}/${total} nodes answer ping")
	fi
	printf '%(%H:%M)T %s\n' -1 "$(join_by ' · ' "${parts[@]}")"
	installer_bootstrap_diag
}

# installer_bootstrap_diag [nodes-json]: extra status lines until the
# bootstrap is done: the agent service's view of the hosts, and a missing
# Machine Config Server (see installer_mcs_check).
installer_bootstrap_diag() {
	state_step_done bootstrap 2>/dev/null && return 0
	installer_agent_status
	[[ -n ${1:-} ]] && installer_mcs_check "$1"
	return 0
}

# installer_agent_status: what the agent service on the rendezvous node
# reports while it runs (until that node boots from its disk): one summary
# line ("agent: installing · 2 Rebooting, 7 Waiting for control plane") and
# one line per host in error or pending-user-action, with the reason. The
# token reaches curl on stdin, never as an argument.
installer_agent_status() {
	local ip f=${GENERATED_DIR}/.openshift_install_state.json token id json base
	ip=$(cfg '.network.rendezvous_ip')
	[[ -n ${ip} && -f ${f} ]] || return 0
	token=$(jq -r '."*gencrypto.AuthConfig".UserAuthToken // empty' "${f}" 2>/dev/null) || return 0
	[[ -n ${token} ]] || return 0
	redact_register "${token}"
	base=http://${ip}:8090/api/assisted-install/v2
	id=$(printf 'header = "Authorization: %s"\n' "${token}" |
		curl -s --noproxy '*' -m 10 -K - "${base}/clusters" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null) || return 0
	[[ -n ${id} ]] || return 0
	json=$(printf 'header = "Authorization: %s"\n' "${token}" |
		curl -s --noproxy '*' -m 10 -K - "${base}/clusters/${id}" 2>/dev/null) || return 0
	jq -r '(.hosts // []) as $h
		| "agent: \(.status) · " + ([$h[] | .progress.current_stage // .status] | group_by(.) | map("\(length) \(.[0])") | join(", ")),
		  ($h[] | select(.status | test("error|pending-user-action"))
			| "agent: \(.requested_hostname // .id) \(.status): \(.status_info // "" | gsub("\\s+"; " ") | .[0:140])")' <<<"${json}" 2>/dev/null
}

# installer_mcs_check <nodes-json>: while masters are missing, they fetch
# their configuration from the Machine Config Server on the API VIP (port
# 22623). Three checks in a row without an answer while the API is up mean
# it did not start, typically because the bootstrap machine-config-controller
# crashes; the masters then wait forever.
installer_mcs_check() {
	local nodes=$1 vip ready want code n=0 f=${OKD_PVE_TMP}/mcs-down
	vip=$(ic '.platform.baremetal.apiVIPs[0]')
	[[ -n ${vip} ]] || return 0
	want=$(nodes_query '[.[] | select(.agent_role == "master")] | length')
	ready=$(jq -r '[.items[] | select(.metadata.labels["node-role.kubernetes.io/master"] != null)
		| select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"${nodes}" 2>/dev/null) || return 0
	((ready < want)) || {
		rm -f "${f}"
		return 0
	}
	code=$(curl -sk --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' "https://${vip}:22623/healthz" 2>/dev/null) || true
	if [[ ${code} == 200 ]]; then
		rm -f "${f}"
		return 0
	fi
	n=$(($(cat "${f}" 2>/dev/null || echo 0) + 1))
	echo "${n}" >"${f}"
	((n >= 3)) || return 0
	printf 'Machine Config Server https://%s:22623 does not answer (%s of %s masters Ready): the other masters cannot get their configuration. See README, Troubleshooting (install.debug_shell).\n' \
		"${vip}" "${ready}" "${want}"
}

# installer_status_details <clusteroperators-json>: why the cluster is not
# done yet: unavailable/degraded operators with their message and pods in
# openshift-* namespaces that crash or cannot pull their image.
installer_status_details() {
	local cos=$1 pods
	if [[ -n ${cos} ]]; then
		jq -r '[.items[]
			| (.status.conditions // []) as $c
			| select(any($c[]; .type == "Degraded" and .status == "True")
				or (any($c[]; .type == "Available" and .status == "True") | not))
			| "waiting on \(.metadata.name): \(
				([$c[] | select(.type == "Degraded" and .status == "True") | .message]
				 + [$c[] | select(.type == "Available" and .status != "True") | .message])[0] // "no status yet"
				| gsub("\\s+"; " ") | .[0:150])"]
			| (.[0:3][]), (if length > 3 then "… and \(length - 3) more operator(s)" else empty end)' <<<"${cos}" 2>/dev/null
	fi
	pods=$(KUBECONFIG=${KUBECONFIG_FILE} timeout 20 "${OC:-oc}" get pods -A -o json 2>/dev/null) || return 0
	jq -r '[.items[] | select(.metadata.namespace | startswith("openshift-"))
		| . as $p | (.status.containerStatuses // [])[]
		| select(.state.waiting.reason // "" | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError"))
		| "\(.state.waiting.reason): \($p.metadata.namespace)/\($p.metadata.name) (\(.name), \(.restartCount) restarts)"]
		| unique | (.[0:3][]), (if length > 3 then "… and \(length - 3) more pod(s)" else empty end)' <<<"${pods}" 2>/dev/null
}

# installer_fixups: workarounds for known installer bugs, applied while
# waiting for install-complete. Idempotent; logs what it changed.
#  - OKD 5.0 generates Machine/MachineSet hostSelectors with an empty
#    "notin" expression, which the baremetal machine controller rejects, so
#    machines never leave Provisioning. "notin []" excludes nothing; dropping
#    the expression keeps the meaning.
installer_fixups() {
	local kc=${KUBECONFIG_FILE} oc=${OC:-oc} kind obj fixed
	[[ -f ${kc} ]] || return 0
	for kind in machinesets machines; do
		while IFS=$'\t' read -r obj fixed; do
			[[ -n ${obj} ]] || continue
			if KUBECONFIG=${kc} timeout 20 "${oc}" -n openshift-machine-api patch "${kind}/${obj}" --type merge -p "${fixed}" >/dev/null 2>&1; then
				_log_to_file FIXUP "${kind}/${obj}: removed empty notin hostSelector expression (installer bug)"
				printf 'workaround: %s/%s had an empty "notin" hostSelector (OKD installer bug), fixed\n' "${kind}" "${obj}"
			fi
		done < <(KUBECONFIG=${kc} timeout 20 "${oc}" -n openshift-machine-api get "${kind}" -o json 2>/dev/null | jq -r --arg kind "${kind}" '
			.items[]
			| (if $kind == "machinesets" then ["spec", "template", "spec", "providerSpec", "value", "hostSelector"]
			   else ["spec", "providerSpec", "value", "hostSelector"] end) as $path
			| getpath($path) as $sel
			| select($sel.matchExpressions // [] | any(.operator == "notin" and ((.values // []) | length) == 0))
			| ($sel.matchExpressions | map(select((.operator == "notin" and ((.values // []) | length) == 0) | not))) as $kept
			| [.metadata.name, ({} | setpath($path; {matchExpressions: $kept}) | tojson)] | @tsv')
	done
}

# installer_recover_hosts: the agent service gives up on hosts after fixed
# stage timeouts (90 min "Waiting for control plane", 60 min "Waiting for
# controller"), which slow image downloads exceed. Such a host ends in "error"
# and stays in the live ISO although its disk is already written:
# - a worker that waited too long for two Ready masters (it writes its disk
#   before that wait),
# - the rendezvous node, which boots from its disk only after every other host
#   has reported to the agent service running on it. Without it there is no
#   third etcd member and the installation never completes. In "Waiting for
#   control plane" it is still the bootstrap node and is left alone.
# The in-cluster assisted-installer-controller logs the host states. Each such
# host missing from oc get nodes is reset once (it boots from its disk and
# joins), then its CSRs are approved, which the controller no longer does.
# install.recover_stuck_hosts: false turns this off.
installer_recover_hosts() {
	local kc=${KUBECONFIG_FILE} oc=${OC:-oc} rv_ip states name vmid ip stage what vm
	local -a joining=()
	[[ -f ${kc} && $(cfg '.install.recover_stuck_hosts') == true ]] || return 0
	# the name in 0.1.2
	[[ $(cfg '.install.recover_rendezvous') != false ]] || return 0
	rv_ip=$(cfg '.network.rendezvous_ip')
	states=$(KUBECONFIG=${kc} timeout 30 "${oc}" -n assisted-installer logs job/assisted-installer-controller 2>/dev/null |
		grep -o 'Hosts status: map\[.*' | tail -n 1) || true
	while IFS=$'\t' read -r name vmid ip; do
		if [[ -f ${STATE_DIR}/recovered-${name} ]]; then
			[[ $(KUBECONFIG=${kc} timeout 15 "${oc}" get node "${name}" \
				-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]] ||
				joining+=("${name}")
			continue
		fi
		stage="Waiting for control plane" what=${name}
		[[ ${ip} == "${rv_ip}" ]] && stage="Waiting for controller" what="rendezvous node ${name}"
		[[ ${states} == *"[${name}:[error ${stage}"* || ${states} == *" ${name}:[error ${stage}"* ]] || continue
		KUBECONFIG=${kc} timeout 15 "${oc}" get node "${name}" >/dev/null 2>&1 && continue
		vm=$(pve_cluster_vms 2>/dev/null | jq -r --argjson id "${vmid}" '.[] | select(.vmid == $id) | "\(.node)\t\(.status)"') || true
		if [[ ${vm#*$'\t'} != running ]]; then
			printf 'recovery: the agent installer gave up on %s, but VM %s is not running (%s); start it in Proxmox\n' \
				"${what}" "${vmid}" "${vm#*$'\t'}"
			continue
		fi
		if ! pve_vm_reset "${vm%%$'\t'*}" "${vmid}" >/dev/null; then
			_log_to_file RECOVER "reset of VM ${vmid} failed: ${PVE_API_ERROR}"
			printf 'recovery: could not reset VM %s (%s); reset it in Proxmox, then approve its CSRs\n' "${vmid}" "${PVE_API_ERROR}"
			continue
		fi
		printf '%(%Y-%m-%dT%H:%M:%S%z)T\n' -1 >"${STATE_DIR}/recovered-${name}"
		_log_to_file RECOVER "${what}: ${states}"
		printf 'recovery: the agent installer gave up on %s ("%s" timed out), so it stayed in the live ISO; reset VM %s to boot it from its installed disk, its CSRs are approved when it joins\n' \
			"${what}" "${stage}" "${vmid}"
	done < <(nodes_query '.[] | [.name, .vmid, .ip] | @tsv')
	((${#joining[@]})) || return 0
	(
		export KUBECONFIG=${kc}
		[[ ${oc} == */* ]] && PATH=$(dirname "${oc}"):${PATH}
		csr_approve_for "${joining[@]}"
	) 2>/dev/null | sed 's/^ *//'
}

# installer_status_loop <interval-seconds>: print a status line periodically.
installer_status_loop() {
	local interval=$1 line first
	while sleep "${interval}"; do
		first=1
		while IFS= read -r line; do
			_log_to_file STATUS "${line}"
			if ((first)); then
				printf '      %s· %s%s\n' "${C_DIM}" "${line}" "${C_RESET}"
				first=0
			else
				printf '        %s%s%s\n' "${C_YELLOW}" "${line}" "${C_RESET}"
			fi
		done < <(
			installer_fixups 2>/dev/null
			installer_recover_hosts 2>/dev/null
			installer_status_line 2>/dev/null
		)
	done
}

INSTALLER_STATUS_PID=''
_installer_status_stop() {
	[[ -n ${INSTALLER_STATUS_PID} ]] || return 0
	# Kill the pending sleep too, or it keeps stdout open after we return.
	pkill -P "${INSTALLER_STATUS_PID}" 2>/dev/null || true
	kill "${INSTALLER_STATUS_PID}" 2>/dev/null || true
	wait "${INSTALLER_STATUS_PID}" 2>/dev/null || true
	INSTALLER_STATUS_PID=''
}

# installer_prune_failed_installers: delete failed installer pods of the
# control-plane operators whose revision the node has already replaced.
# Bootstrap races (e.g. a ConfigMap that does not exist yet) leave them
# behind: the operator rolls out a newer revision but keeps the failed pods,
# which look like errors in the console. Failed pods of the current revision
# stay, they point to a real problem.
installer_prune_failed_installers() {
	local kc=${KUBECONFIG_FILE} oc=${OC:-oc} op ns revs pod n=0
	for op in kubeapiserver:openshift-kube-apiserver kubecontrollermanager:openshift-kube-controller-manager \
		kubescheduler:openshift-kube-scheduler etcd:openshift-etcd; do
		ns=${op#*:}
		revs=$(KUBECONFIG=${kc} timeout 20 "${oc}" get "${op%%:*}" cluster -o json 2>/dev/null |
			jq -c '[.status.nodeStatuses[]? | {key: .nodeName, value: (.currentRevision // 0)}] | from_entries' 2>/dev/null) || true
		[[ -n ${revs} ]] || continue
		while IFS= read -r pod; do
			[[ -n ${pod} ]] || continue
			KUBECONFIG=${kc} timeout 30 "${oc}" -n "${ns}" delete pod "${pod}" >/dev/null 2>&1 && ((++n))
		done < <(KUBECONFIG=${kc} timeout 20 "${oc}" -n "${ns}" get pods -l app=installer -o json 2>/dev/null | jq -r --argjson cur "${revs}" '
			.items[] | select(.status.phase == "Failed" and (.metadata.name | test("^installer-[0-9]+-")))
			| select((.metadata.name | capture("^installer-(?<r>[0-9]+)-").r | tonumber) < ($cur[.spec.nodeName] // 0))
			| .metadata.name' 2>/dev/null)
	done
	((n == 0)) || log_info "Removed ${n} failed installer pod(s) of revisions the nodes have already replaced (bootstrap races)"
}

# installer_progress: how far the cluster is ("2 nodes Ready, 29 operators
# available"); empty while the API is not reachable.
installer_progress() {
	local oc=${OC:-oc} kc=${KUBECONFIG_FILE} nodes cos
	[[ -f ${kc} ]] || return 0
	nodes=$(KUBECONFIG=${kc} timeout 15 "${oc}" get nodes -o json 2>/dev/null) || return 0
	cos=$(KUBECONFIG=${kc} timeout 15 "${oc}" get clusteroperators -o json 2>/dev/null) || cos='{"items":[]}'
	printf '%s nodes Ready, %s operators available\n' \
		"$(jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"${nodes}")" \
		"$(jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Available" and .status == "True"))] | length' <<<"${cos}")"
}

# installer_wait_timed_out: the last wait-for ended because openshift-install
# ran out of time, not because the installation failed.
installer_wait_timed_out() {
	tail -n 40 "${GENERATED_DIR}/.openshift_install.log" 2>/dev/null |
		grep -qE 'context deadline exceeded|timed out|Timed out'
}

# installer_nodes_answering: "<answering>/<total>" nodes that answer ping.
installer_nodes_answering() {
	local ip up=0 total=0
	while IFS= read -r ip; do
		((++total))
		ping -c 1 -W 1 "${ip}" >/dev/null 2>&1 && ((++up))
	done < <(nodes_query '.[].ip')
	printf '%s/%s' "${up}" "${total}"
}

# installer_wait_failed <what> <error> <hint>: exit after a failed wait. A
# timeout usually means a slow installation (image downloads through a proxy
# or registry), not a broken one: say so, and that create keeps waiting when
# started again. Other failures end with <error> and <hint>.
installer_wait_failed() {
	local what=$1 error=$2 hint=$3
	installer_wait_timed_out || die "${EXIT_ERROR}" "${error}" "${hint}"
	log_warn "openshift-install stopped waiting for ${what} after its fixed timeout ($(installer_nodes_answering) nodes answer ping)."
	log_hint "The installation is most likely still running: slow image downloads (proxy, registry) can take longer than openshift-install waits."
	log_hint "Next step: start 'okd-pve create' again. It skips the ISO and the VMs and keeps waiting where it stopped."
	log_hint "If it times out again without progress: ${hint}"
	local line
	while IFS= read -r line; do
		[[ -n ${line} ]] && log_warn "${line}"
	done < <(
		installer_agent_status | grep -E 'error:|pending-user-action:'
		[[ $(cat "${OKD_PVE_TMP}/mcs-down" 2>/dev/null || echo 0) -ge 3 ]] &&
			echo "The Machine Config Server on the API VIP (port 22623) did not answer; see README, Troubleshooting."
	)
	[[ -n ${LOG_FILE} && -f ${LOG_FILE} ]] && log_hint "Full log: ${LOG_FILE}"
	exit "${EXIT_ERROR}"
}

# installer_wait <bootstrap-complete|install-complete>: wait-for with a
# status line every OKD_PVE_STATUS_INTERVAL seconds (default 120, 0 = off).
# openshift-install gives up after a fixed time, counted from when it starts
# waiting, not from when the cluster actually started installing. While the
# cluster still makes progress (more nodes Ready or operators available), wait
# again, up to OKD_PVE_WAIT_RETRIES times (default 3).
installer_wait() {
	local interval=${OKD_PVE_STATUS_INTERVAL:-120} retries=${OKD_PVE_WAIT_RETRIES:-3}
	local rc attempt=1 before after
	if ((interval > 0)); then
		installer_status_loop "${interval}" &
		INSTALLER_STATUS_PID=$!
		# Background jobs ignore SIGINT in scripts; stop it on every exit path.
		on_exit _installer_status_stop
	fi
	while :; do
		before=$(installer_progress)
		rc=0
		installer_run agent wait-for "$1" --dir "${GENERATED_DIR}" || rc=$?
		# Done, interrupted (signal) or out of retries.
		((rc != 0 && rc < 128 && attempt <= retries)) || break
		after=$(installer_progress)
		[[ -n ${after} && ${after} != "${before}" ]] || break
		# Hosts the agent gave up on do not recover by waiting longer.
		if installer_agent_status | grep -qE 'error:|pending-user-action:'; then
			log_warn "The agent service reports hosts that need attention; not waiting again."
			break
		fi
		log_warn "openshift-install stopped waiting, but the cluster is still progressing (${before:-API not reachable} -> ${after}); waiting again (${attempt}/${retries})"
		((++attempt))
	done
	_installer_status_stop
	return "${rc}"
}

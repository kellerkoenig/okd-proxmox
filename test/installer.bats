#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# install-config.yaml / agent-config.yaml rendering (lib/installer.sh).

setup() {
	load test_helper
	load_libs
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	load_cluster
}

@test "install-config: replicas, pull secret and SSH key filled in, source untouched" {
	local before
	before=$(sha256sum "${CLUSTER}/install-config.yaml")
	render_install_config "${BATS_TEST_TMPDIR}/ic.yaml"
	assert_equal "$(sha256sum "${CLUSTER}/install-config.yaml")" "${before}"
	assert_equal "$(yq -r '.controlPlane.replicas' "${BATS_TEST_TMPDIR}/ic.yaml")" 3
	assert_equal "$(yq -r '.compute[0].replicas' "${BATS_TEST_TMPDIR}/ic.yaml")" 3
	assert_equal "$(yq -r '.compute[0].name' "${BATS_TEST_TMPDIR}/ic.yaml")" worker
	assert_equal "$(yq -r '.pullSecret' "${BATS_TEST_TMPDIR}/ic.yaml")" "${OKD_FAKE_PULL_SECRET}"
	assert_equal "$(yq -r '.sshKey' "${BATS_TEST_TMPDIR}/ic.yaml" | cut -d' ' -f1)" ssh-ed25519
	assert_equal "$(yq -r '.platform.baremetal.apiVIPs[0]' "${BATS_TEST_TMPDIR}/ic.yaml")" 192.0.2.5
	assert_equal "$(file_mode "${BATS_TEST_TMPDIR}/ic.yaml")" 600
}

@test "install-config: an existing pullSecret is kept" {
	yq_set '.pullSecret = "{\"auths\":{\"registry.example.com\":{\"auth\":\"eDp5\"}}}"' "${CLUSTER}/install-config.yaml"
	load_cluster
	render_install_config "${BATS_TEST_TMPDIR}/ic.yaml"
	assert_equal "$(yq -r '.pullSecret | fromjson | .auths | keys | .[0]' "${BATS_TEST_TMPDIR}/ic.yaml")" registry.example.com
}

@test "install-config: missing SSH key is a configuration error" {
	rm -f "${HOME}/.ssh/id_ed25519.pub"
	run render_install_config "${BATS_TEST_TMPDIR}/ic.yaml"
	assert_failure 2
	assert_output --partial "No SSH public key"
}

@test "agent-config: rendezvous IP, NTP, hosts with roles, MACs, static IPs" {
	render_agent_config "${BATS_TEST_TMPDIR}/ac.yaml"
	local f=${BATS_TEST_TMPDIR}/ac.yaml
	assert_equal "$(yq -r '.kind' "${f}")" AgentConfig
	assert_equal "$(yq -r '.rendezvousIP' "${f}")" 192.0.2.11
	assert_equal "$(yq -r '.additionalNTPSources | length' "${f}")" 3
	assert_equal "$(yq -r '.hosts | length' "${f}")" 6
	assert_equal "$(yq -r '[.hosts[] | select(.role == "master")] | length' "${f}")" 3
	assert_equal "$(yq -r '.hosts[3].hostname' "${f}")" small-worker-0
	assert_equal "$(yq -r '.hosts[3].role' "${f}")" worker
	assert_equal "$(yq -r '.hosts[3].interfaces[0].macAddress' "${f}")" 02:00:41:00:10:18
	assert_equal "$(yq -r '.hosts[3].networkConfig.interfaces[0].ipv4.address[0].ip' "${f}")" 192.0.2.21
	assert_equal "$(yq -r '.hosts[3].networkConfig.interfaces[0].ipv4.dhcp' "${f}")" false
	assert_equal "$(yq -r '.hosts[3].rootDeviceHints.serialNumber' "${f}")" okd4120d0
	assert_equal "$(yq -r '.hosts[3].networkConfig."dns-resolver".config.server[0]' "${f}")" 192.0.2.53
}

@test "agent-config: root device hint can be disabled" {
	yq_set '.proxmox.root_device_hint = "none"'
	load_cluster
	render_agent_config "${BATS_TEST_TMPDIR}/ac.yaml"
	assert_equal "$(yq -r '.hosts[0] | has("rootDeviceHints")' "${BATS_TEST_TMPDIR}/ac.yaml")" false
}

@test "installer_stage + inputs hash change when the configuration changes" {
	command -v butane >/dev/null || skip "butane not installed"
	BUTANE=$(command -v butane)
	installer_stage "${BATS_TEST_TMPDIR}/stage"
	assert [ -f "${BATS_TEST_TMPDIR}/stage/install-config.yaml" ]
	assert [ -f "${BATS_TEST_TMPDIR}/stage/agent-config.yaml" ]
	assert [ -f "${BATS_TEST_TMPDIR}/stage/openshift/99-worker-okd-pve-chrony.yaml" ]
	local h1 h2
	h1=$(installer_inputs_hash "${BATS_TEST_TMPDIR}/stage")
	yq_set '.network.ntp_servers += ["192.0.2.126"]'
	load_cluster
	installer_stage "${BATS_TEST_TMPDIR}/stage"
	h2=$(installer_inputs_hash "${BATS_TEST_TMPDIR}/stage")
	assert [ "${h1}" != "${h2}" ]
}

@test "installer_pretty turns installer log lines into short progress lines" {
	run installer_pretty <<'LOG'
level=info msg="Cluster is not ready for install. Check validations"
level=debug msg="noise"
level=warning msg="Host small-master-1: updated status from \"discovering\" to \"insufficient\""
level=error msg="Bootstrap failed"
plain line
LOG
	assert_line --index 0 "      | Cluster is not ready for install. Check validations"
	assert_line --index 1 '      ! Host small-master-1: updated status from "discovering" to "insufficient"'
	assert_line --index 2 "      x Bootstrap failed"
	assert_line --index 3 "      | plain line"
}

@test "installer_status_line: nodes, operators and ClusterVersion progress" {
	mkdir -p "${AUTH_DIR}"
	echo "apiVersion: v1" >"${KUBECONFIG_FILE}"
	OC=${BATS_TEST_TMPDIR}/fake-oc
	cat >"${OC}" <<'SH'
#!/usr/bin/env bash
case "$2" in
nodes) echo '{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}' ;;
clusteroperators) echo '{"items":[{"metadata":{"name":"etcd"},"status":{"conditions":[{"type":"Available","status":"True"}]}},{"metadata":{"name":"ingress"},"status":{"conditions":[]}}]}' ;;
clusterversion) echo '{"status":{"conditions":[{"type":"Progressing","message":"Working towards 5.0.0-okd-scos.3: 512 of 863 done (59% complete)"}]}}' ;;
esac
SH
	chmod +x "${OC}"
	run installer_status_line
	assert_success
	assert_line --index 0 --regexp '^[0-9]{2}:[0-9]{2} nodes 1/6 Ready · operators 1/2 available · Working towards 5.0.0-okd-scos.3: 512 of 863 done \(59% complete\)$'
	assert_line --index 1 "waiting on ingress: no status yet"
}

@test "installer_status_line: the CVO's MultipleErrors during the first install is shown as progress" {
	mkdir -p "${AUTH_DIR}"
	echo "apiVersion: v1" >"${KUBECONFIG_FILE}"
	OC=${BATS_TEST_TMPDIR}/fake-oc
	cat >"${OC}" <<'SH'
#!/usr/bin/env bash
case "$2" in
nodes) echo '{"items":[]}' ;;
clusteroperators) echo '{"items":[]}' ;;
clusterversion) echo '{"status":{"history":[{"state":"Partial","version":"4.22.0-okd-scos.10"}],"conditions":[{"type":"Progressing","message":"Unable to apply 4.22.0-okd-scos.10: an unknown error has occurred: MultipleErrors"}]}}' ;;
esac
SH
	chmod +x "${OC}"
	run installer_status_line
	assert_success
	assert_line --index 0 --regexp 'operators 0/0 available · installing 4\.22\.0-okd-scos\.10, operators still starting$'
	refute_output --partial MultipleErrors
}

@test "installer_wait: waits again while the cluster progresses, gives up without progress" {
	mkdir -p "${AUTH_DIR}"
	echo "apiVersion: v1" >"${KUBECONFIG_FILE}"
	export OKD_PVE_STATUS_INTERVAL=0 CALLS=${BATS_TEST_TMPDIR}/calls
	# openshift-install times out twice, then succeeds.
	OPENSHIFT_INSTALL=${BATS_TEST_TMPDIR}/fake-install
	cat >"${OPENSHIFT_INSTALL}" <<'SH'
#!/usr/bin/env bash
echo x >>"${CALLS}"
(($(wc -l <"${CALLS}") > 2)) && exit 0
echo 'level=error msg="bootstrap process timed out: context deadline exceeded"'
exit 1
SH
	# One more Ready node every time it is asked.
	OC=${BATS_TEST_TMPDIR}/fake-oc
	cat >"${OC}" <<'SH'
#!/usr/bin/env bash
case "$2" in
nodes) echo y >>"${CALLS}.oc"; jq -n --argjson n "$(wc -l <"${CALLS}.oc")" '{items: [range($n) | {status: {conditions: [{type: "Ready", status: "True"}]}}]}' ;;
clusteroperators) echo '{"items":[]}' ;;
esac
SH
	chmod +x "${OPENSHIFT_INSTALL}" "${OC}"
	run installer_wait bootstrap-complete
	assert_success
	assert_output --partial "cluster is still progressing (1 nodes Ready, 0 operators available -> 2 nodes Ready, 0 operators available); waiting again (1/3)"
	assert_output --partial "waiting again (2/3)"
	assert_equal "$(wc -l <"${CALLS}")" 3

	# Without progress (API not reachable) the first timeout is final.
	rm -f "${CALLS}" "${CALLS}.oc"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${OC}"
	run installer_wait bootstrap-complete
	assert_failure 1
	refute_output --partial "waiting again"
	assert_equal "$(wc -l <"${CALLS}")" 1
}

@test "installer_prune_failed_installers: only failed pods of replaced revisions are deleted" {
	mkdir -p "${AUTH_DIR}"
	echo "apiVersion: v1" >"${KUBECONFIG_FILE}"
	export DELETED=${BATS_TEST_TMPDIR}/deleted
	OC=${BATS_TEST_TMPDIR}/fake-oc
	cat >"${OC}" <<'SH'
#!/usr/bin/env bash
case "$*" in
"get kubecontrollermanager cluster -o json")
	echo '{"status":{"nodeStatuses":[{"nodeName":"m1","currentRevision":8},{"nodeName":"m2","currentRevision":8}]}}' ;;
"-n openshift-kube-controller-manager get pods -l app=installer -o json")
	echo '{"items":[
	 {"metadata":{"name":"installer-5-m1"},"spec":{"nodeName":"m1"},"status":{"phase":"Failed"}},
	 {"metadata":{"name":"installer-5-retry-1-m1"},"spec":{"nodeName":"m1"},"status":{"phase":"Failed"}},
	 {"metadata":{"name":"installer-8-m1"},"spec":{"nodeName":"m1"},"status":{"phase":"Succeeded"}},
	 {"metadata":{"name":"installer-8-m2"},"spec":{"nodeName":"m2"},"status":{"phase":"Failed"}}]}' ;;
"-n openshift-kube-controller-manager delete pod "*) echo "${*: -1}" >>"${DELETED}" ;;
*) exit 1 ;;
esac
SH
	chmod +x "${OC}"
	run installer_prune_failed_installers
	assert_success
	assert_output --partial "Removed 2 failed installer pod(s)"
	assert_equal "$(sort "${DELETED}" | paste -sd' ' -)" "installer-5-m1 installer-5-retry-1-m1"
}

@test "installer_status_line: before the API is up it counts nodes answering ping" {
	use_mocks
	export MOCK_PING_UP="192.0.2.11 192.0.2.12"
	run installer_status_line
	assert_success
	assert_output --regexp 'API not reachable yet · 2/6 nodes answer ping$'
}

@test "installer_status_details: blocking operators with reason and crashlooping pods" {
	OC=${BATS_TEST_TMPDIR}/fake-oc
	cat >"${OC}" <<'SH'
#!/usr/bin/env bash
echo '{"items":[
 {"metadata":{"namespace":"openshift-machine-api","name":"metal3-abc"},"status":{"containerStatuses":[{"name":"metal3-ironic","restartCount":7,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}},
 {"metadata":{"namespace":"apps","name":"user-pod"},"status":{"containerStatuses":[{"name":"x","restartCount":3,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}'
SH
	chmod +x "${OC}"
	run installer_status_details '{"items":[
		{"metadata":{"name":"ok"},"status":{"conditions":[{"type":"Available","status":"True"}]}},
		{"metadata":{"name":"machine-api"},"status":{"conditions":[{"type":"Available","status":"False","message":"Operator is initializing"},
			{"type":"Degraded","status":"True","message":"minimum worker replica count (2) not yet met"}]}}]}'
	assert_success
	assert_line --index 0 "waiting on machine-api: minimum worker replica count (2) not yet met"
	assert_line --index 1 "CrashLoopBackOff: openshift-machine-api/metal3-abc (metal3-ironic, 7 restarts)"
	assert_equal "${#lines[@]}" 2
}

@test "installer_fixups removes empty notin hostSelector expressions and keeps others" {
	mkdir -p "${AUTH_DIR}"
	echo "apiVersion: v1" >"${KUBECONFIG_FILE}"
	OC=${BATS_TEST_TMPDIR}/fake-oc
	export PATCH_LOG=${BATS_TEST_TMPDIR}/patches
	cat >"${OC}" <<'SH'
#!/usr/bin/env bash
if [[ $3 == patch ]]; then echo "$4 $8" >>"${PATCH_LOG}"; exit 0; fi
case $4 in
machinesets) echo '{"items":[{"metadata":{"name":"ms"},"spec":{"template":{"spec":{"providerSpec":{"value":{"hostSelector":{"matchExpressions":[{"key":"coreos.openshift.io/stream","operator":"notin","values":null},{"key":"rack","operator":"in","values":["a"]}]}}}}}}}]}' ;;
machines) echo '{"items":[{"metadata":{"name":"ok"},"spec":{"providerSpec":{"value":{"hostSelector":{}}}}},{"metadata":{"name":"m0"},"spec":{"providerSpec":{"value":{"hostSelector":{"matchExpressions":[{"key":"coreos.openshift.io/stream","operator":"notin","values":[]}]}}}}}]}' ;;
esac
SH
	chmod +x "${OC}"
	run installer_fixups
	assert_success
	assert_line --index 0 'workaround: machinesets/ms had an empty "notin" hostSelector (OKD installer bug), fixed'
	assert_line --index 1 'workaround: machines/m0 had an empty "notin" hostSelector (OKD installer bug), fixed'
	run cat "${PATCH_LOG}"
	assert_line --index 0 'machinesets/ms {"spec":{"template":{"spec":{"providerSpec":{"value":{"hostSelector":{"matchExpressions":[{"key":"rack","operator":"in","values":["a"]}]}}}}}}}'
	assert_line --index 1 'machines/m0 {"spec":{"providerSpec":{"value":{"hostSelector":{"matchExpressions":[]}}}}}'
}

@test "several SSH keys: install-config gets the first, the rest become Pre-Boot MachineConfigs" {
	command -v butane >/dev/null || skip "butane not installed"
	BUTANE=$(command -v butane)
	yq_set '.sshKey = "ssh-ed25519 AAAAfirst one@example.com\nssh-ed25519 AAAAsecond two@example.com\n"' "${CLUSTER}/install-config.yaml"
	yq_set '.install.additional_ssh_keys = ["ssh-ed25519 AAAAthird three@example.com", "ssh-ed25519 AAAAfirst one@example.com"]'
	load_cluster
	render_install_config "${BATS_TEST_TMPDIR}/ic.yaml"
	assert_equal "$(yq -r '.sshKey' "${BATS_TEST_TMPDIR}/ic.yaml")" "ssh-ed25519 AAAAfirst one@example.com"
	manifests_render "${BATS_TEST_TMPDIR}/out"
	local f=${BATS_TEST_TMPDIR}/out/99-worker-okd-pve-ssh.yaml
	assert_equal "$(yq -r '.metadata.labels."machineconfiguration.openshift.io/role"' "${f}")" worker
	assert_equal "$(yq -r '.spec.config.passwd.users[0].sshAuthorizedKeys | join(",")' "${f}")" \
		"ssh-ed25519 AAAAsecond two@example.com,ssh-ed25519 AAAAthird three@example.com"
	assert [ -f "${BATS_TEST_TMPDIR}/out/99-master-okd-pve-ssh.yaml" ]
}

@test "a single SSH key renders no extra MachineConfig" {
	command -v butane >/dev/null || skip "butane not installed"
	BUTANE=$(command -v butane)
	manifests_render "${BATS_TEST_TMPDIR}/out"
	assert [ ! -e "${BATS_TEST_TMPDIR}/out/99-worker-okd-pve-ssh.yaml" ]
}

# A fake oc for installer_recover_hosts: nodes are missing unless listed in
# FAKE_READY, the controller log shows HOSTS_STATUS, CSR calls are served from
# FAKE_CSRS and approvals logged. RV_* is the rendezvous node, W_* a worker.
_recover_fakes() {
	mkdir -p "${AUTH_DIR}" "${STATE_DIR}" "${BATS_TEST_TMPDIR}/bin"
	echo "apiVersion: v1" >"${KUBECONFIG_FILE}"
	OC=${BATS_TEST_TMPDIR}/bin/oc
	export OC_LOG=${BATS_TEST_TMPDIR}/oc.log PVE_LOG=${BATS_TEST_TMPDIR}/pve.log
	IFS=$'\t' read -r RV_NAME RV_VMID < <(nodes_query --arg ip "$(cfg '.network.rendezvous_ip')" \
		'.[] | select(.ip == $ip) | [.name, .vmid] | @tsv')
	W_NAME=small-worker-0
	W_VMID=$(nodes_query --arg n "${W_NAME}" '.[] | select(.name == $n) | .vmid')
	export RV_VMID W_VMID
	export HOSTS_STATUS="time=\"2026-11-02T11:25:20Z\" level=info msg=\"Hosts status: map[${RV_NAME}:[error Waiting for controller waiting for controller pod ready event] small-master-1:[installed Done ] ${W_NAME}:[installed Done ]]\""
	cat >"${OC}" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"${OC_LOG}"
case "$*" in
"get node "*" -o jsonpath="*) [[ " ${FAKE_READY:-} " == *" $3 "* ]] && echo True || exit 1 ;;
"get node "*) [[ " ${FAKE_READY:-} " == *" $3 "* ]] || exit 1 ;;
"-n assisted-installer logs "*) printf 'time="x" level=info msg="Hosts status: map[old]"\n%s\nlevel=info msg="ConfigMap not found yet"\n' "${HOSTS_STATUS}" ;;
"get csr -o json") cat "${FAKE_CSRS:-/dev/null}" ;;
"adm certificate approve "*) ;;
*) exit 1 ;;
esac
SH
	chmod +x "${OC}"
	pve_api() {
		echo "$*" >>"${PVE_LOG}"
		case $1 in
		/cluster/resources*)
			printf '[{"vmid":%s,"node":"pve2","status":"%s"},{"vmid":%s,"node":"pve1","status":"running"}]\n' \
				"${RV_VMID}" "${FAKE_VM_STATUS:-running}" "${W_VMID}"
			;;
		*/status/reset) echo '"UPID:pve2:reset"' ;;
		esac
	}
}

# _csrs <name>...: pending client CSRs (real ones from test/fixtures/csr).
_csrs() {
	local n i=0
	export FAKE_CSRS=${BATS_TEST_TMPDIR}/csrs.json
	for n in "$@"; do
		jq -n --arg name "csr-$((i++))" --arg r "$(base64 -w0 <"${OKD_PVE_ROOT}/test/fixtures/csr/${n}.pem")" \
			'{metadata: {name: $name}, spec: {username: "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper", signerName: "kubernetes.io/kube-apiserver-client-kubelet", request: $r}, status: {}}'
	done | jq -s '{items: .}' >"${FAKE_CSRS}"
}

@test "host recovery: a rendezvous node stuck in the live ISO is reset once, then its CSRs are approved" {
	_recover_fakes
	run installer_recover_hosts
	assert_success
	assert_output "recovery: the agent installer gave up on rendezvous node ${RV_NAME} (\"Waiting for controller\" timed out), so it stayed in the live ISO; reset VM ${RV_VMID} to boot it from its installed disk, its CSRs are approved when it joins"
	run grep -c "/nodes/pve2/qemu/${RV_VMID}/status/reset --data" "${PVE_LOG}"
	assert_output 1
	assert [ -f "${STATE_DIR}/recovered-${RV_NAME}" ]
	# Next round: no second reset; the client CSR of this node is approved,
	# the one of another node is not.
	_csrs "${RV_NAME}" intruder
	run installer_recover_hosts
	assert_success
	assert_output "Approved CSR csr-0 for ${RV_NAME}"
	run grep -c 'status/reset' "${PVE_LOG}"
	assert_output 1
	run grep -c 'adm certificate approve' "${OC_LOG}"
	assert_output 1
	# Once the node is Ready, nothing is left to do.
	export FAKE_READY=${RV_NAME}
	: >"${OC_LOG}"
	run installer_recover_hosts
	assert_output ""
	run grep -c 'csr' "${OC_LOG}"
	assert_output 0
}

@test "host recovery: a worker that timed out waiting for the control plane is reset" {
	_recover_fakes
	export FAKE_READY=${RV_NAME}
	export HOSTS_STATUS="msg=\"Hosts status: map[${RV_NAME}:[installed Done ] ${W_NAME}:[error Waiting for control plane ] small-worker-1:[installed Done ]]\""
	run installer_recover_hosts
	assert_success
	assert_output "recovery: the agent installer gave up on ${W_NAME} (\"Waiting for control plane\" timed out), so it stayed in the live ISO; reset VM ${W_VMID} to boot it from its installed disk, its CSRs are approved when it joins"
	run grep -c 'status/reset' "${PVE_LOG}"
	assert_output 1
	run grep -c "/nodes/pve1/qemu/${W_VMID}/status/reset --data" "${PVE_LOG}"
	assert_output 1
	assert [ -f "${STATE_DIR}/recovered-${W_NAME}" ]
	assert [ ! -e "${STATE_DIR}/recovered-${RV_NAME}" ]
}

@test "host recovery: the rendezvous node is left alone while it is the bootstrap node" {
	_recover_fakes
	export HOSTS_STATUS="msg=\"Hosts status: map[${RV_NAME}:[error Waiting for control plane waiting for bootstrap to prepare]]\""
	run installer_recover_hosts
	assert_success
	assert_output ""
	assert [ ! -e "${PVE_LOG}" ]
}

@test "host recovery: nothing happens while hosts are still installing or have joined" {
	_recover_fakes
	export HOSTS_STATUS="msg=\"Hosts status: map[${RV_NAME}:[installing-in-progress Waiting for controller waiting for controller pod ready event] ${W_NAME}:[error Waiting for control plane ]]\""
	export FAKE_READY=${W_NAME}
	run installer_recover_hosts
	assert_success
	assert_output ""
	assert [ ! -e "${PVE_LOG}" ]
	run ls "${STATE_DIR}"
	refute_output --partial recovered-
}

@test "host recovery: a stopped VM is reported, not reset" {
	_recover_fakes
	export FAKE_VM_STATUS=stopped
	run installer_recover_hosts
	assert_output --partial "VM ${RV_VMID} is not running (stopped); start it in Proxmox"
	run grep -c 'status/reset' "${PVE_LOG}"
	assert_output 0
}

@test "host recovery: install.recover_stuck_hosts false turns it off" {
	yq_set '.install.recover_stuck_hosts = false'
	load_cluster
	_recover_fakes
	run installer_recover_hosts
	assert_success
	assert_output ""
	assert [ ! -e "${OC_LOG}" ]
}

@test "host recovery: the 0.1.2 setting install.recover_rendezvous false still turns it off" {
	yq_set '.install.recover_rendezvous = false'
	load_cluster
	_recover_fakes
	run installer_recover_hosts
	assert_success
	assert [ ! -e "${OC_LOG}" ]
}

# fake_live_iso <file>: binary data with two karg embed areas like a CoreOS
# live ISO (EFI grub.cfg, isolinux.cfg); a hole makes the file sparse.
fake_live_iso() {
	local f=$1 pad
	pad=$(printf '%*s' 200 '' | tr ' ' '#')
	{
		head -c 4096 /dev/urandom
		printf '\tlinux /images/pxeboot/vmlinuz rw  coreos.liveiso=x ignition.firstboot\n%s# COREOS_KARG_EMBED_AREA\n' "${pad}"
		head -c 4096 /dev/zero
		printf '  append initrd=/images/pxeboot/initrd.img rw  coreos.liveiso=x ignition.firstboot\n%s# COREOS_KARG_EMBED_AREA\n' "${pad}"
	} >"${f}"
	truncate -s +1M "${f}"
	head -c 4096 /dev/urandom >>"${f}"
}

@test "iso_append_karg writes the argument into every embed area without changing the size" {
	local iso=${BATS_TEST_TMPDIR}/live.iso size
	fake_live_iso "${iso}"
	size=$(wc -c <"${iso}")
	run iso_append_karg "${iso}" systemd.debug_shell
	assert_success
	assert_equal "$(wc -c <"${iso}")" "${size}"
	run grep -ac 'ignition.firstboot systemd.debug_shell$' "${iso}"
	assert_output 2
	# the padding shrinks by the argument and the marker stays in place
	run grep -ac "^$(printf '%*s' 180 '' | tr ' ' '#')# COREOS_KARG_EMBED_AREA$" "${iso}"
	assert_output 2
	# a second run changes nothing
	local sum
	sum=$(sha256sum "${iso}")
	run iso_append_karg "${iso}" systemd.debug_shell
	assert_success
	assert_equal "$(sha256sum "${iso}")" "${sum}"
}

@test "iso_append_karg refuses a file without embed area" {
	head -c 8192 /dev/urandom >"${BATS_TEST_TMPDIR}/plain.iso"
	run iso_append_karg "${BATS_TEST_TMPDIR}/plain.iso" systemd.debug_shell
	assert_failure
	assert_output --partial "has no kernel argument area"
}

@test "install.debug_shell: off by default, changes the inputs hash only when on" {
	local iso=${BATS_TEST_TMPDIR}/live.iso h1 h2
	fake_live_iso "${iso}"
	mkdir -p "${BATS_TEST_TMPDIR}/stage"
	echo x >"${BATS_TEST_TMPDIR}/stage/f"
	h1=$(installer_inputs_hash "${BATS_TEST_TMPDIR}/stage")
	run installer_iso_debug_shell "${iso}"
	assert_success
	refute_output
	run grep -ac systemd.debug_shell "${iso}"
	assert_output 0
	yq_set '.install.debug_shell = true'
	load_cluster
	h2=$(installer_inputs_hash "${BATS_TEST_TMPDIR}/stage")
	assert [ "${h1}" != "${h2}" ]
	run installer_iso_debug_shell "${iso}"
	assert_success
	assert_output --partial "root shell without password on tty9"
	run grep -ac systemd.debug_shell "${iso}"
	assert_output 2
}

# _agent_fakes: a fake curl for the agent service and the Machine Config
# Server; it logs its arguments so the test can check the token is not there.
_agent_fakes() {
	mkdir -p "${GENERATED_DIR}" "${BATS_TEST_TMPDIR}/bin"
	echo '{"*gencrypto.AuthConfig": {"UserAuthToken": "secret-agent-token"}}' >"${GENERATED_DIR}/.openshift_install_state.json"
	export CURL_ARGS=${BATS_TEST_TMPDIR}/curl-args MCS_CODE=${MCS_CODE:-000}
	cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "$*" >>"${CURL_ARGS}"
[[ " $* " == *" -K - "* ]] && cat >/dev/null
case "$*" in
*:22623/healthz*) printf '%s' "${MCS_CODE}" ;;
*/v2/clusters/c1*)
	cat <<'JSON'
{"status": "installing-pending-user-action", "hosts": [
 {"requested_hostname": "small-master-0", "status": "installing-in-progress", "progress": {"current_stage": "Waiting for control plane"}},
 {"requested_hostname": "small-master-1", "status": "installing-pending-user-action", "status_info": "Host timed out when pulling the configuration files.", "progress": {"current_stage": "Rebooting"}},
 {"requested_hostname": "small-worker-0", "status": "installing-in-progress", "progress": {"current_stage": "Waiting for control plane"}}]}
JSON
	;;
*/v2/clusters*) echo '[{"id": "c1"}]' ;;
esac
CURL
	chmod +x "${BATS_TEST_TMPDIR}/bin/curl"
	export PATH=${BATS_TEST_TMPDIR}/bin:${PATH}
}

@test "installer_agent_status shows the agent's host stages and hosts that need attention" {
	_agent_fakes
	run installer_agent_status
	assert_success
	assert_line "agent: installing-pending-user-action · 1 Rebooting, 2 Waiting for control plane"
	assert_line "agent: small-master-1 installing-pending-user-action: Host timed out when pulling the configuration files."
	refute grep -q secret-agent-token "${CURL_ARGS}"
}

@test "installer_mcs_check reports a Machine Config Server that does not answer while masters are missing" {
	_agent_fakes
	local nodes='{"items": [{"metadata": {"name": "small-master-0", "labels": {"node-role.kubernetes.io/master": ""}},
		"status": {"conditions": [{"type": "Ready", "status": "True"}]}}]}'
	run installer_mcs_check "${nodes}"
	refute_output
	run installer_mcs_check "${nodes}"
	refute_output
	run installer_mcs_check "${nodes}"
	assert_output --partial "Machine Config Server https://192.0.2.5:22623 does not answer (1 of 3 masters Ready)"
	# an answer resets the count
	MCS_CODE=200 run installer_mcs_check "${nodes}"
	refute_output
	run installer_mcs_check "${nodes}"
	refute_output
}

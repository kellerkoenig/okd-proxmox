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

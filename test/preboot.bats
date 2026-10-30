#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Pre-Boot manifest rendering (lib/manifests.sh, templates/preboot).

setup() {
	load test_helper
	load_libs
	command -v butane >/dev/null || skip "butane not installed"
	BUTANE=$(command -v butane)
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	load_cluster
	OUT=${BATS_TEST_TMPDIR}/out
}

# mc_file <name>: decoded content of the first storage file of a MachineConfig.
mc_file() {
	local src compression
	src=$(yq -r '.spec.config.storage.files[0].contents.source' "${OUT}/$1")
	compression=$(yq -r '.spec.config.storage.files[0].contents.compression // ""' "${OUT}/$1")
	if [[ ${src} == data:\;base64,* ]]; then
		if [[ ${compression} == gzip ]]; then
			base64 -d <<<"${src#data:;base64,}" | gunzip
		else
			base64 -d <<<"${src#data:;base64,}"
		fi
	else
		python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "${src#data:,}"
	fi
}

@test "render_template indents block values and refuses unknown placeholders" {
	printf 'a: {{X}}\nlist:\n  {{LINES}}\n' >"${BATS_TEST_TMPDIR}/t.tpl"
	TPL=([X]=1 [LINES]=$'- one\n- two')
	run render_template "${BATS_TEST_TMPDIR}/t.tpl"
	assert_success
	assert_output $'a: 1\nlist:\n  - one\n  - two'
	TPL=([X]=1)
	run render_template "${BATS_TEST_TMPDIR}/t.tpl"
	assert_failure
	assert_output --partial "no value for {{LINES}}"
}

@test "combined cluster: chrony, kubelet and kernel args for master and worker, no infra pool" {
	manifests_render "${OUT}"
	run ls "${OUT}"
	assert_output $'99-master-okd-pve-chrony.yaml\n99-master-okd-pve-kargs.yaml\n99-okd-pve-kubelet-master.yaml\n99-okd-pve-kubelet-worker.yaml\n99-worker-okd-pve-chrony.yaml\n99-worker-okd-pve-kargs.yaml'
}

@test "chrony config contains the NTP servers, makestep, rtcsync and driftfile" {
	manifests_render "${OUT}"
	assert_equal "$(yq -r '.metadata.labels."machineconfiguration.openshift.io/role"' "${OUT}/99-master-okd-pve-chrony.yaml")" master
	run mc_file 99-worker-okd-pve-chrony.yaml
	assert_output --partial "server 192.0.2.123 iburst"
	assert_output --partial "server 192.0.2.125 iburst"
	assert_output --partial "makestep 1.0 3"
	assert_output --partial "rtcsync"
	assert_output --partial "driftfile /var/lib/chrony/drift"
}

@test "KubeletConfig is rendered for both pools with values from cluster.yaml" {
	yq_set '.kubelet.image_gc_high_threshold_percent = 75'
	load_cluster
	manifests_render "${OUT}"
	local f
	for pool in master worker; do
		f=${OUT}/99-okd-pve-kubelet-${pool}.yaml
		assert_equal "$(yq -r '.spec.machineConfigPoolSelector.matchLabels | keys | .[0]' "${f}")" "pools.operator.machineconfiguration.openshift.io/${pool}"
		assert_equal "$(yq -r '.spec.kubeletConfig.imageGCHighThresholdPercent' "${f}")" 75
		assert_equal "$(yq -r '.spec.autoSizingReserved' "${f}")" true
		assert_equal "$(yq -r '.spec.kubeletConfig.evictionHard."memory.available"' "${f}")" 500Mi
		# every soft threshold needs a grace period
		assert_equal "$(yq -r '.spec.kubeletConfig.evictionSoft | keys | sort | join(",")' "${f}")" \
			"$(yq -r '.spec.kubeletConfig.evictionSoftGracePeriod | keys | sort | join(",")' "${f}")"
	done
}

@test "no hard-coded numbers: GC disabled for one pool via kubelet.pools" {
	yq_set '.kubelet.pools = ["worker"]'
	load_cluster
	manifests_render "${OUT}"
	assert [ ! -e "${OUT}/99-okd-pve-kubelet-master.yaml" ]
	yq_set '.kubelet.pools = ["master", "infra"]'
	load_cluster
	run manifests_render "${BATS_TEST_TMPDIR}/out2"
	assert_failure
	assert_output --partial "'infra' is not supported"
}

@test "dedicated infra: MachineConfigPool and infra overrides" {
	make_cluster large
	yq_set '.preboot.chrony_overrides.infra = ["198.51.100.200", "198.51.100.201", "198.51.100.202"] | .preboot.kernel_args.infra = ["foo=bar"]'
	cp "${OKD_PVE_ROOT}/test/fixtures/ca.pem" "${CLUSTER}/internal-ca.pem"
	load_cluster
	manifests_render "${OUT}"
	assert [ -f "${OUT}/99-okd-pve-infra-machineconfigpool.yaml" ]
	assert_equal "$(yq -r '.spec.nodeSelector.matchLabels | keys | .[0]' "${OUT}/99-okd-pve-infra-machineconfigpool.yaml")" node-role.kubernetes.io/infra
	assert [ -f "${OUT}/99-zz-infra-okd-pve-chrony.yaml" ]
	run mc_file 99-zz-infra-okd-pve-chrony.yaml
	assert_output --partial "server 198.51.100.200 iburst"
	assert_equal "$(yq -r '.spec.kernelArguments[0]' "${OUT}/99-infra-okd-pve-kargs.yaml")" foo=bar
	run mc_file 99-worker-okd-pve-ca.yaml
	assert_output --partial "BEGIN CERTIFICATE"
}

@test "user Pre-Boot directory: YAML copied, Butane rendered, invalid files fail" {
	mkdir -p "${CLUSTER}/preboot"
	cat >"${CLUSTER}/preboot/50-custom.yaml" <<'YAML'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 50-custom
  labels:
    machineconfiguration.openshift.io/role: worker
spec: {}
YAML
	cat >"${CLUSTER}/preboot/60-motd.bu" <<'YAML'
variant: openshift
version: 4.17.0
metadata:
  name: 60-motd
  labels:
    machineconfiguration.openshift.io/role: worker
storage:
  files:
    - path: /etc/motd.d/okd
      contents:
        inline: hello
YAML
	manifests_render "${OUT}"
	assert [ -f "${OUT}/50-custom.yaml" ]
	assert_equal "$(yq -r '.kind' "${OUT}/60-motd.yaml")" MachineConfig
	printf 'kind: MachineConfig\nmetadata: {name: x}\n' >"${CLUSTER}/preboot/70-broken.yaml"
	run manifests_render "${BATS_TEST_TMPDIR}/out3"
	assert_failure
	assert_output --partial "70-broken.yaml: apiVersion, kind and metadata.name are required"
}

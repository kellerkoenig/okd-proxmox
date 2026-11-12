#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Configuration loading and validation (lib/config.sh, lib/jq/validate.jq).

setup() {
	load test_helper
	load_libs
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
}

@test "both examples load and validate without errors" {
	load_cluster
	run config_validate
	assert_success
	assert_equal "${CLUSTER_NAME}" small
	assert_equal "${BASE_DOMAIN}" example.com
	make_cluster large
	load_cluster
	run config_validate
	assert_success
}

@test "defaults are merged under cluster.yaml" {
	load_cluster
	assert_equal "$(cfg '.proxmox.bios')" ovmf
	assert_equal "$(cfg '.infra.taint_value')" reserved
	assert_equal "$(cfg '.proxmox.mac_prefix')" "02:00:41"
	# maps merge key by key: a partial eviction_hard keeps the other keys
	yq_set '.kubelet.eviction_hard."memory.available" = "1Gi"'
	load_cluster
	assert_equal "$(cfg '.kubelet.eviction_hard."memory.available"')" 1Gi
	assert_equal "$(cfg '.kubelet.eviction_hard."nodefs.available"')" "10%"
}

@test "cfg returns false booleans" {
	yq_set '.proxmox.spread = false'
	load_cluster
	assert_equal "$(cfg '.proxmox.spread')" false
}

@test "two masters are rejected" {
	yq_set '(.node_groups[] | select(.name == "master") | .count) = 2'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "must have 1 or 3 nodes"
}

@test "unknown roles and master combined with other roles are rejected" {
	yq_set '(.node_groups[] | select(.name == "worker") | .roles) = ["worker", "storage"]'
	yq_set '(.node_groups[] | select(.name == "master") | .roles) = ["master", "infra"]'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "unknown role(s) storage"
	assert_output --partial "master role cannot be combined"
}

@test "combined worker/infra with taint warns but validates" {
	yq_set '(.node_groups[] | select(.name == "worker") | .taint_infra) = true'
	load_cluster
	run config_validate
	assert_success
	assert_output --partial "effectively dedicated infra nodes"
}

@test "combined worker/infra with little RAM warns" {
	yq_set '(.node_groups[] | select(.name == "worker") | .memory_gib) = 32'
	load_cluster
	run config_validate
	assert_success
	assert_output --partial "OOM killer"
}

@test "too few IPs and a multicast MAC prefix are rejected" {
	yq_set '(.node_groups[] | select(.name == "master") | .ips) = ["192.0.2.11", "192.0.2.12"]'
	yq_set '.proxmox.mac_prefix = "03:00:00"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "3 nodes but only 2 IP addresses"
	assert_output --partial "multicast"
}

@test "VMIDs outside the range are rejected" {
	yq_set '.proxmox.vmid_end = 4110'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "VMID 4120 is outside proxmox.vmid_start..vmid_end"
}

@test "rendezvous IP must belong to a control-plane node" {
	yq_set '.network.rendezvous_ip = "192.0.2.21"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "must be the IP of a control-plane node"
}

@test "proxmox.spread must be true, false or balanced" {
	yq_set '.proxmox.spread = "even"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "proxmox.spread must be true, false or balanced"
}

@test "proxmox.tmp_dir and cache_dir become TMPDIR and XDG_CACHE_HOME" {
	CACHE=${BATS_TEST_TMPDIR}/cache yq_set '.proxmox.tmp_dir = ".tmp" | .proxmox.cache_dir = strenv(CACHE)'
	# a temporary directory okd-pve created itself moves into tmp_dir
	OKD_PVE_TMP=$(mktemp -d "${BATS_TEST_TMPDIR}/okd-pve.XXXXXX")
	local old=${OKD_PVE_TMP}
	echo kept >"${OKD_PVE_TMP}/early"
	load_cluster
	assert_equal "${TMPDIR}" "${CLUSTER}/.tmp"
	assert_equal "${XDG_CACHE_HOME}" "${BATS_TEST_TMPDIR}/cache"
	assert [ -d "${BATS_TEST_TMPDIR}/cache" ]
	assert_equal "${OKD_PVE_TMP%/okd-pve.*}" "${CLUSTER}/.tmp"
	assert_equal "$(cat "${OKD_PVE_TMP}/early")" kept
	assert [ ! -e "${old}" ]
	assert [ -f "${CONFIG_JSON}" ]
	assert_equal "${CONFIG_JSON%/config.json}" "${OKD_PVE_TMP}"
}

@test "proxmox.tmp_dir and cache_dir must be paths" {
	yq_set '.proxmox.cache_dir = 5'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "proxmox.cache_dir must be a directory path"
}

@test "proxmox.guest_agent must be a boolean" {
	yq_set '.proxmox.guest_agent = "yes"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "proxmox.guest_agent must be true or false"
}

@test "node IPs outside machineNetwork are rejected" {
	yq_set '.networking.machineNetwork[0].cidr = "198.51.100.0/24"' "${CLUSTER}/install-config.yaml"
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "is not inside networking.machineNetwork"
}

@test "OKD below 4.17 is rejected" {
	yq_set '.okd.version = "4.16.0-okd-scos.0"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "minimum is 4.17"
}

@test "deprecated singular VIPs and wrong replicas are reported" {
	yq_set '.platform.baremetal.apiVIP = "192.0.2.5" | .controlPlane.replicas = 1' "${CLUSTER}/install-config.yaml"
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "deprecated apiVIP"
	assert_output --partial "controlPlane.replicas (1) does not match"
}

@test "single node needs platform none" {
	yq_set '(.node_groups[] | select(.name == "master") | .count) = 1 | (.node_groups[] | select(.name == "worker") | .count) = 0'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "single-node cluster needs 'platform: {none: {}}'"
	yq_set '.platform = {"none": {}}' "${CLUSTER}/install-config.yaml"
	load_cluster
	run config_validate
	assert_success
}

@test "invalid YAML is a configuration error" {
	echo "node_groups: [" >>"${CLUSTER}/cluster.yaml"
	run config_load
	assert_failure 2
	assert_output --partial "Cannot parse"
}

@test "proxmox.conf readable by others is refused" {
	write_proxmox_conf 644
	run proxmox_conf_load
	assert_failure 2
	assert_output --partial "accessible by group/others"
}

@test "proxmox.conf is loaded and environment variables win" {
	write_proxmox_conf 600
	export PROXMOX_VE_ENDPOINT=https://other.example.com:8006/
	proxmox_conf_load
	assert_equal "${PROXMOX_VE_ENDPOINT}" https://other.example.com:8006/
	assert_equal "${PROXMOX_VE_API_TOKEN}" "${TEST_TOKEN}"
	run redact_string "${TEST_TOKEN_SECRET}"
	assert_output '***REDACTED***'
}

@test "a malformed token is rejected without printing it" {
	export PROXMOX_VE_ENDPOINT=https://pve.example.com:8006/
	export PROXMOX_VE_API_TOKEN="not-a-valid-token-value"
	run proxmox_conf_load
	assert_failure 2
	assert_output --partial "wrong format"
	refute_output --partial "not-a-valid-token-value"
}

@test "pull secret: file is used, placeholder otherwise" {
	load_cluster
	run pull_secret_value
	assert_output "${OKD_FAKE_PULL_SECRET}"
	echo '{"auths":{"registry.example.com":{"auth":"dXNlcjpzZWNyZXRwYXNz"}}}' >"${CLUSTER}/pull-secret.json"
	run pull_secret_source
	assert_output "${CLUSTER}/pull-secret.json"
	register_pull_secret
	run redact_string "auth dXNlcjpzZWNyZXRwYXNz"
	assert_output "auth ***REDACTED***"
}

@test "resolve_cluster_dir finds the only cluster under ./clusters" {
	mkdir -p "${BATS_TEST_TMPDIR}/work/clusters"
	cp -r "${CLUSTER}" "${BATS_TEST_TMPDIR}/work/clusters/small"
	cd "${BATS_TEST_TMPDIR}/work"
	CONFIG_FILE=''
	resolve_cluster_dir ''
	assert_equal "${CLUSTER_DIR}" "${BATS_TEST_TMPDIR}/work/clusters/small"
	cp -r "${CLUSTER}" "${BATS_TEST_TMPDIR}/work/clusters/second"
	run resolve_cluster_dir ''
	assert_failure 2
	assert_output --partial "Several clusters"
}

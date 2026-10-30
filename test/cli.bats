#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# End-to-end CLI behaviour of okd-pve (mocked Proxmox API, no cluster).

setup() {
	load test_helper
	OKD=${OKD_PVE_ROOT}/okd-pve
	export NO_COLOR=1
	use_mocks
	cd "${BATS_TEST_TMPDIR}"
}

@test "version and help" {
	run "${OKD}" version
	assert_success
	assert_output --partial "okd-pve "
	assert_output --partial "minimum OKD:      4.17"
	run "${OKD}"
	assert_success
	assert_output --partial "Usage: okd-pve"
	run "${OKD}" --help
	assert_success
}

@test "unknown command and missing subcommand are configuration errors" {
	run "${OKD}" frobnicate
	assert_failure 2
	run "${OKD}" node
	assert_failure 2
}

@test "init creates a commented skeleton with a private proxmox.conf" {
	run "${OKD}" init demo
	assert_success
	assert [ -f clusters/demo/cluster.yaml ]
	assert [ -f clusters/demo/install-config.yaml ]
	assert [ -f clusters/demo/preboot/README.md ]
	assert_equal "$(stat -c %a clusters/demo/proxmox.conf)" 600
	assert_equal "$(yq -r '.metadata.name' clusters/demo/install-config.yaml)" demo
	run "${OKD}" init demo
	assert_failure 2
	assert_output --partial "refusing to overwrite"
}

@test "init --dry-run creates nothing" {
	run "${OKD}" --dry-run init demo
	assert_success
	assert_output --partial "[dry-run] would create ./clusters/demo/cluster.yaml"
	assert [ ! -e clusters/demo ]
}

@test "init rejects invalid cluster names" {
	run "${OKD}" init Bad_Name
	assert_failure 2
}

@test "commands find the only cluster in ./clusters and write a log file" {
	"${OKD}" init demo >/dev/null
	run "${OKD}" node list
	assert_success
	assert_output --partial "demo-master-0"
	assert [ -L clusters/demo/logs/latest.log ]
	assert_equal "$(stat -c %a clusters/demo/logs)" 700
}

@test "tui: runs a command and returns to the menu, also on a terminal without clear" {
	"${OKD}" init demo >/dev/null
	mkdir -p clusters/demo/logs fake-bin
	echo "line from create" >clusters/demo/logs/okd-pve-create-20260101-100000.log
	# Fake whiptail: one answer per call from answers.txt (selections go to stderr).
	cat >fake-bin/whiptail <<'SH'
#!/usr/bin/env bash
echo "$*" >>whiptail.log
a=$(head -n 1 answers.txt) && sed -i 1d answers.txt
case "$*" in
*--yesno*) [[ ${a} == yes ]] ;;
*) printf '%s' "${a}" >&2 ;;
esac
SH
	chmod +x fake-bin/whiptail
	printf '%s\n' ./clusters/demo logs quit >answers.txt
	PATH=${PWD}/fake-bin:${PATH} TERM=dumb run "${OKD}" tui <<<$'\n'
	assert_success
	assert_output --partial "--dir ./clusters/demo logs"
	assert_output --partial "line from create"
	assert_output --partial "[exit code 0] Press Enter to return to the menu."
	assert_equal "$(grep -c 'Choose an action' whiptail.log)" 2
}

@test "logs -f moves on to the log of a later run; latest.log never points to 'logs' itself" {
	"${OKD}" init demo >/dev/null
	local d=clusters/demo/logs
	mkdir -p "${d}"
	echo "first run" >"${d}/okd-pve-create-20260101-100000.log"
	ln -sfn okd-pve-create-20260101-100000.log "${d}/latest.log"
	# 3>&-: background processes must not hold bats' output descriptor.
	"${OKD}" logs -f >"${BATS_TEST_TMPDIR}/follow.txt" 2>&1 3>&- &
	local pid=$!
	sleep 3
	echo "second run" >"${d}/okd-pve-create-20260101-110000.log"
	sleep 5
	kill -TERM "${pid}"
	local rc=0
	wait "${pid}" || rc=$?
	assert_equal "${rc}" 0
	sleep 1
	run pgrep -f "tail -n .* -f ${PWD}/${d}/"
	assert_failure
	run cat "${BATS_TEST_TMPDIR}/follow.txt"
	assert_line "first run"
	assert_line "==> ${PWD}/${d}/okd-pve-create-20260101-110000.log"
	assert_line "second run"
	refute_output --partial "ERROR"
	assert_equal "$(readlink "${d}/latest.log")" okd-pve-create-20260101-100000.log
}

@test "a configuration error exits with 2" {
	"${OKD}" init demo >/dev/null
	yq -i '(.node_groups[] | select(.name == "master") | .count) = 2' clusters/demo/cluster.yaml
	run "${OKD}" node list
	assert_failure 2
}

@test "a too open proxmox.conf exits with 2" {
	"${OKD}" init demo >/dev/null
	chmod 644 clusters/demo/proxmox.conf
	run "${OKD}" node list
	assert_failure 2
	assert_output --partial "chmod 600"
}

@test "preflight exits with 3 on failures" {
	"${OKD}" init demo >/dev/null
	sed -i "s|^PROXMOX_VE_API_TOKEN=.*|PROXMOX_VE_API_TOKEN=\"${TEST_TOKEN}\"|" clusters/demo/proxmox.conf
	yq -i '.proxmox.pool = "okd-small"' clusters/demo/cluster.yaml
	run "${OKD}" preflight
	assert_failure 3
	assert_output --partial "Preflight:"
}

@test "--debug never leaks the API token to the terminal or the log file" {
	"${OKD}" init demo >/dev/null
	sed -i "s|^PROXMOX_VE_API_TOKEN=.*|PROXMOX_VE_API_TOKEN=\"${TEST_TOKEN}\"|" clusters/demo/proxmox.conf
	yq -i '.proxmox.pool = "okd-small"' clusters/demo/cluster.yaml
	run "${OKD}" --debug preflight
	refute_output --partial "${TEST_TOKEN_SECRET}"
	refute_output --partial "${TEST_TOKEN}"
	local log
	log=$(readlink -f clusters/demo/logs/latest.log)
	run grep -c "${TEST_TOKEN_SECRET}" "${log}"
	assert_output 0
	# The shell trace is in the log, with the token masked.
	run grep -c 'PVEAPIToken=\*\*\*REDACTED\*\*\*' "${log}"
	refute_output 0
}

@test "the token from the environment wins and is masked as well" {
	"${OKD}" init demo >/dev/null
	rm clusters/demo/proxmox.conf
	export PROXMOX_VE_ENDPOINT=https://pve.example.com:8006/ PROXMOX_VE_API_TOKEN=${TEST_TOKEN}
	export MOCK_PVE_FAIL=1
	run "${OKD}" --debug preflight
	assert_failure 3
	refute_output --partial "${TEST_TOKEN_SECRET}"
	run grep -c "${TEST_TOKEN_SECRET}" "$(readlink -f clusters/demo/logs/latest.log)"
	assert_output 0
}

@test "destroy without --yes in a non-interactive shell refuses" {
	"${OKD}" init demo >/dev/null
	sed -i "s|^PROXMOX_VE_API_TOKEN=.*|PROXMOX_VE_API_TOKEN=\"${TEST_TOKEN}\"|" clusters/demo/proxmox.conf
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	printf '#!/bin/sh\necho '\''{"terraform_version":"1.13.2"}'\''\n' >"${BATS_TEST_TMPDIR}/bin/tofu"
	chmod +x "${BATS_TEST_TMPDIR}/bin/tofu"
	PATH=${BATS_TEST_TMPDIR}/bin:${PATH} run "${OKD}" destroy </dev/null
	assert_failure 1
	assert_output --partial "destroy needs confirmation"
}

@test "a missing nmstatectl is extracted with podman into <cluster>/bin" {
	"${OKD}" init demo >/dev/null
	# hide a system nmstatectl so the extraction path is used
	run bash -c "source '${OKD_PVE_ROOT}/okd-pve'; set +eu
		command() { [[ \$1 == -v && \$2 == nmstatectl ]] && return 1; builtin command \"\$@\"; }
		ASSUME_YES=1; NO_COLOR=1; setup_tmp
		resolve_cluster_dir clusters/demo; config_load; tools_path
		mkdir -p \"\${BIN_DIR}\"; _download_nmstatectl && tool_check nmstatectl"
	assert_success
	assert_output --partial "clusters/demo/bin/nmstatectl	2.2.62"
	run grep -c 'podman run --rm -v .*quay.io/centos/centos:stream9' "${MOCK_LOG}"
	assert_output 1
}

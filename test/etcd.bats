#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# etcd backups and restore (lib/etcd.sh, hook 56-etcd-backup).

setup() {
	load test_helper
	load_libs
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	load_cluster
	CALLS=${BATS_TEST_TMPDIR}/calls
	: >"${CALLS}"
	export CALLS
	VERSION=4.21.0-okd-scos.11
}

# backup <name> [version]: a complete local backup.
backup() {
	local d
	d=$(etcd_local_dir)/$1
	mkdir -p "${d}"
	touch "${d}/snapshot_x.db" "${d}/static_kuberesources_x.tar.gz"
	[[ -n ${2:-} ]] && echo "$2" >"${d}/version"
	return 0
}

# A cluster whose API answers and whose control plane nodes answer SSH.
fake_cluster() {
	_etcd_api_up() { return 0; }
	_etcd_api_serving() { return 0; }
	oc() {
		echo "oc $*" >>"${CALLS}"
		case "$*" in
		"get clusterversion version -o jsonpath={.status.desired.version}") echo "${VERSION}" ;;
		"get csr -o json") echo '{"items": []}' ;;
		"-n openshift-etcd get pods -l app=etcd -o json --request-timeout=20s")
			jq -n '{items: [range(3) | {spec: {containers: [{name: "etcd"}, {name: "etcdctl"}]},
				status: {phase: "Running", containerStatuses: [{ready: true}, {ready: true}]}}]}'
			;;
		esac
		return 0
	}
	etcd_ssh() {
		[[ $2 == true ]] && return 0
		echo "ssh $1 $2" >>"${CALLS}"
	}
	scp() { echo "scp ${*: -1}" >>"${CALLS}"; }
	ASSUME_YES=1
}

@test "a backup directory needs the snapshot and the static pod resources" {
	local d=${BATS_TEST_TMPDIR}/b
	mkdir -p "${d}"
	touch "${d}/snapshot_2026-11-21_021500.db"
	run etcd_backup_valid "${d}"
	assert_failure
	touch "${d}/static_kuberesources_2026-11-21_021500.tar.gz"
	run etcd_backup_valid "${d}"
	assert_success
}

@test "local copies are listed oldest first, incomplete ones are left out" {
	backup 2026-11-21_021500_4.21.0-okd-scos.11 4.21.0-okd-scos.11
	backup 2026-11-20_021500_4.21.0-okd-scos.11 4.21.0-okd-scos.11
	mkdir -p "$(etcd_local_dir)/2026-11-22_021500_x.incomplete" "$(etcd_local_dir)/2026-11-19_broken"
	run _etcd_local_list
	assert_line --index 0 --regexp '^2026-11-20_021500_4.21.0-okd-scos.11	.*	4.21.0-okd-scos.11$'
	assert_line --index 1 --regexp '^2026-11-21_021500_4.21.0-okd-scos.11	'
	assert_equal "${#lines[@]}" 2
}

@test "the proxy of install-config.yaml is passed to the node scripts, shell-quoted" {
	yq_set '.proxy = {"httpProxy": "http://proxy.example.com:3128", "noProxy": ".example.com,192.0.2.0/24"}' "${CLUSTER}/install-config.yaml"
	load_cluster
	run _etcd_proxy_env
	assert_output 'HTTP_PROXY=http://proxy.example.com:3128 NO_PROXY=.example.com\,192.0.2.0/24'
}

@test "restore refuses a backup of another release" {
	backup 2026-11-21_021500_4.21.0-okd-scos.10 4.21.0-okd-scos.10
	fake_cluster
	run cmd_etcd_restore 2026-11-21_021500_4.21.0-okd-scos.10
	assert_failure "${EXIT_CONFIG}"
	assert_output --partial "is from 4.21.0-okd-scos.10, the cluster runs 4.21.0-okd-scos.11"
	run grep -c '^ssh' "${CALLS}"
	assert_output 0
}

@test "restore without a local copy and without API cannot continue" {
	_etcd_api_up() { return 1; }
	run cmd_etcd_restore 2026-11-21_021500_x
	assert_failure
	assert_output --partial "is not in $(etcd_local_dir) and the API does not answer"
}

@test "restore follows the documented order: disable etcd elsewhere, restore, quorum guard off and on" {
	backup 2026-11-21_021500_4.21.0-okd-scos.11 4.21.0-okd-scos.11
	fake_cluster
	run cmd_etcd_restore 2026-11-21_021500_4.21.0-okd-scos.11 --recovery-host small-master-1
	assert_success
	assert_output --partial "etcd restored from 2026-11-21_021500_4.21.0-okd-scos.11"
	local remote="'/home/core/okd-pve-restore-2026-11-21_021500_4.21.0-okd-scos.11'"
	run grep -E '^(ssh|scp|oc patch|oc adm)' "${CALLS}"
	assert_line --index 0 "ssh 192.0.2.12 rm -rf ${remote} && mkdir -m 700 ${remote}"
	assert_line --index 1 "scp core@192.0.2.12:${remote//\'/}/"
	assert_line --index 2 "ssh 192.0.2.11 sudo -E /usr/local/bin/disable-etcd.sh"
	assert_line --index 3 "ssh 192.0.2.13 sudo -E /usr/local/bin/disable-etcd.sh"
	assert_line --index 4 --partial "ssh 192.0.2.12 sudo bash -c 'x=/var/lib/etcd-backup/extra-data-dir-contents;"
	assert_line --index 5 "ssh 192.0.2.12 sudo -E /usr/local/bin/cluster-restore.sh ${remote}"
	assert_line --index 6 --partial '"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true'
	assert_line --index 7 --partial "oc adm wait-for-stable-cluster"
	assert_line --index 8 --partial '"unsupportedConfigOverrides": null'
	assert_line --index 9 "ssh 192.0.2.12 sudo rm -rf /home/core/okd-pve-restore-*"
}

@test "restore stops when a control plane node has no SSH and its VM is running" {
	backup 2026-11-21_021500_4.21.0-okd-scos.11 4.21.0-okd-scos.11
	fake_cluster
	etcd_ssh() { [[ $1 == 192.0.2.13 ]] && return 255; echo "ssh $1 $2" >>"${CALLS}"; }
	proxmox_require() { :; }
	pve_cluster_vms() { echo '[{"vmid": 4102, "status": "running"}]'; }
	cmd_etcd_fetch() { :; }
	run cmd_etcd_restore --latest
	assert_failure
	assert_output --partial "No SSH to small-master-2 (no answer), and its VM is running"
	run grep -c 'disable-etcd\|cluster-restore' "${CALLS}"
	assert_output 0
}

@test "restore continues when the unreachable node is powered off" {
	backup 2026-11-21_021500_4.21.0-okd-scos.11 4.21.0-okd-scos.11
	fake_cluster
	etcd_ssh() {
		[[ $1 == 192.0.2.13 ]] && return 255
		[[ $2 == true ]] && return 0
		echo "ssh $1 $2" >>"${CALLS}"
	}
	proxmox_require() { :; }
	pve_cluster_vms() { echo '[{"vmid": 4102, "status": "stopped"}]'; }
	# --latest fetches first; no backup volume in this fake cluster
	cmd_etcd_fetch() { :; }
	run cmd_etcd_restore --latest
	assert_success
	assert_output --partial "small-master-2: no SSH, VM is stopped"
	run grep -c 'disable-etcd' "${CALLS}"
	assert_output 1
}

@test "the backup script in the hook names, completes and prunes backups" {
	local root=${BATS_TEST_TMPDIR}/root bin=${BATS_TEST_TMPDIR}/bin script=${BATS_TEST_TMPDIR}/backup.sh
	mkdir -p "${root}/host" "${root}/backup" "${bin}"
	for d in 2026-11-17_021500_v 2026-11-18_021500_v 2026-11-19_021500_v .incomplete-2026-11-20_021500_v; do
		mkdir -p "${root}/backup/${d}"
	done
	# the script from the ConfigMap, with /host and /backup moved into the test directory
	sed -n '/^  backup.sh: |$/,/^YAML$/p' "${OKD_PVE_ROOT}/hooks/56-etcd-backup.sh" | sed '1d;$d' | sed 's/^    //' |
		sed "s#/host#${root}/host#g; s#/backup#${root}/backup#g" >"${script}"
	printf '#!/bin/bash\necho 4.21.0-okd-scos.11\n' >"${bin}/oc"
	# chroot <root> cluster-backup.sh <dir>: what the real script leaves behind
	printf '#!/bin/bash\nmkdir -p "$1$3" && touch "$1$3/snapshot_x.db" "$1$3/static_kuberesources_x.tar.gz"\n' >"${bin}/chroot"
	chmod +x "${bin}"/*
	PATH=${bin}:${PATH} KEEP=2 NODE_NAME=small-master-0 run bash "${script}"
	assert_success
	assert_output --partial "removing old backup 2026-11-17_021500_v"
	assert_output --partial "removing old backup 2026-11-18_021500_v"
	run ls "${root}/backup"
	assert_line --index 0 "2026-11-19_021500_v"
	assert_line --index 1 --regexp '^20[0-9-]+_[0-9]{6}_4\.21\.0-okd-scos\.11$'
	assert_equal "${#lines[@]}" 2
	local new=${lines[1]}
	run cat "${root}/backup/${new}/version" "${root}/backup/${new}/node"
	assert_output $'4.21.0-okd-scos.11\nsmall-master-0'
	run ls -A "${root}/host/var/tmp"
	assert_output ""
}

@test "restore needs OKD 4.18 or newer" {
	yq_set '.okd.version = "4.17.0-okd-scos.0"'
	load_cluster
	run cmd_etcd_restore --latest
	assert_failure "${EXIT_CONFIG}"
	assert_output --partial "etcd restore needs OKD 4.18 or newer (this cluster: 4.17)"
}

@test "the warning names the time of the backup" {
	run _etcd_backup_time 2026-11-21_103603_4.22.0-okd-scos.10
	assert_output "2026-11-21 10:36:03 UTC"
}

@test "restore --continue picks up after cluster-restore.sh" {
	fake_cluster
	run cmd_etcd_restore --continue
	assert_success
	assert_output --partial "etcd restored in"
	run grep -E '^(ssh|oc patch|oc adm)' "${CALLS}"
	assert_line --index 0 --partial '"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true'
	assert_line --index 1 --partial "oc adm wait-for-stable-cluster"
	assert_line --index 2 --partial '"unsupportedConfigOverrides": null'
	assert_line --index 3 "ssh 192.0.2.11 sudo rm -rf /home/core/okd-pve-restore-*"
	run grep -c 'disable-etcd\|cluster-restore' "${CALLS}"
	assert_output 0
}

@test "a restore that does not roll out etcd gets a forced redeployment" {
	fake_cluster
	ETCD_MASTERS=(a b c)
	local n=0
	_etcd_members_count() { echo 1; }
	SECONDS=0
	sleep() { SECONDS=$((SECONDS + 300)); }
	ETCD_RESTORE_TIMEOUT=1500
	run _etcd_restore_finish 192.0.2.11 0
	assert_failure
	assert_output --partial "forcing an etcd redeployment"
	assert_output --partial "1/3 etcd members running"
	run grep -c 'forceRedeploymentReason' "${CALLS}"
	assert_output 1
}

@test "restore names a changed host key of the recovery host" {
	backup 2026-11-21_021500_4.21.0-okd-scos.11 4.21.0-okd-scos.11
	fake_cluster
	etcd_ssh() {
		[[ $1 == 192.0.2.11 ]] && { echo "Host key verification failed." >&2; return 255; }
		return 0
	}
	run cmd_etcd_restore 2026-11-21_021500_4.21.0-okd-scos.11
	assert_failure
	assert_output --partial "No SSH to the recovery host small-master-0 (core@192.0.2.11): Host key verification failed."
	assert_output --partial "ssh-keygen -R 192.0.2.11 -f"
}

@test "fetch retries a copy that breaks off" {
	_etcd_require_cronjob() { :; }
	_etcd_browser_start() { :; }
	_etcd_browser_stop() { :; }
	_etcd_remote_list() { printf '2026-11-21_213817_5.0.0-okd-scos.8\t5.0.0-okd-scos.8\t76M\n'; }
	TRIES=${BATS_TEST_TMPDIR}/tries
	: >"${TRIES}"
	# the first stream breaks off, the second one is complete
	oc() {
		local src=${BATS_TEST_TMPDIR}/src
		echo x >>"${TRIES}"
		mkdir -p "${src}" && touch "${src}/snapshot_x.db" "${src}/static_kuberesources_x.tar.gz"
		if (($(wc -l <"${TRIES}") == 1)); then
			tar -C "${src}" -cf - . | head -c 100
			return 1
		fi
		tar -C "${src}" -cf - .
	}
	ETCD_FETCH_RETRY_DELAY=0
	run cmd_etcd_fetch --latest
	assert_success
	assert_output --partial "was interrupted; trying again (1/3)"
	assert_output --partial "Fetched 2026-11-21_213817_5.0.0-okd-scos.8"
	assert_equal "$(wc -l <"${TRIES}")" 2
	assert [ ! -e "$(etcd_local_dir)/2026-11-21_213817_5.0.0-okd-scos.8.incomplete" ]
}

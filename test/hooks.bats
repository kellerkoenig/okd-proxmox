#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Post-Install hook mechanics (lib/hooks.sh).

setup() {
	load test_helper
	load_libs
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	BUILTIN=${BATS_TEST_TMPDIR}/builtin
	EXTERNAL=${BATS_TEST_TMPDIR}/external
	mkdir -p "${BUILTIN}/manifests" "${EXTERNAL}/manifests"
	builtin_hooks_dir() { printf '%s' "${BUILTIN}"; }
	yq_set '.hooks.builtin = "all" | .hooks.dir = "'"${EXTERNAL}"'"'
	load_cluster
}

# hook <dir> <name> <exit-code> [body]
hook() {
	printf '#!/usr/bin/env bash\necho "ran %s in $OKD_PVE_CLUSTER_NAME"\n%s\nexit %s\n' "$2" "${4:-}" "$3" >"$1/$2"
	chmod +x "$1/$2"
}

@test "hooks from both sources are merged and sorted, external wins on collision" {
	hook "${BUILTIN}" 10-a.sh 0
	hook "${BUILTIN}" 30-c.sh 0
	hook "${EXTERNAL}" 20-b.sh 0
	hook "${EXTERNAL}" 30-c.sh 0
	printf 'apiVersion: v1\nkind: Namespace\nmetadata: {name: x}\n' >"${EXTERNAL}/manifests/25-ns.yaml"
	hook "${BUILTIN}" not-numbered.sh 0
	printf 'echo no' >"${BUILTIN}/40-not-executable.sh"
	run hooks_collect
	assert_success
	assert_line --index 0 --regexp '^10-a.sh	exec	.*/builtin/10-a.sh	builtin$'
	assert_line --index 1 --regexp '^20-b.sh	exec	.*	external$'
	assert_line --index 2 --regexp '^25-ns.yaml	manifest	.*/external/manifests/25-ns.yaml	external$'
	assert_line --index 3 --regexp '^30-c.sh	exec	.*/external/30-c.sh	external$'
	assert_equal "${#lines[@]}" 4
}

@test "built-in hooks only run when selected, skip list applies to both" {
	hook "${BUILTIN}" 10-a.sh 0
	hook "${BUILTIN}" 20-b.sh 0
	hook "${EXTERNAL}" 30-c.sh 0
	hook "${EXTERNAL}" 40-d.sh 0
	yq_set '.hooks.builtin = ["20-b"] | .hooks.skip = ["40-d.sh"]'
	load_cluster
	run hooks_collect
	assert_equal "$(cut -f1 <<<"${output}" | paste -sd' ' -)" "20-b.sh 30-c.sh"
}

@test "--hooks-dir overrides hooks.dir" {
	local other=${BATS_TEST_TMPDIR}/other
	mkdir -p "${other}"
	hook "${other}" 50-x.sh 0
	HOOKS_DIR_OVERRIDE=${other}
	run hooks_collect
	assert_output --regexp '50-x.sh'
}

@test "hooks get the documented environment" {
	hook "${EXTERNAL}" 10-env.sh 0 'echo "env:$OKD_PVE_CLUSTER_NAME:$OKD_PVE_BASE_DOMAIN:$OKD_PVE_STORAGE_CLASS:$OKD_PVE_INFRA_TAINT_KEY=$OKD_PVE_INFRA_TAINT_VALUE:$INGRESS_REPLICAS:${KUBECONFIG##*/}"'
	run hooks_run
	assert_success
	assert_output --partial "env:small:example.com:nfs:node-role.kubernetes.io/infra=reserved:3:kubeconfig"
}

@test "secrets in hooks.env and the environment are masked in hook output and logs" {
	yq_set '.hooks.env.ALERTMANAGER_WEBHOOK_URL = "https://chat.example.com/hooks/abcd1234secret"'
	load_cluster
	export OIDC_CLIENT_SECRET=s3cr3t-value
	hook "${EXTERNAL}" 10-leak.sh 0 'echo "url=$ALERTMANAGER_WEBHOOK_URL secret=$OIDC_CLIENT_SECRET"'
	run hooks_run
	assert_success
	assert_output --partial "url=***REDACTED*** secret=***REDACTED***"
	run grep -c 'abcd1234secret\|s3cr3t-value' "${LOG_FILE}"
	assert_output 0
}

@test "exit code 2 is a warning and the run continues; report lists all hooks" {
	hook "${EXTERNAL}" 10-ok.sh 0
	hook "${EXTERNAL}" 20-warn.sh 2
	hook "${EXTERNAL}" 30-ok.sh 0
	run hooks_run
	assert_success
	assert_output --partial "ran 30-ok.sh"
	assert_output --regexp '20-warn.sh +external +[0-9]+s +warning'
	assert_output --regexp '30-ok.sh +external +[0-9]+s +ok'
	assert_equal "$(state_hook_last 20-warn.sh | cut -d' ' -f1)" warning
}

@test "hooks list shows hooks that never ran" {
	hook "${EXTERNAL}" 10-ok.sh 0
	hook "${EXTERNAL}" 20-new.sh 0
	hook "${EXTERNAL}" 30-new.sh 0
	hooks_run 10-ok >/dev/null
	run cmd_hooks_list
	assert_success
	assert_output --regexp '10-ok.sh +exec +external +ok \('
	assert_output --regexp '20-new.sh +exec +external +-'
	assert_output --regexp '30-new.sh +exec +external +-'
	assert_output --partial "Built-in hooks run only when listed"
}

@test "exit code 1 aborts with exit code 4 and names the hook to re-run" {
	hook "${EXTERNAL}" 10-ok.sh 0
	hook "${EXTERNAL}" 20-fail.sh 1
	hook "${EXTERNAL}" 30-never.sh 0
	run hooks_run
	assert_failure 4
	refute_output --partial "ran 30-never.sh"
	assert_output --regexp '30-never.sh +external +- +not run'
	assert_output --partial "okd-pve hooks run --from 20-fail.sh"
}

@test "a single hook can be run by name with or without number and extension" {
	hook "${EXTERNAL}" 10-one.sh 0
	hook "${EXTERNAL}" 20-two.sh 0
	run hooks_run two
	assert_success
	assert_output --partial "ran 20-two.sh"
	refute_output --partial "ran 10-one.sh"
	run hooks_run nope
	assert_failure 2
}

@test "--from runs the named hook and everything after it" {
	hook "${EXTERNAL}" 10-one.sh 0
	hook "${EXTERNAL}" 20-two.sh 0
	hook "${EXTERNAL}" 30-three.sh 0
	run hooks_run --from 20-two
	assert_success
	refute_output --partial "ran 10-one.sh"
	assert_output --partial "ran 20-two.sh"
	assert_output --partial "ran 30-three.sh"
}

@test "dry-run lists hooks without running them" {
	hook "${EXTERNAL}" 10-one.sh 0
	DRY_RUN=1
	run hooks_run
	assert_success
	assert_output --partial "[dry-run] would run hook 10-one.sh"
	refute_output --partial "ran 10-one.sh"
}

@test "manifests are applied with oc apply" {
	oc() { echo "oc $*"; }
	export -f oc
	printf 'apiVersion: v1\nkind: Namespace\nmetadata: {name: x}\n' >"${EXTERNAL}/manifests/60-ns.yaml"
	run hooks_run
	assert_success
	assert_output --partial "oc apply -f ${EXTERNAL}/manifests/60-ns.yaml"
}

@test "shipped hooks are executable, numbered and examples are disabled" {
	local f
	for f in "${OKD_PVE_ROOT}"/hooks/[0-9]*.sh; do
		assert [ -x "${f}" ]
	done
	for f in "${OKD_PVE_ROOT}"/hooks/*.example; do
		assert [ ! -x "${f}" ]
	done
}

#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Logging, redaction and helpers from lib/common.sh.

setup() {
	load test_helper
	load_libs
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	: >"${LOG_FILE}"
}

@test "redact_string masks registered secrets" {
	redact_register "${TEST_TOKEN}" "${TEST_TOKEN_SECRET}"
	run redact_string "token is ${TEST_TOKEN} and secret ${TEST_TOKEN_SECRET}."
	assert_success
	assert_output "token is ***REDACTED*** and secret ***REDACTED***."
	refute_output --partial "${TEST_TOKEN_SECRET}"
}

@test "redact_string masks PVEAPIToken headers without registration" {
	run redact_string "Authorization: PVEAPIToken=someone@pve!id=abcdef-123 next"
	assert_output "Authorization: PVEAPIToken=***REDACTED*** next"
}

@test "redact_string masks several bearer tokens on one line" {
	run redact_string "a Authorization: Bearer sha256~one b Authorization: Bearer sha256~two"
	assert_output "a Authorization: Bearer ***REDACTED*** b Authorization: Bearer ***REDACTED***"
}

@test "redact_register ignores very short values" {
	redact_register "ab"
	run redact_string "about abc"
	assert_output "about abc"
}

@test "redact_stream masks secrets in streams, longest value first" {
	redact_register "${TEST_TOKEN_SECRET}" "${TEST_TOKEN}"
	run bash -c "source '${OKD_PVE_ROOT}/lib/common.sh'
		REDACT_VALUES=('${TEST_TOKEN_SECRET}' '${TEST_TOKEN}')
		printf 'one %s\ntwo %s\n' '${TEST_TOKEN}' '${TEST_TOKEN_SECRET}' | redact"
	assert_success
	assert_line --index 0 "one ***REDACTED***"
	assert_line --index 1 "two ***REDACTED***"
}

@test "redact_stream writes log and copy files" {
	redact_register "${TEST_TOKEN}"
	printf 'x %s\n' "${TEST_TOKEN}" | redact_stream --log "${LOG_FILE}" --copy "${BATS_TEST_TMPDIR}/copy"
	run cat "${LOG_FILE}" "${BATS_TEST_TMPDIR}/copy"
	assert_output $'x ***REDACTED***\nx ***REDACTED***'
}

@test "log functions never write secrets to stdout, stderr or the log file" {
	redact_register "${TEST_TOKEN}" "${TEST_TOKEN_SECRET}"
	DEBUG=1
	local f
	for f in log_info log_warn log_error log_debug log_step log_hint log_ok log_raw; do
		run "${f}" "message ${TEST_TOKEN} / ${TEST_TOKEN_SECRET}"
		refute_output --partial "${TEST_TOKEN_SECRET}"
	done
	run cat "${LOG_FILE}"
	refute_output --partial "${TEST_TOKEN_SECRET}"
	assert_output --partial "[INFO] message ***REDACTED*** / ***REDACTED***"
}

@test "die exits with the given code and prints the hint" {
	run die 2 "broken config" "fix it"
	assert_failure 2
	assert_output --partial "ERROR: broken config"
	assert_output --partial "Next step: fix it"
}

@test "version_ge compares dotted versions" {
	version_ge 1.13.2 1.8.0
	version_ge 4.17 4.17.0
	version_ge 9.2.21 8.0
	run version_ge 1.7.9 1.8.0
	assert_failure
	version_ge 4.21.0-okd-scos.11 4.17
}

@test "join_by and elapsed" {
	run join_by ', ' a b c
	assert_output "a, b, c"
	SECONDS=3725
	run elapsed 0
	assert_output "1h02m05s"
}

@test "dry_run_note only acts in dry-run mode" {
	DRY_RUN=0
	run dry_run_note "would do"
	assert_failure
	DRY_RUN=1
	run dry_run_note "would do"
	assert_success
	assert_output --partial "[dry-run] would do"
}

@test "confirm answers yes with --yes and no without a terminal" {
	ASSUME_YES=1
	confirm "really?"
	ASSUME_YES=0
	run confirm "really?" </dev/null
	assert_failure
}

@test "every pinned Butane version has checksums for all platforms" {
	local p
	for p in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin; do
		[[ ${BUTANE_SHA256[${BUTANE_VERSION}/${p}]:-} =~ ^[0-9a-f]{64}$ ]] ||
			fail "BUTANE_SHA256 has no checksum for ${BUTANE_VERSION}/${p} (lib/versions.sh)"
	done
}

@test "Makefile and lib/versions.sh pin the same OpenTofu and Butane versions" {
	assert_equal "$(sed -n 's/^TOFU_VERSION *:= *//p' "${OKD_PVE_ROOT}/Makefile")" "${TOFU_VERSION}"
	assert_equal "$(sed -n 's/^BUTANE_VERSION *:= *//p' "${OKD_PVE_ROOT}/Makefile")" "${BUTANE_VERSION}"
}

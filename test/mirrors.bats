#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Registry mirrors (lib/mirrors.sh): validation, install-config, Pre-Boot
# manifest, preflight and 'mirrors apply' against a fake oc.

setup() {
	load test_helper
	load_libs
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	: >"${LOG_FILE}"
	IC=${BATS_TEST_TMPDIR}/ic.yaml
}

# _mirrors [fallback]: two mirrors, quay.io with its own fallback setting.
_mirrors() {
	yq_set ".registry_mirrors.fallback = ${1:-false}"
	yq_set '.registry_mirrors.registries = [
		{"source": "quay.io", "mirror": "quay-cache.example.com", "fallback": true},
		{"source": "registry.redhat.io", "mirror": "cache.example.com:5000/redhat"}]'
}

_auth_file() {
	jq -n '{auths: {"quay-cache.example.com": {auth: "bWlycm9yOnNlY3JldA=="}}}' >"${CLUSTER}/mirror-auth.json"
	chmod 600 "${CLUSTER}/mirror-auth.json"
	yq_set '.registry_mirrors.auth_file = "mirror-auth.json"'
}

@test "without registry_mirrors nothing changes" {
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq '.imageDigestSources' "${IC}")" null
	assert_equal "$(yq '.proxy' "${IC}")" null
	run mirrors_enabled
	assert_failure
}

@test "install-config gets imageDigestSources, no fallback by default" {
	_mirrors
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq -o json -I0 '.imageDigestSources' "${IC}")" \
		'[{"source":"quay.io","mirrors":["quay-cache.example.com"],"sourcePolicy":"AllowContactingSource"},{"source":"registry.redhat.io","mirrors":["cache.example.com:5000/redhat"],"sourcePolicy":"NeverContactSource"},{"source":"quay.io/okd/scos-release","mirrors":["quay-cache.example.com/okd/scos-release"],"sourcePolicy":"AllowContactingSource"},{"source":"quay.io/okd/scos-content","mirrors":["quay-cache.example.com/okd/scos-content"],"sourcePolicy":"AllowContactingSource"}]'
}

@test "the release repositories get exact entries from the most specific covering mirror" {
	yq_set '.registry_mirrors.registries = [
		{"source": "quay.io", "mirror": "quay-cache.example.com"},
		{"source": "quay.io/okd", "mirror": "cache.example.com:5000/okd", "fallback": true},
		{"source": "quay.io/okd/scos-content", "mirror": "content.example.com/c"}]'
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq -o json -I0 '[.imageDigestSources[] | select(.source == "quay.io/okd/scos-release")]' "${IC}")" \
		'[{"source":"quay.io/okd/scos-release","mirrors":["cache.example.com:5000/okd/scos-release"],"sourcePolicy":"AllowContactingSource"}]'
	# a repository with its own entry is not added again
	assert_equal "$(yq '[.imageDigestSources[] | select(.source == "quay.io/okd/scos-content")] | length' "${IC}")" 1
	# no mirror for quay.io: nothing added
	yq_set '.registry_mirrors.registries = [{"source": "registry.redhat.io", "mirror": "redhat-cache.example.com"}]'
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq -r '.imageDigestSources[].source' "${IC}" | paste -sd' ')" "registry.redhat.io"
}

@test "registry_mirrors.fallback: true allows the source for every entry without its own setting" {
	_mirrors true
	yq_set '.registry_mirrors.registries[0].fallback = false'
	load_cluster
	render_install_config "${IC}"
	# the release repositories inherit the policy of the quay.io entry
	assert_equal "$(yq -r '.imageDigestSources[] | .sourcePolicy' "${IC}" | paste -sd' ')" \
		"NeverContactSource AllowContactingSource NeverContactSource NeverContactSource"
}

@test "imageDigestSources from install-config.yaml are kept" {
	_mirrors
	yq_set '.imageDigestSources = [{"source": "registry.example.org", "mirrors": ["mirror.example.org"]}]' "${CLUSTER}/install-config.yaml"
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq -r '.imageDigestSources[].source' "${IC}" | paste -sd' ')" \
		"registry.example.org quay.io registry.redhat.io quay.io/okd/scos-release quay.io/okd/scos-content"
}

@test "mirror hosts are added to noProxy unless already covered" {
	_mirrors
	yq_set '.proxy = {"httpProxy": "http://proxy.example.net:3128", "httpsProxy": "http://proxy.example.net:3128", "noProxy": ".example.org,example.com"}' "${CLUSTER}/install-config.yaml"
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq -r '.proxy.noProxy' "${IC}")" ".example.org,example.com"
	yq_set '.proxy.noProxy = "198.51.100.0/24,quay-cache.example.com"' "${CLUSTER}/install-config.yaml"
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq -r '.proxy.noProxy' "${IC}")" "198.51.100.0/24,quay-cache.example.com,cache.example.com"
	# the source file is not modified
	assert_equal "$(yq -r '.proxy.noProxy' "${CLUSTER}/install-config.yaml")" "198.51.100.0/24,quay-cache.example.com"
}

@test "no_proxy_covers matches like Go and curl" {
	run no_proxy_covers a.example.com "example.com"
	assert_success
	run no_proxy_covers a.example.com ".example.com"
	assert_success
	run no_proxy_covers a.example.com "other.example.org, *.example.com"
	assert_success
	run no_proxy_covers cache.example.com:5000 "cache.example.com"
	assert_success
	run no_proxy_covers anything "*"
	assert_success
	run no_proxy_covers cache.example.com "he.example.com"
	assert_failure
	run no_proxy_covers example.com ""
	assert_failure
}

@test "the mirror credentials are merged into the pull secret" {
	_mirrors
	_auth_file
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq -r '.pullSecret | fromjson | .auths | keys | join(" ")' "${IC}")" "fake quay-cache.example.com"
}

@test "username and password from cluster.yaml become pull secret entries for every mirror" {
	_mirrors
	yq_set '.registry_mirrors.username = "svc" | .registry_mirrors.password = "pw-cluster-yaml"'
	yq_set '.registry_mirrors.registries[1].username = "other" | .registry_mirrors.registries[1].password = "pw-entry"'
	load_cluster
	render_install_config "${IC}"
	assert_equal "$(yq -r '.pullSecret | fromjson | .auths["quay-cache.example.com"].auth | @base64d' "${IC}")" "svc:pw-cluster-yaml"
	assert_equal "$(yq -r '.pullSecret | fromjson | .auths["cache.example.com:5000/redhat"].auth | @base64d' "${IC}")" "other:pw-entry"
}

@test "OKD_PVE_MIRROR_PASSWORD overrides registry_mirrors.password, never an entry's own" {
	_mirrors
	yq_set '.registry_mirrors.username = "svc" | .registry_mirrors.password = "pw-cluster-yaml"'
	yq_set '.registry_mirrors.registries[1].password = "pw-entry"'
	load_cluster
	export OKD_PVE_MIRROR_PASSWORD=pw-from-env
	assert_equal "$(mirrors_config_auths | jq -r '.["quay-cache.example.com"].auth | @base64d')" "svc:pw-from-env"
	assert_equal "$(mirrors_config_auths | jq -r '.["cache.example.com:5000/redhat"].auth | @base64d')" "svc:pw-entry"
}

@test "username/password win over auth_file for the same mirror" {
	_mirrors
	_auth_file
	yq_set '.registry_mirrors.username = "svc" | .registry_mirrors.password = "pw-cluster-yaml"'
	load_cluster
	assert_equal "$(pull_secret_value | jq -r '.auths["quay-cache.example.com"].auth | @base64d')" "svc:pw-cluster-yaml"
}

@test "mirror passwords are masked in every output" {
	_mirrors
	yq_set '.registry_mirrors.username = "svc" | .registry_mirrors.password = "pw-cluster-yaml"'
	load_cluster
	export OKD_PVE_MIRROR_PASSWORD=pw-from-env
	register_pull_secret
	run redact_string "a pw-from-env b pw-cluster-yaml c $(printf svc:pw-from-env | base64)"
	assert_output "a ***REDACTED*** b ***REDACTED*** c ***REDACTED***"
}

@test "incomplete mirror credentials are configuration errors" {
	_mirrors
	yq_set '.registry_mirrors.username = "svc"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "registry_mirrors: quay-cache.example.com has a username but no password (set registry_mirrors.password or OKD_PVE_MIRROR_PASSWORD)"
	# the password from the environment completes it
	OKD_PVE_MIRROR_PASSWORD=pw-from-env run config_validate
	assert_success
	yq_set '.registry_mirrors.username = "" | .registry_mirrors.password = "pw"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "registry_mirrors.password is set but no username"
	yq_set '.registry_mirrors.password = 5'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "registry_mirrors.password must be a string"
}

@test "a missing auth_file is a configuration error" {
	_mirrors
	yq_set '.registry_mirrors.auth_file = "nope.json"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "registry_mirrors.auth_file ${CLUSTER}/nope.json does not exist"
}

@test "invalid registry_mirrors are rejected" {
	yq_set '.registry_mirrors.fallback = "no"'
	yq_set '.registry_mirrors.registries = [
		{"source": "https://quay.io", "mirror": "quay-cache.example.com"},
		{"source": "registry.redhat.io", "mirror": "https://cache.example.com", "fallback": "yes"},
		{"source": "registry.redhat.io", "mirror": "cache.example.com"}]'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "registry_mirrors.fallback must be true or false"
	assert_output --partial 'source "https://quay.io" must be a registry host'
	assert_output --partial 'mirror "https://cache.example.com" of registry.redhat.io must be a host'
	assert_output --partial "fallback of registry.redhat.io must be true or false"
	assert_output --partial "source registry.redhat.io is listed more than once"
}

@test "a source in both registry_mirrors and imageDigestSources is rejected" {
	_mirrors
	yq_set '.imageDigestSources = [{"source": "quay.io", "mirrors": ["mirror.example.org"]}]' "${CLUSTER}/install-config.yaml"
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "source quay.io is also in imageDigestSources of install-config.yaml"
}

@test "Pre-Boot: an ImageTagMirrorSet for images pulled by tag" {
	command -v butane >/dev/null || skip "butane not installed"
	BUTANE=$(command -v butane)
	_mirrors
	load_cluster
	manifests_render "${BATS_TEST_TMPDIR}/out"
	local f=${BATS_TEST_TMPDIR}/out/${MIRRORS_ITMS_FILE}
	assert_equal "$(yq -r '.kind + " " + .metadata.name' "${f}")" "ImageTagMirrorSet image-tag-mirror"
	assert_equal "$(yq -o json -I0 '.spec.imageTagMirrors[1]' "${f}")" \
		'{"source":"registry.redhat.io","mirrors":["cache.example.com:5000/redhat"],"mirrorSourcePolicy":"NeverContactSource"}'
}

@test "Pre-Boot: no ImageTagMirrorSet without mirrors" {
	command -v butane >/dev/null || skip "butane not installed"
	BUTANE=$(command -v butane)
	load_cluster
	manifests_render "${BATS_TEST_TMPDIR}/out"
	[[ ! -e ${BATS_TEST_TMPDIR}/out/${MIRRORS_ITMS_FILE} ]]
}

@test "preflight: anonymous, credentials, missing credentials, no answer" {
	_mirrors
	_auth_file
	yq_set '.registry_mirrors.registries += [{"source": "registry.example.net", "mirror": "down.example.com", "fallback": true}]'
	load_cluster
	registry_probe() {
		case $1 in
		quay-cache.example.com) [[ -n ${2:-} ]] && echo 200 || echo 401 ;;
		cache.example.com:5000) echo 401 ;;
		*) echo 000 ;;
		esac
	}
	run pf_mirrors
	assert_output --partial "[PASS] Mirror quay-cache.example.com accepts the credentials from the pull secret"
	assert_output --partial "[FAIL] Mirror cache.example.com:5000 needs credentials, but the pull secret has none for it"
	assert_output --partial "[WARN] Mirror down.example.com does not answer"
	refute_output --partial "bWlycm9yOnNlY3JldA=="
}

@test "preflight: rejected credentials of a mirror with fallback only warn" {
	_mirrors
	_auth_file
	load_cluster
	registry_probe() { echo 401; }
	registry_token_probe() { echo 401; }
	run pf_mirrors
	assert_output --partial "[WARN] Mirror quay-cache.example.com rejects the credentials from the pull secret (HTTP 401)"
}

# _fake_cluster: oc that knows the objects 'mirrors apply' touches, and a
# curl that answers 200 on every registry /v2/.
_fake_cluster() {
	use_mocks
	write_proxmox_conf
	mkdir -p "${CLUSTER}/.state/steps" "${CLUSTER}/auth" "${BATS_TEST_TMPDIR}/bin" "${BATS_TEST_TMPDIR}/live"
	touch "${CLUSTER}/.state/steps/install"
	echo "apiVersion: v1" >"${CLUSTER}/auth/kubeconfig"
	echo '{"auths":{"quay.io":{"auth":"cXVheTpxdWF5"}}}' >"${BATS_TEST_TMPDIR}/live/pull-secret"
	export LIVE=${BATS_TEST_TMPDIR}/live OKD_PVE_MCP_SETTLE=0
	cat >"${BATS_TEST_TMPDIR}/bin/oc" <<'OC'
#!/usr/bin/env bash
echo "oc $*" >>"${MOCK_LOG}"
case "$*" in
"version --client"*) echo '{"releaseClientVersion":"4.21.0-okd-scos.11"}' ;;
"get imagedigestmirrorset image-digest-mirror"* | "get imagetagmirrorset image-tag-mirror"*)
	f=${LIVE}/$2
	[[ -f ${f} ]] && yq -o json "${f}"
	;;
"apply -f -")
	doc=$(cat)
	kind=$(yq -r '.kind | downcase' <<<"${doc}")
	printf '%s\n' "${doc}" >"${LIVE}/${kind}"
	;;
"get secret pull-secret -n openshift-config -o json")
	jq -n --arg d "$(base64 -w0 "${LIVE}/pull-secret")" '{data: {".dockerconfigjson": $d}}'
	;;
"set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="*)
	cp "${6#--from-file=.dockerconfigjson=}" "${LIVE}/pull-secret"
	;;
"delete "*) rm -f "${LIVE}/$2" ;;
"get proxy cluster -o json") echo '{"spec": {}}' ;;
"get machineconfigpool -o jsonpath"*) printf 'master\nworker\n' ;;
"get machineconfigpool "*" -o json")
	echo '{"status": {"machineCount": 3, "updatedMachineCount": 3, "conditions": [{"type": "Updated", "status": "True"}]}}'
	;;
esac
exit 0
OC
	cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'CURL'
#!/usr/bin/env bash
for a; do
	if [[ ${a} == https://*/v2/ ]]; then
		cat >/dev/null
		printf 200
		exit 0
	fi
done
exec "${OKD_PVE_ROOT}/test/mocks/curl" "$@"
CURL
	chmod +x "${BATS_TEST_TMPDIR}/bin/oc" "${BATS_TEST_TMPDIR}/bin/curl"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

@test "mirrors apply --dry-run changes nothing" {
	_mirrors
	_auth_file
	_fake_cluster
	run "${OKD_PVE_ROOT}/okd-pve" --dir "${CLUSTER}" --dry-run --no-color mirrors apply
	assert_success
	assert_output --partial "would add the credentials for quay-cache.example.com to openshift-config/pull-secret"
	assert_output --partial "would apply imagedigestmirrorset/image-digest-mirror"
	assert_output --partial "would apply imagetagmirrorset/image-tag-mirror"
	[[ ! -e ${LIVE}/imagetagmirrorset ]]
	assert_equal "$(jq -r '.auths | keys | join(" ")' "${LIVE}/pull-secret")" "quay.io"
}

@test "mirrors apply creates the mirror sets, merges the pull secret and is idempotent" {
	_mirrors
	_auth_file
	_fake_cluster
	run "${OKD_PVE_ROOT}/okd-pve" --dir "${CLUSTER}" --no-color mirrors apply
	assert_success
	assert_output --partial "Registry mirrors applied"
	assert_equal "$(jq -r '.auths | keys | join(" ")' "${LIVE}/pull-secret")" "quay-cache.example.com quay.io"
	assert_equal "$(yq -r '.spec.imageDigestMirrors[1].mirrorSourcePolicy' "${LIVE}/imagedigestmirrorset")" NeverContactSource
	assert_equal "$(yq -r '.spec.imageTagMirrors[0].mirrors[0]' "${LIVE}/imagetagmirrorset")" quay-cache.example.com
	grep -q 'get machineconfigpool worker -o json' "${MOCK_LOG}"
	refute grep -q 'bWlycm9yOnNlY3JldA==' "${MOCK_LOG}" "${CLUSTER}"/logs/*.log

	run "${OKD_PVE_ROOT}/okd-pve" --dir "${CLUSTER}" --no-color mirrors apply
	assert_success
	assert_output --partial "Registry mirrors are up to date"
}

@test "mirrors apply without mirrors removes the mirror sets" {
	_mirrors
	_fake_cluster
	"${OKD_PVE_ROOT}/okd-pve" --dir "${CLUSTER}" --no-color mirrors apply >/dev/null
	[[ -e ${LIVE}/imagetagmirrorset ]]
	yq_set '.registry_mirrors.registries = []'
	run "${OKD_PVE_ROOT}/okd-pve" --dir "${CLUSTER}" --no-color mirrors apply
	assert_success
	assert_output --partial "imagetagmirrorset/image-tag-mirror deleted"
	assert_output --partial "imagedigestmirrorset/image-digest-mirror deleted"
}

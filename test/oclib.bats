#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# oc helpers (lib/oclib.sh) and catalog profiles (lib/catalog.sh) with a
# mocked oc.

setup() {
	load test_helper
	OCLIB_POLL_INTERVAL=0
	# shellcheck source=../lib/oclib.sh
	source "${OKD_PVE_ROOT}/lib/oclib.sh"
	# shellcheck source=../lib/catalog.sh
	source "${OKD_PVE_ROOT}/lib/catalog.sh"
	OC_LOG=${BATS_TEST_TMPDIR}/oc.log
	: >"${OC_LOG}"
}

@test "patch_merge does nothing when the live object already matches" {
	oc() {
		echo "oc $*" >>"${OC_LOG}"
		[[ $1 == get ]] && echo '{"spec":{"replicas":2,"tuningOptions":{"headerBufferBytes":32768},"other":1}}'
		return 0
	}
	run patch_merge ingresscontroller/default '{"spec":{"replicas":2,"tuningOptions":{"headerBufferBytes":32768}}}' -n openshift-ingress-operator
	assert_success
	run grep -c 'oc patch' "${OC_LOG}"
	assert_output 0
}

@test "patch_merge patches when a value differs or a key must be removed" {
	oc() {
		echo "oc $*" >>"${OC_LOG}"
		[[ $1 == get ]] && echo '{"spec":{"replicas":2,"old":"x"}}'
		return 0
	}
	patch_merge ingresscontroller/default '{"spec":{"replicas":3}}'
	patch_merge ingresscontroller/default '{"spec":{"old":null}}'
	run grep -c 'oc patch ingresscontroller/default --type merge' "${OC_LOG}"
	assert_output 2
}

@test "sa_token uses the TokenRequest API, never 'serviceaccounts get-token'" {
	oc() {
		echo "oc $*" >>"${OC_LOG}"
		[[ $1 == create && $2 == token ]] && echo "eyJ.token"
		return 0
	}
	run sa_token inventory okd-pve-inventory --duration 24h
	assert_success
	assert_output "eyJ.token"
	run grep -c 'get-token' "${OC_LOG}"
	assert_output 0
	run grep -c 'oc create token inventory -n okd-pve-inventory --duration 24h' "${OC_LOG}"
	assert_output 1
}

@test "sa_token --long-lived creates a service-account-token secret" {
	oc() {
		echo "oc $*" >>"${OC_LOG}"
		if [[ $1 == apply ]]; then cat >>"${OC_LOG}"; fi
		if [[ $1 == get && $2 == secret ]]; then printf '%s' "$(printf 'long-token' | base64)"; fi
		return 0
	}
	run sa_token inventory ns1 --long-lived
	assert_success
	assert_output "long-token"
	run grep -c 'type: kubernetes.io/service-account-token' "${OC_LOG}"
	assert_output 1
}

@test "install_operator resolves @default, picks OwnNamespace and waits for CSV and CRDs" {
	oc() {
		echo "oc $*" >>"${OC_LOG}"
		case "$1 $2" in
		"get packagemanifests")
			echo '{"items":[{"metadata":{"name":"cluster-kube-descheduler-operator"},"status":{"defaultChannel":"stable","channels":[{"name":"stable","currentCSVDesc":{"installModes":[{"type":"OwnNamespace","supported":true},{"type":"AllNamespaces","supported":false}]}}]}}]}'
			;;
		"get operatorgroups") echo '{"items":[]}' ;;
		"get subscription.operators.coreos.com") echo "descheduler.v5.3.0" ;;
		"get csv")
			if [[ $* == *jsonpath* ]]; then echo Succeeded; else echo '{"spec":{"customresourcedefinitions":{"owned":[{"name":"kubedeschedulers.operator.openshift.io"}]}}}'; fi
			;;
		"get crd") echo '{"status":{"conditions":[{"type":"Established","status":"True"}]}}' ;;
		"get namespace") return 1 ;;
		"apply -f") cat >>"${OC_LOG}" ;;
		esac
		return 0
	}
	run install_operator cluster-kube-descheduler-operator @default openshift-kube-descheduler-operator redhat-operators
	assert_success
	run grep -c 'channel: stable$' "${OC_LOG}"
	assert_output 1
	run grep -c 'targetNamespaces: \[openshift-kube-descheduler-operator\]' "${OC_LOG}"
	assert_output 1
	run grep -c 'oc get crd kubedeschedulers.operator.openshift.io' "${OC_LOG}"
	assert_output 1
}

@test "install_operator fails clearly for an unknown channel or package" {
	oc() {
		[[ "$1 $2" == "get packagemanifests" ]] &&
			echo '{"items":[{"metadata":{"name":"web-terminal"},"status":{"defaultChannel":"fast","channels":[{"name":"fast"}]}}]}'
		return 0
	}
	run install_operator web-terminal nightly openshift-operators
	assert_failure
	assert_output --partial "Channel nightly does not exist for web-terminal in redhat-operators. Available: fast"
	run install_operator missing-op stable ns1
	assert_failure
	assert_output --partial "Package missing-op not found in catalog redhat-operators"
}

@test "catalog profiles and per-operator overrides" {
	OKD_PVE_CATALOG_PROFILE=redhat
	run operator_coordinates cert-manager
	assert_output "openshift-cert-manager-operator @default cert-manager-operator redhat-operators"
	OKD_PVE_CATALOG_PROFILE=okderators
	run operator_coordinates cert-manager
	assert_output "cert-manager-operator @default cert-manager-operator okderators"
	run operator_coordinates cluster-resource-override
	assert_failure
	OKD_PVE_OP_CLUSTER_RESOURCE_OVERRIDE_PACKAGE=clusterresourceoverride
	OKD_PVE_OP_CLUSTER_RESOURCE_OVERRIDE_CHANNEL=stable
	OKD_PVE_OP_CLUSTER_RESOURCE_OVERRIDE_NAMESPACE=cro
	OKD_PVE_OP_CLUSTER_RESOURCE_OVERRIDE_SOURCE=my-catalog
	run operator_coordinates cluster-resource-override
	assert_output "clusterresourceoverride stable cro my-catalog"
}

@test "infra_tolerations_json matches the configured taint" {
	OKD_PVE_INFRA_TAINT_KEY=example.com/infra OKD_PVE_INFRA_TAINT_VALUE=yes OKD_PVE_INFRA_TAINT_EFFECTS="NoSchedule NoExecute" \
		run infra_tolerations_json
	assert_output '[{"key":"example.com/infra","operator":"Equal","value":"yes","effect":"NoSchedule"},{"key":"example.com/infra","operator":"Equal","value":"yes","effect":"NoExecute"}]'
}

@test "cluster_operators_not_ready lists degraded, progressing and unavailable operators" {
	oc() {
		cat <<'JSON'
{"items":[
 {"metadata":{"name":"ok"},"status":{"conditions":[{"type":"Available","status":"True"},{"type":"Degraded","status":"False"},{"type":"Progressing","status":"False"}]}},
 {"metadata":{"name":"degraded"},"status":{"conditions":[{"type":"Available","status":"True"},{"type":"Degraded","status":"True"}]}},
 {"metadata":{"name":"progressing"},"status":{"conditions":[{"type":"Available","status":"True"},{"type":"Progressing","status":"True"}]}},
 {"metadata":{"name":"unavailable"},"status":{"conditions":[{"type":"Available","status":"False"}]}}]}
JSON
	}
	run cluster_operators_not_ready
	assert_output $'degraded\nprogressing\nunavailable'
}

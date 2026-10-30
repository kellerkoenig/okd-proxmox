# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Shared setup for the bats tests. Proxmox API and oc are mocked; nothing
# here talks to a real system.

bats_load_library bats-support
bats_load_library bats-assert

OKD_PVE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
export OKD_PVE_ROOT
TEST_TOKEN='terraform-okd@pve!okd=11111111-2222-3333-4444-555555555555'
TEST_TOKEN_SECRET='11111111-2222-3333-4444-555555555555'

# load_libs: source the libraries into the test shell.
load_libs() {
	set +u
	local l
	for l in common versions config state tools proxmox manifests preflight terraform installer oclib catalog nodes hooks verify storage; do
		# shellcheck disable=SC1090
		source "${OKD_PVE_ROOT}/lib/${l}.sh"
	done
	OKD_PVE_TMP=${BATS_TEST_TMPDIR}/tmp
	mkdir -p "${OKD_PVE_TMP}"
	NO_COLOR=1
	setup_colors
}

# make_cluster <example>: copy an example into a temp cluster dir and load it.
make_cluster() {
	local src=${OKD_PVE_ROOT}/examples/$1
	CLUSTER=${BATS_TEST_TMPDIR}/cluster
	rm -rf "${CLUSTER}"
	mkdir -p "${CLUSTER}"
	cp "${src}/cluster.yaml" "${src}/install-config.yaml" "${CLUSTER}/"
	mkdir -p "${BATS_TEST_TMPDIR}/home/.ssh"
	echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBATSBATSBATSBATSBATSBATSBATSBATSBATSBATS test@example.com" \
		>"${BATS_TEST_TMPDIR}/home/.ssh/id_ed25519.pub"
	export HOME=${BATS_TEST_TMPDIR}/home
	CONFIG_FILE=''
	if declare -F set_cluster_paths >/dev/null; then set_cluster_paths "${CLUSTER}"; fi
}

# load_cluster: config_load + nodes for the current CLUSTER.
load_cluster() {
	config_load
	nodes_invalidate
}

# yq_set <expression> [file]: modify cluster.yaml (default) in place.
yq_set() {
	yq -i "$1" "${2:-${CLUSTER}/cluster.yaml}"
}

# write_proxmox_conf [mode]
write_proxmox_conf() {
	cat >"${CLUSTER}/proxmox.conf" <<CONF
PROXMOX_VE_ENDPOINT="https://pve.example.com:8006/"
PROXMOX_VE_API_TOKEN="${TEST_TOKEN}"
PROXMOX_VE_INSECURE="false"
CONF
	chmod "${1:-600}" "${CLUSTER}/proxmox.conf"
}

use_mocks() {
	export PATH="${OKD_PVE_ROOT}/test/mocks:${PATH}"
	export MOCK_PVE_FIXTURES=${OKD_PVE_ROOT}/test/fixtures/pve
	export MOCK_LOG=${BATS_TEST_TMPDIR}/mock.log
}

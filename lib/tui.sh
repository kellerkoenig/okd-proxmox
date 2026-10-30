# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Text user interface. A thin wrapper: it only collects input and runs the
# same okd-pve CLI commands (shown before they run), so everything possible
# here is possible headless as well. No business logic lives in this file.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_TUI_LOADED:-} ]] && return 0
_OKD_PVE_TUI_LOADED=1

TUI_BIN=''
TUI_DIR=''

tui_detect() {
	if have_cmd whiptail; then
		TUI_BIN=whiptail
	elif have_cmd dialog; then
		TUI_BIN=dialog
	else
		die "${EXIT_ERROR}" "Neither whiptail nor dialog is installed." \
			"Install whiptail (newt) or dialog, or use the CLI commands directly (okd-pve help)."
	fi
}

# _tui <whiptail/dialog args...>: result on stdout, returns the box status.
_tui() {
	local out rc=0
	out=$("${TUI_BIN}" --title "okd-pve ${TUI_DIR:+[${TUI_DIR}]}" "$@" 3>&1 1>&2 2>&3) || rc=$?
	printf '%s' "${out}"
	return "${rc}"
}

tui_input() {
	_tui --inputbox "$1" 10 70 "${2:-}"
}

tui_yesno() {
	"${TUI_BIN}" --title "okd-pve" --yesno "$1" 10 70
}

tui_msg() {
	"${TUI_BIN}" --title "okd-pve" --msgbox "$1" 12 70
}

# tui_clear: clear fails on terminals without that capability (TERM=dumb);
# that must not end the TUI.
tui_clear() {
	clear 2>/dev/null || true
}

# tui_run <args...>: run an okd-pve command in the terminal, then wait.
tui_run() {
	local -a argv=("${OKD_PVE_ROOT}/okd-pve")
	[[ -n ${TUI_DIR} ]] && argv+=(--dir "${TUI_DIR}")
	((ASSUME_YES)) && argv+=(--yes)
	((DEBUG)) && argv+=(--debug)
	argv+=("$@")
	tui_clear
	printf '$ %s\n\n' "${argv[*]}"
	local rc=0
	# Ctrl-C belongs to the command: it stops it (or ends a log view) and
	# the TUI returns to the menu. A no-op trap, not an ignored signal: an
	# ignored SIGINT would be inherited and the command could not be stopped.
	trap ':' INT
	"${argv[@]}" || rc=$?
	trap _on_interrupt INT
	printf '\n[exit code %s] Press Enter to return to the menu. ' "${rc}"
	read -r _
}

tui_pick_dir() {
	local -a items=()
	local d
	for d in ./clusters/*/; do
		[[ -f ${d}cluster.yaml ]] && items+=("${d%/}" "")
	done
	if ((${#items[@]} == 0)); then
		TUI_DIR=$(tui_input "Cluster directory (contains cluster.yaml):" "${TUI_DIR:-./clusters/}") || return 0
		return 0
	fi
	items+=(other "enter a path")
	local choice
	choice=$(_tui --menu "Select the cluster directory" 20 70 10 "${items[@]}") || return 0
	if [[ ${choice} == other ]]; then
		TUI_DIR=$(tui_input "Cluster directory:" "${TUI_DIR}") || return 0
	else
		TUI_DIR=${choice}
	fi
}

tui_node_add() {
	local role count
	role=$(_tui --menu "Role of the new nodes" 12 60 2 worker "application workloads" infra "ingress, monitoring, registry") || return 0
	count=$(tui_input "Number of ${role} nodes to add:" 1) || return 0
	tui_run node add --role "${role}" --count "${count}"
}

tui_node_remove() {
	local name
	name=$(tui_input "Name of the node to remove (see 'Nodes'):") || return 0
	[[ -n ${name} ]] || return 0
	tui_yesno "Cordon, drain and delete ${name} including its VM and disks?" || return 0
	tui_run --yes node remove "${name}"
}

tui_hooks_run() {
	local name
	name=$(tui_input "Hook to run (empty = all hooks):") || return 0
	if [[ -n ${name} ]]; then
		tui_run hooks run "${name}"
	else
		tui_run hooks run
	fi
}

tui_init() {
	local name dir
	name=$(tui_input "Name of the new cluster (lowercase, digits, dashes):") || return 0
	[[ -n ${name} ]] || return 0
	dir=$(tui_input "Directory for the configuration:" "./clusters/${name}") || return 0
	tui_clear
	"${OKD_PVE_ROOT}/okd-pve" init "${name}" --dir "${dir}" || true
	TUI_DIR=${dir}
	printf '\nPress Enter to continue. '
	read -r _
}

tui_main() {
	tui_detect
	TUI_DIR=${DIR_FLAG:-}
	[[ -n ${TUI_DIR} || -f ./cluster.yaml ]] || tui_pick_dir
	local choice
	while :; do
		choice=$(_tui --menu "Choose an action" 24 78 16 \
			dir "Select cluster directory" \
			init "Create a new cluster configuration" \
			preflight "Run preflight checks (changes nothing)" \
			dry-run "Show what create would do" \
			create "Create / continue creating the cluster" \
			verify "Check cluster health" \
			nodes "List nodes" \
			node-add "Add worker or infra nodes" \
			node-remove "Remove a node" \
			reconcile "Re-apply infra labels and taints" \
			storage "Install the storage backend" \
			hooks "List Post-Install hooks" \
			hooks-run "Run Post-Install hooks" \
			kubeconfig "Show the kubeconfig path" \
			logs "Show the latest log" \
			logs-follow "Follow the log, also of later runs (Ctrl-C: back)" \
			destroy "Destroy the cluster" \
			quit "Exit") || break
		case ${choice} in
		dir) tui_pick_dir ;;
		init) tui_init ;;
		preflight) tui_run preflight ;;
		dry-run) tui_run --dry-run create ;;
		create) tui_yesno "Create (or continue creating) the cluster now?" && tui_run create ;;
		verify) tui_run verify ;;
		nodes) tui_run node list ;;
		node-add) tui_node_add ;;
		node-remove) tui_node_remove ;;
		reconcile) tui_run node reconcile ;;
		storage) tui_run storage install ;;
		hooks) tui_run hooks list ;;
		hooks-run) tui_hooks_run ;;
		kubeconfig) tui_run kubeconfig --export ;;
		logs) tui_run logs ;;
		logs-follow) tui_run logs -f ;;
		destroy) tui_yesno "Really destroy the cluster? You will be asked to type its name." && tui_run destroy ;;
		quit) break ;;
		esac
	done
	tui_clear
}

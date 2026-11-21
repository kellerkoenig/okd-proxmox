#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Entrypoint of the container image: run okd-pve as the owner of the mounted
# /work directory, so every file it writes there (state, logs, kubeconfig,
# backups) belongs to you on the host.
#
# - docker (rootful): the container starts as root, /work belongs to your
#   uid: a user with that uid is created and okd-pve runs as that user.
# - podman (rootless): root in the container is your user on the host and
#   /work appears as owned by root: okd-pve runs as root.
#
# HOME is /home/okd-pve in both cases; mount ~/.ssh to /home/okd-pve/.ssh.
set -euo pipefail

home=/home/okd-pve
uid=$(stat -c %u /work)
gid=$(stat -c %g /work)
export HOME=${home}

if [[ $(id -u) == 0 && ${uid} != 0 ]]; then
	getent group "${gid}" >/dev/null || groupadd -g "${gid}" okd-pve
	getent passwd "${uid}" >/dev/null || useradd -u "${uid}" -g "${gid}" -d "${home}" -M -s /bin/bash okd-pve
	mkdir -p "${home}"
	chown "${uid}:${gid}" "${home}"
	exec setpriv --reuid "${uid}" --regid "${gid}" --clear-groups /opt/okd-pve/okd-pve "$@"
fi
mkdir -p "${home}" 2>/dev/null || true
exec /opt/okd-pve/okd-pve "$@"

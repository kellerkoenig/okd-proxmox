# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# okd-pve with every tool it needs (yq, jq, nmstatectl, ssh, whiptail, ...),
# so nothing has to be installed on the workstation. oc, openshift-install,
# tofu and butane match the cluster's versions; okd-pve downloads them into
# <cluster>/bin on first use, as without the container.
#
#   docker run --rm -it -v "$PWD:/work:Z" -v "$HOME/.ssh:/home/okd-pve/.ssh:ro,Z" \
#     ghcr.io/kellerkoenig/okd-proxmox:<version> --dir clusters/lab create
#
# The same with podman. /work is the directory with clusters/; okd-pve runs as
# its owner (scripts/container-entrypoint.sh, docs/container.md).
FROM quay.io/centos/centos:stream9@sha256:875f628a88425be59d5edf2aa81e9836dd803de564ce3f728f23c63660d65662

# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=4.54.1
# SHA256 of yq_linux_amd64 from the release's checksums-bsd file; update it
# together with YQ_VERSION.
ARG YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f

RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
		bind-utils diffutils findutils gzip hostname iputils jq newt nmstate \
		openssh-clients procps-ng shadow-utils tar unzip util-linux which \
	&& dnf clean all \
	&& rm -rf /var/cache/dnf \
	&& curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
	&& echo "${YQ_SHA256}  /usr/local/bin/yq" | sha256sum -c - \
	&& chmod 755 /usr/local/bin/yq

COPY LICENSE README.md okd-pve /opt/okd-pve/
COPY LICENSES /opt/okd-pve/LICENSES
COPY docs /opt/okd-pve/docs
COPY examples /opt/okd-pve/examples
COPY hooks /opt/okd-pve/hooks
COPY lib /opt/okd-pve/lib
COPY templates /opt/okd-pve/templates
COPY terraform /opt/okd-pve/terraform
COPY scripts/container-entrypoint.sh /opt/okd-pve/container-entrypoint.sh

# Caches (base ISO, OpenTofu providers) stay in the mounted directory
# unless cluster.yaml sets proxmox.cache_dir.
ENV XDG_CACHE_HOME=/work/.cache \
	OKD_PVE_CONTAINER=1
WORKDIR /work
ENTRYPOINT ["/opt/okd-pve/container-entrypoint.sh"]
CMD ["help"]

ARG OKD_PVE_VERSION=dev
LABEL org.opencontainers.image.title="okd-pve" \
	org.opencontainers.image.description="OKD clusters on Proxmox VE with the agent-based installer and OpenTofu" \
	org.opencontainers.image.source="https://github.com/kellerkoenig/okd-proxmox" \
	org.opencontainers.image.licenses="AGPL-3.0-or-later" \
	org.opencontainers.image.version="${OKD_PVE_VERSION}"

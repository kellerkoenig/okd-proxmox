# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Development tasks. `make tools` installs pinned linters/test tools into
# .tools/ (nothing system-wide); every other target uses them from there.

TOOLS := $(CURDIR)/.tools
export PATH := $(TOOLS)/bin:$(PATH)
export BATS_LIB_PATH := $(TOOLS)

SHELL_FILES := okd-pve $(wildcard lib/*.sh) $(wildcard hooks/*.sh) $(wildcard scripts/*.sh) $(shell find test/mocks -type f)
EXAMPLE_HOOKS := $(wildcard hooks/*.example)

# "# renovate:" comments let Renovate propose updates (.github/renovate.json5).
# renovate: datasource=github-releases depName=mvdan/sh
SHFMT_VERSION   := 3.14.1
# renovate: datasource=github-releases depName=mikefarah/yq
YQ_VERSION      := 4.54.1
# renovate: datasource=github-releases depName=coreos/butane
BUTANE_VERSION  := 0.29.0
# renovate: datasource=github-releases depName=opentofu/opentofu
TOFU_VERSION    := 1.13.2
# renovate: datasource=github-releases depName=terraform-linters/tflint
TFLINT_VERSION  := 0.64.0
# renovate: datasource=github-tags depName=bats-core/bats-core
BATS_VERSION    := 1.14.0
# renovate: datasource=github-tags depName=bats-core/bats-support
BATS_SUPPORT_VERSION := 0.3.0
# renovate: datasource=github-tags depName=bats-core/bats-assert
BATS_ASSERT_VERSION  := 2.2.4

.PHONY: all check lint fmt fmt-fix test terraform leakcheck tools clean-tools

all: check

check: lint fmt test terraform leakcheck

lint:
	shellcheck -x $(SHELL_FILES) $(EXAMPLE_HOOKS)

fmt:
	shfmt -d -ln bash $(SHELL_FILES) $(EXAMPLE_HOOKS)

fmt-fix:
	shfmt -w -ln bash $(SHELL_FILES) $(EXAMPLE_HOOKS)

test:
	bats test/

terraform:
	tofu -chdir=terraform fmt -check -diff
	tofu -chdir=terraform init -backend=false -input=false >/dev/null
	tofu -chdir=terraform validate
	cd terraform && tflint --init >/dev/null && tflint
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl

leakcheck:
	scripts/check-leaks.sh

tools:
	mkdir -p $(TOOLS)/bin
	curl -fsSL -o $(TOOLS)/bin/shfmt https://github.com/mvdan/sh/releases/download/v$(SHFMT_VERSION)/shfmt_v$(SHFMT_VERSION)_linux_amd64
	curl -fsSL -o $(TOOLS)/bin/yq https://github.com/mikefarah/yq/releases/download/v$(YQ_VERSION)/yq_linux_amd64
	curl -fsSL -o $(TOOLS)/bin/butane https://github.com/coreos/butane/releases/download/v$(BUTANE_VERSION)/butane-x86_64-unknown-linux-gnu
	curl -fsSL -o $(TOOLS)/tofu.zip https://github.com/opentofu/opentofu/releases/download/v$(TOFU_VERSION)/tofu_$(TOFU_VERSION)_linux_amd64.zip
	unzip -qo $(TOOLS)/tofu.zip tofu -d $(TOOLS)/bin && rm $(TOOLS)/tofu.zip
	curl -fsSL -o $(TOOLS)/tflint.zip https://github.com/terraform-linters/tflint/releases/download/v$(TFLINT_VERSION)/tflint_linux_amd64.zip
	unzip -qo $(TOOLS)/tflint.zip -d $(TOOLS)/bin && rm $(TOOLS)/tflint.zip
	for r in bats-core:$(BATS_VERSION) bats-support:$(BATS_SUPPORT_VERSION) bats-assert:$(BATS_ASSERT_VERSION); do \
		n=$${r%%:*}; v=$${r##*:}; mkdir -p $(TOOLS)/$$n; \
		curl -fsSL https://github.com/bats-core/$$n/archive/refs/tags/v$$v.tar.gz | tar xz --strip-components=1 -C $(TOOLS)/$$n; \
	done
	ln -sf ../bats-core/bin/bats $(TOOLS)/bin/bats
	chmod +x $(TOOLS)/bin/*

clean-tools:
	rm -rf $(TOOLS)

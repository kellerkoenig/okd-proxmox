# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Static validation of cluster.yaml (merged with defaults) and its relation
# to install-config.yaml. Produces {"errors": [...], "warnings": [...]}.

include "nodes";

def when(cond; msg): if cond then [msg] else [] end;

def dns_label: type == "string" and test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$");

def valid_hostname:
  type == "string" and length <= 253
  and (split(".") | all(test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")));

def hexval: ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1];

def okd_version_ok:
  (try (capture("^(?<maj>[0-9]+)\\.(?<min>[0-9]+)") | (.maj | tonumber) as $a | (.min | tonumber) as $b
        | ($a > 4 or ($a == 4 and $b >= 17))) catch false);

def group_errors($c):
  . as $g
  | when(($g.name | dns_label) | not; "node_groups: name \"\($g.name)\" must be a lowercase DNS label")
  + when(($g.roles | type) != "array" or ($g.roles | length) == 0;
      "node_groups.\($g.name).roles must be a non-empty list, e.g. [\"worker\"]")
  + when(($g.roles // []) - ["master", "worker", "infra"] | length > 0;
      "node_groups.\($g.name).roles: unknown role(s) \(($g.roles // []) - ["master", "worker", "infra"] | join(", ")); allowed: master, worker, infra")
  + when(($g | is_master_group) and (($g.roles | length) > 1);
      "node_groups.\($g.name): the master role cannot be combined with other roles")
  + when(($g.count | type) != "number" or $g.count < 0 or ($g.count | floor) != $g.count;
      "node_groups.\($g.name).count must be a non-negative integer")
  + when(($g.cpu | type) != "number" or $g.cpu < (if $g | is_master_group then 4 else 2 end);
      "node_groups.\($g.name).cpu must be at least \(if $g | is_master_group then 4 else 2 end) (installer hardware validation)")
  + when(($g.memory_gib | type) != "number" or $g.memory_gib < (if $g | is_master_group then 16 else 8 end);
      "node_groups.\($g.name).memory_gib must be at least \(if $g | is_master_group then 16 else 8 end) (installer hardware validation)")
  + when(($g.disk_gib | type) != "number" or $g.disk_gib < 100;
      "node_groups.\($g.name).disk_gib must be at least 100 (installer hardware validation)")
  + when(($g.taint_infra != null) and (($g.taint_infra | type) != "boolean");
      "node_groups.\($g.name).taint_infra must be true or false")
  + when(($g.taint_infra == true) and ($g | has_role("infra") | not);
      "node_groups.\($g.name).taint_infra is set but the group has no infra role")
  + [($g.data_disks // [])[] | select(((if type == "object" then .size_gib else . end) | type) != "number")
     | "node_groups.\($g.name).data_disks: every entry needs a size in GiB (number or {size_gib: N})"]
  + [($g.ips // [])[] | tostring | select(test("-") | not) | select(is_ipv4 | not)
     | "node_groups.\($g.name).ips: \"\(.)\" is not an IPv4 address"]
  + [($g.ips // [])[] | tostring | select(test("-")) | select(split("-") | all(is_ipv4) | not)
     | "node_groups.\($g.name).ips: \"\(.)\" is not a valid range (a.b.c.d-a.b.c.e)"]
  + when(($g.ips // [] | expand_ips | length) < ($g.count // 0);
      "node_groups.\($g.name): \($g.count) nodes but only \($g.ips // [] | expand_ips | length) IP addresses in ips")
  + when((($g.proxmox_nodes // $c.proxmox.nodes) | length) == 0;
      "node_groups.\($g.name): no Proxmox target node (set proxmox.nodes)");

def group_warnings($c):
  . as $g
  | when(($g | is_combined_infra) and ($g | taint_infra_effective);
      "node_groups.\($g.name) combines roles \($g.roles | join("+")) with taint_infra: true. With the taint these nodes are effectively dedicated infra nodes: workloads without a toleration will not schedule there, the worker label does not change that. Set taint_infra: false or use a dedicated infra group.")
  + when(($g | is_combined_infra) and ($g.memory_gib // 0) < $c.infra.combined_min_memory_gib;
      "node_groups.\($g.name) combines worker and infra with only \($g.memory_gib) GiB RAM (recommended >= \($c.infra.combined_min_memory_gib) GiB). Prometheus and the ingress routers share memory with applications, the OOM killer may hit monitoring.");

# registry host with optional port and path; a source may start with "*.".
def registry_ref: type == "string" and test("^(\\*\\.)?[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9._/-]*[a-z0-9])?$");
def mirror_ref: type == "string" and test("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9._/-]*[a-z0-9])?$");

def mirrors_errors($c; $ic):
  ($c.registry_mirrors // {}) as $m
  | ($m.registries // []) as $r
  | when(($m.fallback | type) != "boolean"; "registry_mirrors.fallback must be true or false")
  + when(($m.auth_file | type) != "string"; "registry_mirrors.auth_file must be a file path")
  + [("username", "password") as $k | select(($m[$k] | type) != "string")
     | "registry_mirrors.\($k) must be a string (\"\" = none)"]
  + if ($r | type) != "array" then ["registry_mirrors.registries must be a list of {source, mirror}"]
    else
      [$r[] | select(type != "object") | "registry_mirrors.registries: every entry needs source and mirror"]
      + [$r[] | objects | select(.source | registry_ref | not)
         | "registry_mirrors.registries: source \(.source | tojson) must be a registry host with optional port and path, without https:// (e.g. quay.io or quay.io/okd)"]
      + [$r[] | objects | select(.mirror | mirror_ref | not)
         | "registry_mirrors.registries: mirror \(.mirror | tojson) of \(.source) must be a host with optional port and path, without https:// (e.g. quay-cache.example.com)"]
      + [$r[] | objects | select(.fallback != null and (.fallback | type) != "boolean")
         | "registry_mirrors.registries: fallback of \(.source) must be true or false"]
      + [$r[] | objects | . as $e | ("username", "password") as $k
         | select($e[$k] != null and ($e[$k] | type) != "string")
         | "registry_mirrors.registries: \($k) of \($e.source) must be a string"]
      + [$r | map(objects | .source) | group_by(.)[] | select(length > 1)
         | "registry_mirrors.registries: source \(.[0]) is listed more than once"]
      + [$r[] | objects | .source as $s | select(any(($ic.imageDigestSources // [])[]; .source == $s))
         | "registry_mirrors.registries: source \($s) is also in imageDigestSources of install-config.yaml; configure it in one place"]
    end;

def validate($cluster; $inventory; $ic):
  . as $c
  | ($c.node_groups // []) as $groups
  | ([$groups[] | select(is_master_group)]) as $mgroups
  | (
      when(($c.okd.version // "") == ""; "okd.version is required (an OKD release tag such as 4.21.0-okd-scos.11)")
    + when((($c.okd.version // "") != "") and (($c.okd.version | okd_version_ok) | not);
        "okd.version \($c.okd.version) is not supported; the minimum is 4.17")
    + when(($c.proxmox.nodes | type) != "array" or ($c.proxmox.nodes | length) == 0;
        "proxmox.nodes must list at least one Proxmox node")
    + when(($c.proxmox.vm_storage // "") == ""; "proxmox.vm_storage is required")
    + when(($c.proxmox.iso_storage // "") == ""; "proxmox.iso_storage is required")
    + when(($c.proxmox.bridge // "") == ""; "proxmox.bridge is required")
    + when(($c.proxmox.vlan_tag | type) != "number" or $c.proxmox.vlan_tag < 0 or $c.proxmox.vlan_tag > 4094;
        "proxmox.vlan_tag must be 0 (untagged) or 1-4094")
    + when(($c.proxmox.vmid_start | type) != "number" or $c.proxmox.vmid_start < 100;
        "proxmox.vmid_start must be >= 100")
    + when(($c.proxmox.vmid_end | type) != "number" or $c.proxmox.vmid_end < ($c.proxmox.vmid_start // 0);
        "proxmox.vmid_end must be >= proxmox.vmid_start")
    + when(($c.proxmox.vmid_block | type) != "number" or $c.proxmox.vmid_block < 1;
        "proxmox.vmid_block must be a positive number")
    + when(($c.proxmox.mac_prefix | type) != "string"
           or ($c.proxmox.mac_prefix | test("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){1,3}$") | not);
        "proxmox.mac_prefix must be 2-4 bytes like \"02:00:00\"")
    + when(($c.proxmox.mac_prefix | type) == "string"
           and ($c.proxmox.mac_prefix | test("^[0-9A-Fa-f]{2}"))
           and (($c.proxmox.mac_prefix[0:2] | hexval) % 2 == 1);
        "proxmox.mac_prefix is a multicast address; use a unicast prefix such as 02:00:00")
    + when(([$c.proxmox.spread] - [true, false, "balanced"] | length) > 0; "proxmox.spread must be true, false or balanced")
    + when(([$c.proxmox.bios] - ["ovmf", "seabios"] | length) > 0; "proxmox.bios must be ovmf or seabios")
    + [("tmp_dir", "cache_dir") as $k | select(($c.proxmox[$k] | type) != "string")
       | "proxmox.\($k) must be a directory path (\"\" = default)"]
    + when(($c.proxmox.ha.enabled | type) != "boolean"; "proxmox.ha.enabled must be true or false")
    + when(($c.proxmox.guest_agent | type) != "boolean"; "proxmox.guest_agent must be true or false")
    + when(($c.install.debug_shell | type) != "boolean"; "install.debug_shell must be true or false")
    + when(([$c.proxmox.ha.max_restart, $c.proxmox.ha.max_relocate] | map(type == "number" and . >= 0 and . == floor) | all) | not;
        "proxmox.ha.max_restart and max_relocate must be whole numbers >= 0")
    + when(([$c.proxmox.root_device_hint] - ["serial", "none"] | length) > 0;
        "proxmox.root_device_hint must be serial or none")
    + when(($c.network.gateway | is_ipv4) | not; "network.gateway must be an IPv4 address")
    + when(($c.network.prefix_length | type) != "number" or $c.network.prefix_length < 1 or $c.network.prefix_length > 32;
        "network.prefix_length must be 1-32")
    + when(($c.network.dns_servers | type) != "array" or ($c.network.dns_servers | length) == 0
           or ($c.network.dns_servers | all(is_ipv4) | not);
        "network.dns_servers must list at least one IPv4 address")
    + when(($c.network.ntp_servers | type) != "array" or ($c.network.ntp_servers | length) == 0;
        "network.ntp_servers must list at least one NTP server")
    + when(($c.network.rendezvous_ip | is_ipv4) | not; "network.rendezvous_ip must be an IPv4 address")
    + when(($c.network.interface // "") == ""; "network.interface is required (usually ens18 on Proxmox)")
    + when(($groups | length) == 0; "node_groups must define at least one group")
    + when(($mgroups | length) != 1; "exactly one node group must carry the master role")
    + when(($groups | map(.name) | length) != ($groups | map(.name) | unique | length); "node_groups: names must be unique")
    + ([$c.infra.taint_effects[]? | select(. as $e | ["NoSchedule", "PreferNoSchedule", "NoExecute"] | index($e) | not)
        | "infra.taint_effects: \(.) is not a valid taint effect"])
    + when(($c.hostname_format | type) != "string"
           or ($c.hostname_format | test("\\{group\\}") and test("\\{index\\}") | not);
        "hostname_format must contain {group} and {index} (e.g. \"{cluster}-{group}-{index}\")")
    + when(([$c.storage.backend] - ["none", "proxmox-csi", "ceph-external", "lso", "nfs"] | length) > 0;
        "storage.backend must be one of none, proxmox-csi, ceph-external, lso, nfs")
    + ([$groups[] | group_errors($c)] | add // [])
    + mirrors_errors($c; $ic)
    ) as $basic
  | if ($basic | length) > 0 then {errors: $basic, warnings: []}
    else
      ($c | nodes($cluster; $inventory)) as $nodes
      | ([$nodes[] | select(.agent_role == "master")] | length) as $masters
      | ($ic.networking.machineNetwork // [] | map(.cidr)) as $mnets
      | (
          when(($mgroups[0].count != 1) and ($mgroups[0].count != 3);
            "the master group must have 1 or 3 nodes (has \($mgroups[0].count))")
        + [$nodes[] | select(.vmid > $c.proxmox.vmid_end)
           | "\(.name): VMID \(.vmid) is outside proxmox.vmid_start..vmid_end (\($c.proxmox.vmid_start)-\($c.proxmox.vmid_end)); raise vmid_end or lower vmid_block"]
        + [$groups | to_entries[] | .key as $gi | .value as $g
           | select(((($inventory // {})[$g.name] // [range(0; $g.count)]) | max // -1) >= $c.proxmox.vmid_block and $g.vmid_offset == null)
           | "node_groups.\($g.name): node index exceeds proxmox.vmid_block (\($c.proxmox.vmid_block)); VMIDs would collide with the next group"]
        + [$nodes | group_by(.vmid)[] | select(length > 1) | "VMID \(.[0].vmid) is used by \(map(.name) | join(" and "))"]
        + [$nodes[] | select(.vmid >= mac_capacity($c.proxmox.mac_prefix))
           | "\(.name): VMID \(.vmid) does not fit into the MAC address bytes after proxmox.mac_prefix; use a shorter prefix"]
        + [$nodes[] | select(.ip == null) | "\(.name): no IP address left in node_groups.\(.group).ips"]
        + [$nodes | map(select(.ip != null)) | group_by(.ip)[] | select(length > 1) | "IP \(.[0].ip) is assigned to \(map(.name) | join(" and "))"]
        + [$nodes[] | select(.name | valid_hostname | not)
           | "\(.name): not a valid hostname (lowercase letters, digits, dashes, dots; labels up to 63, total up to 253 characters); check hostname_format"]
        + [$nodes | group_by(.name)[] | select(length > 1)
           | "hostname \(.[0].name) is used by several nodes; hostname_format must contain {group} and {index}"]
        + when(([$nodes[] | select(.agent_role == "master" and .ip == $c.network.rendezvous_ip)] | length) == 0;
            "network.rendezvous_ip \($c.network.rendezvous_ip) must be the IP of a control-plane node")
        + (if ($mnets | length) > 0 then
             [$nodes[] | select(.ip != null) | select(.ip as $ip | $mnets | any(. as $n | $ip | in_cidr($n)) | not)
              | "\(.name): IP \(.ip) is not inside networking.machineNetwork (\($mnets | join(", ")))"]
           else [] end)
        ) as $errs
      | {
          errors: $errs,
          warnings: (([$groups[] | group_warnings($c)] | add // [])
            + when(($masters == 1) and (([$nodes[] | select(.agent_role == "worker")] | length) > 0);
                "single-node cluster with additional nodes: the agent installer requires 0 workers at install time; add workers later with node add"))
        }
    end;

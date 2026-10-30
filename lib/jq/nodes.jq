# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Node model: derives every VM (name, VMID, MAC, IP, disk serials, target
# host) deterministically from cluster.yaml and the slot inventory.

def ip2int:
  split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];

def int2ip:
  [(. / 16777216 | floor) % 256, (. / 65536 | floor) % 256, (. / 256 | floor) % 256, . % 256]
  | map(tostring) | join(".");

def is_ipv4:
  type == "string"
  and test("^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$");

# in_cidr($cidr): true if the IPv4 address (input) lies inside $cidr.
def in_cidr($cidr):
  ($cidr | split("/")) as [$net, $len]
  | ($len | tonumber) as $l
  | pow(2; 32 - $l) as $size
  | ((ip2int / $size | floor) == ($net | ip2int / $size | floor));

# Expand ["192.0.2.10", "192.0.2.20-192.0.2.22"] into single addresses.
def expand_ips:
  [.[]? | tostring
   | if test("-") then (split("-") | map(ip2int)) as [$a, $b] | range($a; $b + 1) | int2ip
     else . end];

def hex2:
  . as $n | "0123456789abcdef" as $h
  | $h[($n / 16 | floor):($n / 16 | floor) + 1] + $h[($n % 16):($n % 16) + 1];

# MAC = configured prefix (2-4 bytes) followed by the VMID in the remaining
# bytes, big endian. Stable across rebuilds because the VMID is.
def mac_for($prefix; $vmid):
  ($prefix | ascii_downcase | split(":")) as $p
  | (6 - ($p | length)) as $nb
  | $p + [range($nb - 1; -1; -1) as $i | ($vmid / pow(256; $i) | floor) % 256 | hex2]
  | join(":");

def mac_capacity($prefix):
  pow(256; 6 - ($prefix | split(":") | length));

# Proxmox limits disk serials to 20 characters.
def serial_for($vmid; $n):
  "okd\($vmid)d\($n)";

def has_role($r):
  (.roles // []) | index($r) != null;

def is_master_group: has_role("master");
def is_dedicated_infra: ((.roles // []) | sort) == ["infra"];
def is_combined_infra: has_role("infra") and ((.roles // []) | length) > 1;

def taint_infra_effective:
  has_role("infra") and (if .taint_infra == null then is_dedicated_infra else .taint_infra end);

def default_inventory:
  [.node_groups[]? | {key: .name, value: [range(0; .count // 0)]}] | from_entries;

def vmid_offset($gi; $c):
  .vmid_offset // ($gi * $c.proxmox.vmid_block);

# hostname($c; $cluster; $group; $index): hostname_format with
# {cluster}, {group}, {index} and {domain} replaced. The result is hostname,
# Kubernetes node name and Proxmox VM name.
def hostname($c; $cluster; $group; $index):
  ($c.hostname_format // "{cluster}-{group}-{index}")
  | gsub("\\{cluster\\}"; $cluster)
  | gsub("\\{group\\}"; $group)
  | gsub("\\{index\\}"; $index | tostring)
  | gsub("\\{domain\\}"; $c.cluster_meta.base_domain // "");

# nodes($cluster; $inventory): input is the merged cluster.yaml.
def nodes($cluster; $inventory):
  . as $c
  | ($inventory // ($c | default_inventory)) as $inv
  | [$c.node_groups | to_entries[] | .key as $gi | .value as $g
     | ($g.proxmox_nodes // $c.proxmox.nodes) as $hosts
     | ($g.ips // [] | expand_ips) as $ips
     | ($g | vmid_offset($gi; $c)) as $off
     | ($inv[$g.name] // [])[] as $idx
     | ($c.proxmox.vmid_start + $off + $idx) as $vmid
     | {
         name: hostname($c; $cluster; $g.name; $idx),
         group: $g.name,
         index: $idx,
         roles: $g.roles,
         agent_role: (if ($g | is_master_group) then "master" else "worker" end),
         infra: ($g | has_role("infra")),
         dedicated_infra: ($g | is_dedicated_infra),
         taint_infra: ($g | taint_infra_effective),
         vmid: $vmid,
         mac: mac_for($c.proxmox.mac_prefix; $vmid),
         ip: $ips[$idx],
         host: (if ($hosts | length) == 0 then null
                elif $c.proxmox.spread then $hosts[$idx % ($hosts | length)]
                else $hosts[0] end),
         cpu: $g.cpu,
         memory_mib: ($g.memory_gib * 1024),
         disk_gib: $g.disk_gib,
         boot_serial: serial_for($vmid; 0),
         data_disks: [($g.data_disks // []) | to_entries[] | {
           size_gib: (if (.value | type) == "object" then .value.size_gib else .value end),
           storage: (if (.value | type) == "object" then (.value.storage // $c.proxmox.vm_storage)
                     else $c.proxmox.vm_storage end),
           serial: serial_for($vmid; .key + 1)
         }]
       }]
  | sort_by(.vmid);

# Pool layout: a dedicated infra MachineConfigPool is only created when every
# group carrying the infra role is dedicated. A node matching two custom pools
# goes Degraded, so combined worker/infra nodes stay in the worker pool.
def infra_pool_enabled:
  ([.node_groups[]? | select(has_role("infra"))]) as $infra
  | ($infra | length) > 0 and ($infra | all(is_dedicated_infra));

# agent_host($c): one host entry for agent-config.yaml / nodes-config.yaml
# (static IPv4 via nmstate, MAC binding, root device hint by disk serial).
def agent_host($c):
  {
    hostname: .name,
    interfaces: [{name: $c.network.interface, macAddress: .mac}],
    networkConfig: {
      interfaces: [{
        name: $c.network.interface,
        type: "ethernet",
        state: "up",
        "mac-address": .mac,
        ipv4: {enabled: true, dhcp: false, address: [{ip: .ip, "prefix-length": $c.network.prefix_length}]},
        ipv6: {enabled: false}
      }],
      "dns-resolver": {config: {server: $c.network.dns_servers}},
      routes: {config: [{
        destination: "0.0.0.0/0",
        "next-hop-address": $c.network.gateway,
        "next-hop-interface": $c.network.interface,
        "table-id": 254
      }]}
    }
  }
  + (if $c.proxmox.root_device_hint == "serial" then {rootDeviceHints: {serialNumber: .boot_serial}} else {} end);

# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors

output "nodes" {
  description = "Created VMs: hostname => {vmid, host, mac}."
  value = {
    for name, vm in proxmox_virtual_environment_vm.node : name => {
      vmid = vm.vm_id
      host = vm.node_name
      mac  = var.nodes[name].mac
    }
  }
}

output "isos" {
  description = "ISO volume IDs the VMs refer to (uploaded by okd-pve)."
  value       = { for k, iso in var.isos : k => "${var.iso_storage}:iso/${iso.file_name}" }
}

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
  description = "Uploaded ISO volume IDs."
  value       = { for k, f in proxmox_virtual_environment_file.iso : k => f.id }
}

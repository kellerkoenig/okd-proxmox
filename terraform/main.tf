# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# VMs for an OKD cluster installed with the agent-based installer.
#
# The ISO carries the Ignition configs, so no snippets, fw_cfg or `qm set
# --args` are needed: an API token without root@pam and without SSH access to
# the Proxmox nodes is enough.

locals {
  # One upload per ISO and target node, or a single upload when the ISO
  # storage is shared between nodes.
  iso_uploads = merge([
    for key, iso in var.isos : {
      for host in(var.iso_storage_shared ? [iso.hosts[0]] : distinct(iso.hosts)) :
      "${key}@${host}" => {
        key       = key
        host      = host
        path      = iso.path
        file_name = iso.file_name
      }
    }
  ]...)

  iso_upload_key = {
    for name, n in var.nodes :
    name => n.iso == "" ? "" : "${n.iso}@${var.iso_storage_shared ? var.isos[n.iso].hosts[0] : n.host}"
  }
}

resource "proxmox_virtual_environment_file" "iso" {
  for_each = local.iso_uploads

  content_type   = "iso"
  datastore_id   = var.iso_storage
  node_name      = each.value.host
  timeout_upload = var.upload_timeout

  source_file {
    path      = each.value.path
    file_name = each.value.file_name
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name        = each.key
  node_name   = each.value.host
  vm_id       = each.value.vmid
  pool_id     = var.pool_id
  description = "OKD cluster ${var.cluster_name}, roles: ${join(", ", each.value.roles)}. Managed by okd-pve."
  tags        = var.tags ? sort(distinct(concat(["okd", "okd-pve", var.cluster_name], each.value.roles))) : null

  bios          = var.bios
  machine       = var.machine
  scsi_hardware = "virtio-scsi-single"
  on_boot       = true
  started       = true

  # Never reboot cluster nodes because of a config change (e.g. ISO detach).
  reboot_after_update = false
  stop_on_destroy     = true

  # Disk first: the empty disk falls through to the ISO on first boot, and
  # after the installer has written the disk the node boots from it, even if
  # the ISO is still attached.
  boot_order = each.value.iso == "" ? ["scsi0"] : ["scsi0", "ide2"]

  # SCOS ships no qemu-guest-agent; enabling it makes apply wait until timeout.
  agent {
    enabled = false
  }

  cpu {
    sockets = 1
    cores   = each.value.cpu
    type    = var.cpu_type
  }

  # No ballooning: OKD nodes must see fixed memory.
  memory {
    dedicated = each.value.memory_mib
    floating  = 0
  }

  dynamic "efi_disk" {
    for_each = var.bios == "ovmf" ? [1] : []
    content {
      datastore_id      = var.efi_storage
      type              = "4m"
      pre_enrolled_keys = false
    }
  }

  # Boot disk. iothread + discard + no write cache: etcd is latency
  # sensitive, a misconfigured disk causes sporadic leader elections.
  disk {
    interface    = "scsi0"
    datastore_id = var.vm_storage
    size         = each.value.disk_gib
    file_format  = "raw"
    iothread     = true
    discard      = "on"
    ssd          = true
    cache        = "none"
    serial       = each.value.boot_serial
  }

  # Raw data disks for software-defined storage (LSO/ODF/Ceph). The stable
  # serial makes them appear as /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_<serial>.
  dynamic "disk" {
    for_each = { for i, d in each.value.data_disks : i => d }
    content {
      interface    = "scsi${disk.key + 1}"
      datastore_id = disk.value.storage
      size         = disk.value.size_gib
      file_format  = "raw"
      iothread     = true
      discard      = "on"
      ssd          = true
      cache        = "none"
      serial       = disk.value.serial
    }
  }

  cdrom {
    interface = "ide2"
    file_id   = each.value.iso == "" ? "none" : proxmox_virtual_environment_file.iso[local.iso_upload_key[each.key]].id
  }

  network_device {
    bridge      = var.bridge
    model       = "virtio"
    mac_address = each.value.mac
    vlan_id     = var.vlan_id > 0 ? var.vlan_id : null
    firewall    = false
  }

  # Serial console for boot diagnostics: qm terminal <vmid>.
  serial_device {
    device = "socket"
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [
      # Proxmox may report extra tags set by admins.
      description,
    ]
  }
}

# The HA manager restarts a VM on another node when its node fails. It is
# destroyed before its VM (dependency), so destroy and node remove keep
# working unchanged.
resource "proxmox_virtual_environment_haresource" "node" {
  for_each = var.ha.enabled ? var.nodes : {}

  resource_id  = "vm:${proxmox_virtual_environment_vm.node[each.key].vm_id}"
  state        = "started"
  max_restart  = var.ha.max_restart
  max_relocate = var.ha.max_relocate
  comment      = "OKD cluster ${var.cluster_name}. Managed by okd-pve."
}

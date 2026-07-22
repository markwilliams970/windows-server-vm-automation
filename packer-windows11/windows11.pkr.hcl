packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

# Windows 11 client build. Deliberately a separate directory/template from
# packer/windows-server.pkr.hcl (see this directory's variables.pkr.hcl for
# why - variable-name collisions with the Server template if combined into
# one Packer config directory).
#
# Rewritten to fully manually construct every -drive via qemuargs (main
# disk, both pflash UEFI files, both CD-ROMs, TPM), rather than relying on
# Packer's own iso_url/efi_firmware_*/cd_files native fields to auto-generate
# them - following a working reference (github.com/eb4x/packer-qemu-win11)
# after Windows 11's media hit the identical UEFI boot-key failure Server
# 2025 did (see packer/windows-server.pkr.hcl's Finding 15 pointer). Once
# ANY qemuargs entry uses "-drive", Packer replaces ALL of its own
# auto-generated -drive entries (Finding 2), so this can't be partial - if
# any drive is manual, they all have to be. This gives deterministic
# control over exactly what order OVMF's BDS sees devices in, which the
# native fields don't - plausibly the actual reason 2025/Windows 11 media
# fails this project's boot_command approach while Server 2022 never has.
#
# Two direct consequences of going fully manual:
#   - cd_files/cd_content can't be used: the merged driver+unattend ISO it
#     builds lands at a Packer-chosen temp path with no HCL-visible variable
#     to reference from qemuargs. floppy_content (just the small XML, well
#     within floppy's reliable size range per Finding 7/8) replaces it for
#     the answer file; the *raw, unmodified* virtio-win.iso is mounted
#     directly as a second CD-ROM instead of a curated cd_files subset.
#   - efi_firmware_vars stays a native field further down (not bypassed):
#     Packer's builder does its own internal efivars pre-flight handling
#     whenever efi_boot=true regardless of qemuargs, and it isn't optional -
#     omitting the field entirely made it fall back to a hardcoded internal
#     default path (/usr/share/OVMF/OVMF_VARS.fd) that doesn't exist on this
#     host, crashing before qemu even started. Confirmed live. Keeping the
#     native field lets Packer make its own normal per-build writable copy
#     at "<output_directory>/efivars.fd" (same convention the Server
#     template already relies on) - qemuargs' pflash unit=1 entry below just
#     points at that same resulting path instead of managing a separate copy.
#
# No sysprep/generalize in shutdown_command, same reasoning as Server: this
# produces one disposable, already-specialized VM disk, not a golden image.
source "qemu" "windows11" {
  vm_name          = "${var.vm_name}.qcow2"
  output_directory = "${path.root}/output/${var.vm_name}"

  # Still set so Packer's own schema validation/checksum verification runs
  # as a safety net, even though the actual boot-time attachment below is
  # manual - iso_target_path pins Packer's download-if-needed logic to the
  # exact same already-cached local file build-windows11.sh resolved, so it
  # never actually re-downloads.
  iso_url         = var.iso_url
  iso_checksum    = var.iso_checksum
  iso_target_path = var.iso_url_local_path

  headless = var.headless

  cpus      = var.cpus
  memory    = var.memory_size
  # disk_size still matters even though the main disk's -drive attachment
  # below is manual: Packer creates the actual backing qcow2 file (via its
  # own qemu-img create, sized by this field) as a separate pre-flight step
  # before it ever constructs the qemu invocation, so this isn't overridden
  # by qemuargs the way the -drive argument itself is.
  disk_size = var.disk_size

  accelerator  = "kvm"
  machine_type = "q35"
  format       = "qcow2"

  # disk_interface/net_device still drive Packer's own -device generation
  # (virtio-scsi-pci, scsi-hd, virtio-net) - only the -drive (backing store)
  # side is manual below.
  disk_interface = "virtio-scsi"
  net_device     = "virtio-net"

  # Required (not just for "other internal logic") - see the header comment
  # above on efi_firmware_vars. Packer copies this template to
  # "<output_directory>/efivars.fd" as its own pre-flight step; qemuargs
  # below references that exact resulting path.
  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars

  # index=N on both CD-ROM drives is load-bearing, not decoration: a
  # community-documented fix for the identical "no bootable device"/drops-
  # to-UEFI-shell symptom (Arch Linux forums bbs.archlinux.org/viewtopic.
  # php?id=212268, "[solved]") was exactly this - without an explicit index,
  # QEMU/OVMF's bus assignment for implicit-interface -drive entries can end
  # up ambiguous enough that BDS never enumerates them as boot candidates at
  # all. Confirmed live here too: omitting index produced OVMF's own
  # "BdsDxe: No bootable option or device was found", not even an attempt
  # to read the CD.
  qemuargs = [
    ["-drive", "if=pflash,unit=0,file=${var.efi_firmware_code},format=raw,readonly=on"],
    ["-drive", "if=pflash,unit=1,file=${path.root}/output/${var.vm_name}/efivars.fd,format=raw"],
    ["-drive", "if=none,id=drive0,file=${path.root}/output/${var.vm_name}/${var.vm_name}.qcow2,format=qcow2,cache=writeback,discard=ignore"],
    ["-drive", "media=cdrom,index=0,file=${var.iso_url_local_path}"],
    ["-drive", "media=cdrom,index=1,file=${var.virtio_iso_path}"],
    ["-chardev", "socket,id=chrtpm,path=${var.tpm_socket_path}"],
    ["-tpmdev", "emulator,id=tpm0,chardev=chrtpm"],
    ["-device", "tpm-crb,tpmdev=tpm0"],
  ]

  # Just the answer file - drivers now come from the raw virtio-win.iso CD-
  # ROM above instead of a cd_files-curated one, so floppy's known failure
  # mode (Finding 7/8: unreliable specifically for large files like
  # NETKVM.SYS) never applies here; the XML itself is a few KB.
  floppy_content = {
    "autounattend.xml" = templatefile("${path.root}/answer_files/autounattend-windows11.xml.pkrtpl", {
      admin_password  = var.admin_password
      computer_name   = var.vm_name
      windows_edition = var.windows_edition
      virtio_os_dir   = var.virtio_os_dir
    })
  }

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_insecure = true
  winrm_use_ssl  = false

  # A single <enter> (eb4x's approach) got past the "no bootable device"
  # problem (fixed by the index= addition above) only to hit the original
  # "press any key" timing-miss symptom (PXE fallthrough) - confirmed live.
  # Reverted to this project's own repeated-spacebar mechanism instead,
  # proven reliable across every Server 2022 build this session (see
  # packer/windows-server.pkr.hcl's matching comment for the full
  # rationale) now that the qemuargs/index fix has solved the separate,
  # real structural problem.
  boot_wait    = "2s"
  boot_command = [join("", [for _ in range(25) : "<spacebar><wait1>"])]

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "15m"
}

build {
  name    = "windows11"
  sources = ["source.qemu.windows11"]

  provisioner "file" {
    source      = var.services_yaml_path
    destination = "C:/Windows/Temp/services.yaml"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/"
    destination = "C:/Windows/Temp/scripts"
  }

  provisioner "powershell" {
    inline = ["powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\scripts\\run-services.ps1"]
  }

  # Harmless no-op here: ad-ds (the only role that needs a reboot) isn't a
  # meaningful choice for a Windows 11 client and won't be selected, but
  # this stays unconditional for the same reason it is on the Server
  # template - Packer can't conditionally include a provisioner by variable.
  provisioner "windows-restart" {
    restart_timeout = "5m"
  }

  provisioner "powershell" {
    inline = ["powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\scripts\\verify-post-reboot.ps1"]
  }
}

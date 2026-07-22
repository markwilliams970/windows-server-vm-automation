packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

# Phase 2: unattended install only. No provisioners here yet — AD DS, IIS,
# and the Datadog Agent are added as separate "provisioner" blocks in later
# phases, running as ordinary WinRM commands against the finished install.
#
# Deliberately no sysprep/generalize in shutdown_command: this build produces
# one disposable, already-specialized VM disk, not a golden image template.
source "qemu" "windows_server" {
  vm_name          = "${local.vm_name}.qcow2"
  output_directory = "${path.root}/output/${local.vm_name}"

  iso_url      = local.iso_url
  iso_checksum = local.iso_checksum

  headless = var.headless

  cpus      = var.cpus
  memory    = var.memory_size
  disk_size = var.disk_size

  accelerator      = "kvm"
  machine_type     = "q35"
  disk_interface   = "virtio-scsi"
  net_device       = "virtio-net"
  disk_compression = true
  format           = "qcow2"

  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars

  # autounattend.xml + driver files go on a second generated CD-ROM (not
  # qemuargs, not a floppy — both tried and rejected first):
  #   - qemuargs: setting it fully replaces packer's own "-drive" arguments,
  #     including the main boot disk. Broke VM startup entirely.
  #   - floppy: content delivery was flaky specifically for larger files —
  #     NETKVM.SYS (192KB) repeatedly failed "pnputil /add-driver" with
  #     "the system cannot find the file specified" even right after a
  #     `dir A:\` confirmed it was listed, while the smaller vioscsi/viostor
  #     .sys files (65-80KB) installed fine. Confirmed live in a running VM.
  #   - A second CD-ROM was actually tried before floppy too, and rejected
  #     at the time because Setup's edition picker showed "No images are
  #     available" despite an exact /IMAGE/NAME match — but that turned out
  #     to be caused by a mismatched <ProductKey> (a volume-license KMS key
  #     against eval-channel media, see the note below), not the second
  #     CD-ROM. Now that ProductKey is removed, a second CD-ROM is safe and
  #     is far more reliably read than floppy.
  # cd_files preserves each directory's own basename at the CD root (unlike
  # floppy_files, which flattens everything) — hence DriverPaths below uses
  # nested vioscsi\<virtio_os_dir>\amd64 style paths again.
  cd_label = "unattend"
  cd_files = [
    "${var.virtio_drivers_dir}/vioscsi",
    "${var.virtio_drivers_dir}/viostor",
    "${var.virtio_drivers_dir}/NetKVM",
  ]
  cd_content = {
    "autounattend.xml" = templatefile("${path.root}/answer_files/autounattend.xml.pkrtpl", {
      admin_password  = var.admin_password
      computer_name   = local.vm_name
      windows_edition = local.windows_edition
      virtio_os_dir   = local.virtio_os_dir
    })
  }

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_insecure = true
  winrm_use_ssl  = false

  # The Windows install media's UEFI bootloader shows "Press any key to boot
  # from CD or DVD..." for only ~2-3s and falls through to the next boot
  # device (eventually dead-ending at PXE/HTTP boot) if nothing responds in
  # time. Exact OVMF POST timing before that prompt appears varies by host
  # and isn't predictable, so instead of guessing when to press once, keep
  # pressing spacebar every second for a long window to guarantee overlap.
  #
  # windows_version=2025's media reliably fails this same mechanism outright
  # (falls through to the OVMF UEFI shell every time, even after widening
  # this window to 1s-wait/60s and forcing an explicit qemu -boot order hint
  # - both reverted, neither helped) - a known, unresolved upstream issue as
  # of this writing (hashicorp/packer#13342, #13514; HashiCorp Discuss "QEMU
  # - Windows unable to boot in UEFI mode" reports the identical FS0/FS1 EFI
  # Shell symptom with no confirmed fix). See WINDOWS_SERVER_UNATTENDED_
  # THRU_PHASE2.md's Open Issues for the full investigation. Do not re-widen
  # this window or re-add qemuargs for 2025 without new evidence - both were
  # tried and shelved.
  boot_wait    = "2s"
  boot_command = [join("", [for _ in range(25) : "<spacebar><wait1>"])]

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "15m"
}

build {
  name    = "windows-server"
  sources = ["source.qemu.windows_server"]

  provisioner "file" {
    source      = var.services_yaml_path
    destination = "C:/Windows/Temp/services.yaml"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/"
    destination = "C:/Windows/Temp/scripts"
  }

  provisioner "powershell" {
    inline = ["powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\scripts\\run-services.ps1 -DomainName '${var.domain_name}'"]
  }

  # Unconditional: Packer can't conditionally include a provisioner based on
  # a runtime variable (e.g. "only if ad-ds was selected"), and this is a
  # no-op cost when nothing needed a reboot. install-ad.ps1 deliberately
  # passes -NoRebootOnCompletion to Install-ADDSForest so its own reboot
  # happens here, under Packer's control, instead of dropping the WinRM
  # connection out from under the still-running powershell provisioner
  # above. A fresh DC's first reboot (SYSVOL/AD DS/DNS service startup) is
  # slower than a normal Windows reboot, hence the longer timeout than a
  # bare install would need.
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # Always runs, same "PowerShell decides, HCL stays static" pattern as
  # run-services.ps1: verify-post-reboot.ps1 checks for a marker file
  # install-ad.ps1 leaves behind and no-ops if it's not present, so this
  # step is meaningful only when ad-ds was actually selected. Verification
  # has to happen here, after the restart above, since AD DS/DNS aren't
  # fully up until the promotion reboot completes.
  provisioner "powershell" {
    inline = ["powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\scripts\\verify-post-reboot.ps1"]
  }
}

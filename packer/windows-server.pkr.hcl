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
  boot_wait    = "2s"
  boot_command = [join("", [for _ in range(25) : "<spacebar><wait1>"])]

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "15m"
}

build {
  name    = "windows-server"
  sources = ["source.qemu.windows_server"]
}

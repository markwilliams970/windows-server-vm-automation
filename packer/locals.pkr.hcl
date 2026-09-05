# Per-Windows-version defaults. To support another release, add a key here —
# everything else (variables.pkr.hcl, windows-server.pkr.hcl, build.sh) reads
# from this map and needs no further changes. Each field can still be
# overridden individually via its matching -var flag regardless of version.
locals {
  windows_profiles = {
    "2022" = {
      iso_url         = "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
      iso_checksum    = "sha256:3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325"
      windows_edition = "Windows Server 2022 SERVERSTANDARD"
      product_key     = "VDYBN-27WPP-V4HQT-9VMD4-VMK7H"
      virtio_os_dir   = "2k22"
      # The "press any key to boot from CD or DVD..." race — see
      # windows-server.pkr.hcl's boot_command comment for why this exists and
      # why 2025 below cannot use it.
      boot_command = [join("", [for _ in range(25) : "<spacebar><wait1>"])]
      # 2022's Setup never performs the stricter hardware-capability checks
      # 2025 does — packer's own default (no -cpu flag, so plain qemu64) is
      # enough. Left empty rather than also adding -cpu host: no known need,
      # and every gated-per-version field here should default to "unchanged
      # from before this project touched Server 2025" unless there's a
      # concrete reason otherwise.
      qemuargs = []
    }
    "2025" = {
      iso_url = "https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us"
      # Microsoft doesn't publish a checksum for this file, and it's too large
      # (~8.5GB) to have been verified by downloading it while writing this.
      # "none" disables packer's integrity check for this profile only. After
      # your first successful download, run sha256sum on the cached ISO and
      # pass -var iso_checksum=sha256:... (or set WIN_ISO_CHECKSUM) to pin it.
      iso_checksum    = "none"
      windows_edition = "Windows Server 2025 SERVERSTANDARD"
      product_key     = "TVRH6-WHNXV-R9WG3-9XRFY-MY832"
      virtio_os_dir   = "2k25"
      # Empty, not just shorter: 2025's media reliably loses the spacebar
      # race above no matter how it's tuned (Finding 15,
      # WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md — confirmed unfixable via
      # boot_command/boot-order tuning alone). build.sh instead patches this
      # version's cached ISO with Microsoft's own "_noprompt" boot files
      # before ever handing it to packer, which removes the prompt from the
      # media itself — so no keystroke is needed or sent. See build.sh's
      # prepare_noprompt_iso and EXPERIMENT_SERVER2025_NOPROMPT_SETUP.md in
      # the sibling windows-auto-build-pipeline project for how this was
      # proven out before landing here.
      boot_command = []
      # -cpu host: without it, packer's own default qemu64 CPU model is not
      # enough for 2025's Setup — the VM reset back to the OVMF/TianoCore
      # splash on a real, repeating cycle (never reaching Setup's actual
      # GUI), matching Finding 15's original symptom despite the
      # noprompt-patched media. Reproduced standalone outside packer entirely
      # (ruling out cd_files/driver-CD involvement), then confirmed -cpu host
      # alone fixed it. Exposes the full host CPU feature set (plausibly
      # whatever VBS/virtualization-related flags 2025's stricter
      # hardware-capability checks probe for that a generic qemu64 lacks) —
      # not itself TPM emulation, which this template doesn't configure.
      #
      # A second, different failure (a generic Windows Setup "restarted
      # unexpectedly ... installation cannot proceed" dialog, partway through
      # a real install) also surfaced during this investigation, once -cpu
      # host got far enough to reach it. It looked at first like packer's
      # implicit "-drive file=...,media=cdrom" CD-ROM wiring — replacing it
      # with explicit ide-cd/bus=ide.0/ide.1 pinning (matching the sibling
      # project's own working experiment) made the failure go away in a
      # standalone repro. That conclusion was wrong: the repro had also
      # switched to a short (<=15 char) ComputerName in the same test,
      # confounding two changed variables at once. A follow-up test — short
      # ComputerName, packer's ORIGINAL implicit CD-ROM wiring, no pinning at
      # all — also succeeded cleanly (real authenticated WinRM). The actual
      # second cause was an oversized ComputerName (this project's own
      # ad-hoc test vm_names exceeded NetBIOS's 15-character limit, e.g.
      # "win2025-gate1-boot-retry"), not the CD-ROM wiring; build.sh now
      # rejects any vm_name over 15 characters outright rather than letting
      # this recur silently. qemuargs overriding "-drive"/"-device" was
      # confirmed (via packer's own docs) to drop ALL of packer's own default
      # generation for those switches, not just the ones named — real,
      # avoidable complexity this project doesn't actually need. Recorded
      # here so the same wrong turn isn't retried without re-deriving why.
      qemuargs = [["-cpu", "host"]]
    }
  }

  profile = local.windows_profiles[var.windows_version]

  vm_name      = coalesce(var.vm_name, "win${var.windows_version}-dc")
  iso_url      = coalesce(var.iso_url, local.profile.iso_url)
  iso_checksum = coalesce(var.iso_checksum, local.profile.iso_checksum)
  # Not currently passed into autounattend.xml.pkrtpl — these ISOs are eval
  # media, and this KMS client key is for the non-eval edition (see the
  # ProductKey note in autounattend.xml.pkrtpl). Kept as documented reference
  # and for if this project ever targets non-eval/volume-license media.
  product_key     = coalesce(var.product_key, local.profile.product_key)
  windows_edition = coalesce(var.windows_edition, local.profile.windows_edition)
  virtio_os_dir   = coalesce(var.virtio_os_dir, local.profile.virtio_os_dir)
  boot_command    = local.profile.boot_command
  qemuargs        = local.profile.qemuargs
}

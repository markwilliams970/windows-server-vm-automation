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
}

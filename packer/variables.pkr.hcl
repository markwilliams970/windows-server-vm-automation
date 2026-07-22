variable "windows_version" {
  type        = string
  default     = "2022"
  description = "Windows Server version to build — must be a key in local.windows_profiles (packer/locals.pkr.hcl). Currently \"2022\" or \"2025\". Selects default iso_url/iso_checksum/product_key/windows_edition unless individually overridden below. Also determines which virtio driver folder build.sh extracts (see the WINDOWS_VERSION case statement there)."

  validation {
    condition     = contains(["2022", "2025"], var.windows_version)
    error_message = "Windows_version must be a key defined in local.windows_profiles, currently 2022 or 2025."
  }
}

variable "vm_name" {
  type        = string
  default     = null
  description = "Used for the VM/output directory name and as the guest's ComputerName. Defaults to \"win<windows_version>-dc\" if unset."
}

variable "iso_url" {
  type        = string
  default     = null
  description = "Override the default ISO URL for windows_version. Accepts a remote https:// URL (packer downloads and caches it) or a local file:// path. Set via build.sh from WIN_ISO_PATH."
}

variable "iso_checksum" {
  type        = string
  default     = null
  description = "Override the default checksum for iso_url, in packer's \"type:hexdigest\" form, e.g. sha256:abcd... Set via build.sh from WIN_ISO_CHECKSUM."
}

variable "virtio_drivers_dir" {
  type        = string
  description = "Local directory containing extracted vioscsi/, viostor/, and NetKVM/ driver trees from virtio-win.iso. build.sh extracts these automatically from VIRTIO_ISO_PATH before invoking packer — this variable should not normally be set by hand."
}

variable "product_key" {
  type        = string
  default     = null
  description = "Override the KMS client setup key for windows_version/windows_edition. Selects edition during setup only — not a real license. See https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys"
}

variable "windows_edition" {
  type        = string
  default     = null
  description = "Override the /IMAGE/NAME to install from the ISO's install.wim. Must match an edition present in that ISO. Use '...SERVERSTANDARDCORE' for Server Core."
}

variable "virtio_os_dir" {
  type        = string
  default     = null
  description = "Override the OS folder name used inside virtio-win's driver paths for windows_version (e.g. \"2k22\", \"2k25\")."
}

variable "efi_firmware_code" {
  type        = string
  default     = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  description = "Path to the OVMF UEFI firmware code file on the host (Ubuntu 'ovmf' package, 2024.02+ ships the _4M variant — check `ls /usr/share/OVMF/` if this build fails to find it)."
}

variable "efi_firmware_vars" {
  type        = string
  default     = "/usr/share/OVMF/OVMF_VARS_4M.fd"
  description = "Path to the OVMF UEFI firmware vars template file on the host."
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_size" {
  type    = number
  default = 16384
}

variable "disk_size" {
  type        = number
  default     = 61440
  description = "Disk size in MB."
}

variable "headless" {
  type    = bool
  default = true
}

variable "winrm_timeout" {
  type    = string
  default = "45m"
}

variable "admin_password" {
  type        = string
  default     = "ChangeMe-Lab123!"
  sensitive   = true
  description = "Local Administrator password, baked into autounattend.xml and used as the WinRM/Packer communicator password for this build only. This is a build-time credential on a disposable, isolated lab VM, not a secret asset — override via PKR_VAR_admin_password if you want a different value."
}

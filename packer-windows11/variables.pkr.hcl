variable "iso_url" {
  type        = string
  description = "file:// path to the cached Windows 11 Enterprise Evaluation ISO. Set by build-windows11.sh from iso_cache/. Kept for Packer's own schema validation/checksum verification even though the actual boot-time attachment is manual (qemuargs) - see iso_url_local_path."
}

variable "iso_url_local_path" {
  type        = string
  description = "Plain local filesystem path (no file:// prefix) to the same ISO as iso_url - qemuargs needs a bare path, not a URL. Set by build-windows11.sh."
}

variable "iso_checksum" {
  type        = string
  description = "sha256:<hex> for iso_url. Set by build-windows11.sh from iso_cache/'s sidecar file."
}

variable "virtio_iso_path" {
  type        = string
  description = "Local path to the raw, unmodified virtio-win.iso - mounted directly as a second CD-ROM rather than a cd_files-curated subset (see windows11.pkr.hcl's header comment for why). Set by build-windows11.sh from iso_cache/."
}

variable "services_yaml_path" {
  type        = string
  description = "Absolute path to the services.yaml controlling which roles this build installs. Only iis is meaningful for Windows 11 - ad-ds and sql-server are Server-only roles and will simply be skipped with a warning by run-services.ps1 if listed. Set by build-windows11.sh, defaulting to services.yaml at the repo root."
}

variable "vm_name" {
  type        = string
  default     = "win11-ent"
  description = "Used for the VM/output directory name and as the guest's ComputerName."
}

variable "admin_password" {
  type        = string
  default     = "ChangeMe-Lab123!"
  sensitive   = true
  description = "Local Administrator password, baked into autounattend.xml and used as the WinRM/Packer communicator password for this build only. Same disposable-lab placeholder used throughout this project - not treated as a real secret."
}

variable "windows_edition" {
  type        = string
  default     = "Windows 11 Enterprise Evaluation"
  description = "Must exactly match the /IMAGE/NAME reported by the ISO's install.wim - confirmed directly against the cached ISO (7z/strings extraction) before setting this default, not assumed."
}

variable "virtio_os_dir" {
  type        = string
  default     = "w11"
  description = "OS folder name used inside virtio-win's driver paths for Windows 11 client media - confirmed present (with an amd64 subfolder) in the cached virtio-win.iso before setting this default."
}

variable "efi_firmware_code" {
  type        = string
  default     = "/usr/share/OVMF/OVMF_CODE_4M.ms.fd"
  description = "Microsoft-signed-keys OVMF variant (Ubuntu's ovmf package), required for Windows 11's Secure Boot check to genuinely pass rather than being bypassed. Must be paired with efi_firmware_vars's matching \".ms.fd\" vars template."
}

variable "efi_firmware_vars" {
  type        = string
  default     = "/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
  description = "Matching Secure-Boot-enrolled vars template for efi_firmware_code."
}

variable "tpm_socket_path" {
  type        = string
  description = "Unix socket path of a running swtpm instance (swtpm socket --tpmstate ... --ctrl type=unixio,path=<this> --tpm2), started by build-windows11.sh before invoking packer. Packer's QEMU builder has no native TPM device option, so this is wired in via qemuargs in windows11.pkr.hcl."
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_size" {
  type    = number
  default = 8192
}

variable "disk_size" {
  type        = number
  default     = 81920
  description = "Disk size in MB. Windows 11 Enterprise's larger footprint than Server Core/Standard gets more headroom than Server's 60GB default."
}

variable "headless" {
  type    = bool
  default = true
}

variable "winrm_timeout" {
  type    = string
  default = "45m"
}

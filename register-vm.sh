#!/usr/bin/env bash
# Registers an already-built Packer/QEMU disk (see build.sh) as a libvirt
# domain, so it shows up in virt-manager / `virsh list --all` instead of
# existing only as a loose qcow2 file under packer/output/.
#
# Packer's QEMU builder runs qemu-system-x86_64 directly as a subprocess and
# never talks to libvirt at all — nothing is registered as a side effect of
# a plain build.sh run. This script is the separate, explicit step that
# does that (or pass REGISTER_VM=true to build.sh, which calls this
# automatically once the build finishes).
#
# The registered domain's device model mirrors what Packer used to build
# the disk (q35 machine type, OVMF UEFI, virtio-scsi disk, virtio-net NIC)
# so the VirtIO drivers already installed in the guest keep working. Its
# network is libvirt's own "default" NAT network via DHCP, not the isolated
# usermode networking Packer used for WinRM during provisioning — expect a
# new IP; connect over RDP once the guest is up.
#
# Usage:
#   ./register-vm.sh [vm_name] [output_dir]
# Both default the same way build.sh/locals.pkr.hcl resolve them: vm_name
# defaults to "win${WINDOWS_VERSION}-dc" (WINDOWS_VERSION env, default
# 2022), output_dir defaults to packer/output/<vm_name>.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

command -v virsh >/dev/null 2>&1 || fail "virsh is not installed or not on PATH"
virsh -c qemu:///system list >/dev/null 2>&1 \
  || fail "cannot reach libvirt at qemu:///system — is libvirtd running, and is this user in the 'libvirt' group?"

WINDOWS_VERSION="${WINDOWS_VERSION:-2022}"
VM_NAME="${1:-${VM_NAME:-win${WINDOWS_VERSION}-dc}}"
OUTPUT_DIR="${2:-${OUTPUT_DIR:-${REPO_ROOT}/packer/output/${VM_NAME}}}"

QCOW2_PATH="${OUTPUT_DIR}/${VM_NAME}.qcow2"
NVRAM_PATH="${OUTPUT_DIR}/efivars.fd"

[[ -f "${QCOW2_PATH}" ]] || fail "no disk found at ${QCOW2_PATH} — run build.sh first, or pass the right vm_name/output_dir"
[[ -f "${NVRAM_PATH}" ]] || fail "no UEFI vars file found at ${NVRAM_PATH} — expected Packer's own per-build copy alongside the disk"

CPUS="${CPUS:-4}"
MEMORY_MB="${MEMORY_MB:-16384}"
EFI_FIRMWARE_CODE="${EFI_FIRMWARE_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
NETWORK="${NETWORK:-default}"

[[ -f "${EFI_FIRMWARE_CODE}" ]] || fail "OVMF code file not found at ${EFI_FIRMWARE_CODE} — override via EFI_FIRMWARE_CODE=..."
virsh -c qemu:///system net-info "${NETWORK}" >/dev/null 2>&1 \
  || fail "libvirt network '${NETWORK}' does not exist — override via NETWORK=..., or create it (virsh net-define/net-start)"

# Repeated builds reuse the same vm_name (CLAUDE.md's "recreate the same
# environment repeatedly" principle), so re-registering after a rebuild is
# the common case, not an edge case. Only touch a domain that's actually
# shut off — refuse to silently undefine something that might be in active
# use.
if virsh -c qemu:///system dominfo "${VM_NAME}" >/dev/null 2>&1; then
  STATE="$(virsh -c qemu:///system domstate "${VM_NAME}")"
  if [[ "${STATE}" != "shut off" ]]; then
    fail "libvirt domain '${VM_NAME}' already exists and is '${STATE}' — shut it down (or destroy it) before re-registering"
  fi
  log "Domain '${VM_NAME}' already registered and shut off — undefining before re-registering with the fresh build"
  # --keep-nvram: the old domain's <nvram> path is this same build's
  # OUTPUT_DIR/efivars.fd, which the new Packer build has already
  # overwritten with fresh UEFI vars by the time this runs. Plain
  # `undefine` refuses to proceed at all once a domain has an nvram file
  # (needs an explicit --nvram/--keep-nvram choice); --nvram would delete
  # the file the new build just wrote.
  virsh -c qemu:///system undefine --keep-nvram "${VM_NAME}"
fi

DOMAIN_XML="$(mktemp --suffix=.xml)"
trap 'rm -f "${DOMAIN_XML}"' EXIT

# Mirrors packer/windows-server.pkr.hcl's qemu builder config: machine_type
# q35, efi_boot true (OVMF code ro + this build's own writable vars copy,
# not the shared template), disk_interface virtio-scsi, net_device
# virtio-net. cpu mode host-passthrough is a libvirt-default-style choice
# (Packer's own build didn't pin a specific -cpu model) — fine for a lab
# VM that only ever runs on this host.
cat > "${DOMAIN_XML}" <<EOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${MEMORY_MB}</memory>
  <currentMemory unit='MiB'>${MEMORY_MB}</currentMemory>
  <vcpu placement='static'>${CPUS}</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>${EFI_FIRMWARE_CODE}</loader>
    <nvram>${NVRAM_PATH}</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='localtime'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${QCOW2_PATH}'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    <interface type='network'>
      <source network='${NETWORK}'/>
      <model type='virtio'/>
    </interface>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <video>
      <model type='qxl'/>
    </video>
    <!-- Without this, libvirt defaults to a relative PS/2 mouse, which
         desyncs from the VNC/SPICE client's absolute cursor position and
         makes the console unusable (clicks land somewhere other than the
         visible cursor). A USB tablet reports absolute coordinates, so
         guest and client cursors always agree. -->
    <input type='tablet' bus='usb'/>
  </devices>
</domain>
EOF

log "Defining libvirt domain '${VM_NAME}' from ${QCOW2_PATH}"
virsh -c qemu:///system define "${DOMAIN_XML}"

log "Registered '${VM_NAME}' — visible in virt-manager now, shut off."
log "Start it with: virsh -c qemu:///system start ${VM_NAME}"

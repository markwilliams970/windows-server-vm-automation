#!/usr/bin/env bash
# Phase 2: unattended Windows Server install only.
# AD DS / IIS / Datadog provisioning and post-build verification are added
# in later phases and will extend this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKER_DIR="${REPO_ROOT}/packer"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

echo "==> Checking prerequisites"
command -v packer >/dev/null 2>&1 || fail "packer is not installed or not on PATH"
command -v qemu-img >/dev/null 2>&1 || fail "qemu-img is not installed or not on PATH"
command -v virsh >/dev/null 2>&1 || fail "virsh is not installed or not on PATH"
command -v xorriso >/dev/null 2>&1 || fail "xorriso is not installed or not on PATH (needed to extract virtio drivers)"

virsh -c qemu:///system list >/dev/null 2>&1 \
  || fail "cannot reach libvirt at qemu:///system — is libvirtd running, and is this user in the 'libvirt' group?"

WINDOWS_VERSION="${WINDOWS_VERSION:-2022}"
: "${VIRTIO_ISO_PATH:?Set VIRTIO_ISO_PATH to the path of virtio-win.iso (https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/)}"
[[ -f "${VIRTIO_ISO_PATH}" ]] || fail "VIRTIO_ISO_PATH does not point to a file: ${VIRTIO_ISO_PATH}"

# WIN_ISO_PATH/WIN_ISO_CHECKSUM are optional: unset, packer downloads and
# verifies the profile's default ISO for WINDOWS_VERSION (see
# packer/locals.pkr.hcl) itself. Set them to build from an already-downloaded
# local copy instead.
PACKER_EXTRA_VARS=(-var "windows_version=${WINDOWS_VERSION}")
if [[ -n "${WIN_ISO_PATH:-}" ]]; then
  [[ -f "${WIN_ISO_PATH}" ]] || fail "WIN_ISO_PATH does not point to a file: ${WIN_ISO_PATH}"
  : "${WIN_ISO_CHECKSUM:?WIN_ISO_PATH is set but WIN_ISO_CHECKSUM is not — set it to the ISO checksum, e.g. sha256:abcd...}"
  PACKER_EXTRA_VARS+=(-var "iso_url=file://${WIN_ISO_PATH}" -var "iso_checksum=${WIN_ISO_CHECKSUM}")
fi

# Only the one OS variant windows_version needs is extracted (not every
# version virtio-win.iso ships). This is the only place this mapping lives
# — add a case here for any new Windows version added to
# packer/locals.pkr.hcl's windows_profiles map.
case "${WINDOWS_VERSION}" in
  2022) VIRTIO_OS_DIR="2k22" ;;
  2025) VIRTIO_OS_DIR="2k25" ;;
  *) fail "No virtio driver folder known for WINDOWS_VERSION=${WINDOWS_VERSION} — add one here" ;;
esac

echo "==> Extracting virtio ${VIRTIO_OS_DIR} drivers from ${VIRTIO_ISO_PATH}"
VIRTIO_DRIVERS_DIR="$(mktemp -d)"
cleanup() { rm -rf "${VIRTIO_DRIVERS_DIR}"; }
trap cleanup EXIT
xorriso -indev "${VIRTIO_ISO_PATH}" -osirrox on \
  -extract "/vioscsi/${VIRTIO_OS_DIR}" "${VIRTIO_DRIVERS_DIR}/vioscsi/${VIRTIO_OS_DIR}" \
  -extract "/viostor/${VIRTIO_OS_DIR}" "${VIRTIO_DRIVERS_DIR}/viostor/${VIRTIO_OS_DIR}" \
  -extract "/NetKVM/${VIRTIO_OS_DIR}" "${VIRTIO_DRIVERS_DIR}/NetKVM/${VIRTIO_OS_DIR}" \
  >/dev/null
# xorriso preserves the ISO's own (read-only, dr-xr-xr-x) permission bits on
# extracted directories, which blocks both packer's own copy into its floppy
# staging dir and our cleanup trap below. Reassert normal owner permissions.
chmod -R u+rwX "${VIRTIO_DRIVERS_DIR}"
# Only .pdb (debug symbols, several hundred KB to multi-MB each, never
# needed) is worth stripping. Everything else stays: netkvm.inf's own
# CopyFiles directive requires netkvmp.exe alongside netkvm.sys, not just
# the .sys — pnputil fails with "the system cannot find the file specified"
# if it's missing, which cost real time to track down (confirmed live: the
# same failure happened identically over both floppy and CD-ROM delivery,
# so it was never a media problem). Driver delivery now uses a CD, not the
# 1.44MB floppy that motivated aggressive filtering in the first place, so
# there's no real size pressure to filter beyond this.
find "${VIRTIO_DRIVERS_DIR}" -type f -name '*.pdb' -delete

echo "==> Initializing Packer plugins"
packer init "${PACKER_DIR}/windows-server.pkr.hcl"

echo "==> Validating template"
packer validate \
  "${PACKER_EXTRA_VARS[@]}" \
  -var "virtio_drivers_dir=${VIRTIO_DRIVERS_DIR}" \
  "${PACKER_DIR}"

echo "==> Building Windows Server ${WINDOWS_VERSION} VM"
packer build \
  "${PACKER_EXTRA_VARS[@]}" \
  -var "virtio_drivers_dir=${VIRTIO_DRIVERS_DIR}" \
  "${PACKER_DIR}"

echo "==> Build complete. Disk artifact in ${PACKER_DIR}/output/"

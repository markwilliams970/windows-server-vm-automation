#!/usr/bin/env bash
# Windows 11 client build. Deliberately a separate script from build.sh, not
# a WINDOWS_VERSION=win11 case added there: this template lives in its own
# packer-windows11/ directory (see that directory's windows11.pkr.hcl for
# why - variable-name collisions with the Server template if combined into
# one Packer config directory), and needs an extra host-side step Server
# builds don't: starting swtpm (a real TPM 2.0 emulator - Windows 11 setup's
# TPM check is satisfied for real here, not bypassed) before Packer runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKER_DIR="${REPO_ROOT}/packer-windows11"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

echo "==> Checking prerequisites"
command -v packer >/dev/null 2>&1 || fail "packer is not installed or not on PATH"
command -v qemu-img >/dev/null 2>&1 || fail "qemu-img is not installed or not on PATH"
command -v virsh >/dev/null 2>&1 || fail "virsh is not installed or not on PATH"
command -v curl >/dev/null 2>&1 || fail "curl is not installed or not on PATH (needed for ISO cache/currency checks)"
command -v swtpm >/dev/null 2>&1 || fail "swtpm is not installed or not on PATH (needed to emulate TPM 2.0 for Windows 11's setup requirement)"

virsh -c qemu:///system list >/dev/null 2>&1 \
  || fail "cannot reach libvirt at qemu:///system — is libvirtd running, and is this user in the 'libvirt' group?"

[[ -f /usr/share/OVMF/OVMF_CODE_4M.ms.fd && -f /usr/share/OVMF/OVMF_VARS_4M.ms.fd ]] \
  || fail "Secure-Boot OVMF firmware (OVMF_CODE_4M.ms.fd / OVMF_VARS_4M.ms.fd) not found under /usr/share/OVMF/ — needed for Windows 11's Secure Boot requirement to genuinely pass rather than being bypassed"

ISO_CACHE_DIR="${ISO_CACHE_DIR:-${REPO_ROOT}/../iso_cache}"
mkdir -p "${ISO_CACHE_DIR}"

WIN11_STABLE_URL="https://go.microsoft.com/fwlink/?linkid=2334167&clcid=0x809&culture=en-gb&country=gb"

# Same cache/currency pattern as build.sh's check_windows_iso_cache, just
# not version-parameterized since there's only one Windows 11 profile here
# (unlike Server's windows_profiles map in locals.pkr.hcl).
check_win11_iso_cache() {
  local cache_dir="$1"
  local cached_iso cached_sum_file cached_meta headers remote_etag recorded_etag

  cached_iso="$(find "${cache_dir}" -maxdepth 1 -name "win11ent-*.iso" 2>/dev/null | head -n1)"
  [[ -n "${cached_iso}" ]] || return 1

  cached_sum_file="${cached_iso}.sha256"
  cached_meta="${cached_iso}.meta"
  if [[ ! -f "${cached_sum_file}" || ! -f "${cached_meta}" ]]; then
    log "Found ${cached_iso} but it's missing its .sha256/.meta sidecar — treating as untrusted, will re-download"
    return 1
  fi

  headers="$(curl -sI --max-time 20 -L "${WIN11_STABLE_URL}" 2>/dev/null)" || true
  remote_etag="$(grep -i '^etag:' <<<"${headers}" | tail -n1 | tr -d '\r' | sed -E 's/^[Ee][Tt][Aa][Gg]:\s*"?([^"]*)"?.*/\1/')"

  if [[ -z "${remote_etag}" ]]; then
    log "Could not reach Microsoft to check Windows 11 ISO currency (network issue?) — falling back to cached ISO"
    echo "${cached_iso}"
    return 0
  fi

  recorded_etag="$(grep -E '^etag=' "${cached_meta}" | cut -d= -f2-)"
  if [[ "${remote_etag}" == "${recorded_etag}" ]]; then
    log "Cached Windows 11 Enterprise Eval ISO matches the currently published ETag — using cache, no download needed"
    echo "${cached_iso}"
    return 0
  fi

  log "Published Windows 11 ISO has changed since it was cached (ETag differs) — cache is stale"
  return 1
}

# Downloads a fresh copy directly (no separate small-bootstrapper step, this
# fwlink serves the full ISO in one request - confirmed via a HEAD request
# before ever writing this).
download_win11_iso() {
  local cache_dir="$1"
  local headers remote_etag remote_name dest tmp actual_sum

  headers="$(curl -sI --max-time 20 -L "${WIN11_STABLE_URL}")" \
    || fail "Could not reach Microsoft to resolve the Windows 11 Enterprise Evaluation ISO download"
  remote_etag="$(grep -i '^etag:' <<<"${headers}" | tail -n1 | tr -d '\r' | sed -E 's/^[Ee][Tt][Aa][Gg]:\s*"?([^"]*)"?.*/\1/')"
  remote_name="$(grep -i '^content-disposition:' <<<"${headers}" | tail -n1 | tr -d '\r' | sed -E 's/.*filename="?([^";]+)"?.*/\1/')"
  [[ -n "${remote_name}" ]] || remote_name="win11-enterprise-eval.iso"

  dest="${cache_dir}/win11ent-${remote_name}"
  tmp="$(mktemp "${dest}.XXXXXX.part")"
  log "Downloading Windows 11 Enterprise Evaluation ISO (several GB — this will take a while)..."
  curl -fL --max-time 3600 -o "${tmp}" "${WIN11_STABLE_URL}" || { rm -f "${tmp}"; fail "Failed to download Windows 11 ISO"; }

  actual_sum="$(sha256sum "${tmp}" | awk '{print $1}')"
  rm -f "${cache_dir}"/win11ent-*.iso "${cache_dir}"/win11ent-*.iso.sha256 "${cache_dir}"/win11ent-*.iso.meta
  mv "${tmp}" "${dest}"
  echo "${actual_sum}  $(basename "${dest}")" > "${dest}.sha256"
  {
    echo "source_url=${WIN11_STABLE_URL}"
    echo "etag=${remote_etag}"
    echo "checked=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${dest}.meta"
  log "Cached fresh Windows 11 ISO at ${dest}"
  echo "${dest}"
}

log "Checking Windows 11 Enterprise Evaluation ISO cache/currency..."
if ! WIN11_ISO_PATH="$(check_win11_iso_cache "${ISO_CACHE_DIR}")"; then
  WIN11_ISO_PATH="$(download_win11_iso "${ISO_CACHE_DIR}")"
fi
WIN11_ISO_CHECKSUM="sha256:$(awk '{print $1}' "${WIN11_ISO_PATH}.sha256")"

SERVICES_YAML_PATH="${SERVICES_YAML_PATH:-${REPO_ROOT}/services.yaml}"
[[ -f "${SERVICES_YAML_PATH}" ]] || fail "SERVICES_YAML_PATH does not point to a file: ${SERVICES_YAML_PATH}"

VIRTIO_ISO_PATH="$(find "${ISO_CACHE_DIR}" -maxdepth 1 -name 'virtio-win-*.iso' 2>/dev/null | sort -V | tail -n1)"
[[ -n "${VIRTIO_ISO_PATH}" ]] || fail "No virtio-win-*.iso found in ${ISO_CACHE_DIR} — run build.sh once first so it gets cached, or place one there manually"
log "Using virtio-win.iso directly (mounted raw, not extracted): ${VIRTIO_ISO_PATH}"

# swtpm's state dir runs for the lifetime of this script, alongside
# whatever qemu process Packer starts - cleaned up in the EXIT trap below
# regardless of how this script exits (success, failure, or Ctrl-C). No
# separate efivars copy needed here - Packer's own efi_firmware_vars field
# still handles that (see windows11.pkr.hcl's header comment for why that
# native field couldn't be bypassed the way the other drives were).
SCRATCH_DIR="$(mktemp -d)"
TPM_SOCK="${SCRATCH_DIR}/swtpm-sock"
SWTPM_PID=""

cleanup() {
  if [[ -n "${SWTPM_PID}" ]] && kill -0 "${SWTPM_PID}" 2>/dev/null; then
    log "Stopping swtpm (pid ${SWTPM_PID})"
    kill "${SWTPM_PID}" 2>/dev/null || true
  fi
  rm -rf "${SCRATCH_DIR}"
}
trap cleanup EXIT

log "Starting swtpm (TPM 2.0 emulator) on ${TPM_SOCK}"
swtpm socket --tpmstate dir="${SCRATCH_DIR}" --ctrl type=unixio,path="${TPM_SOCK}" --tpm2 --log level=1 &
SWTPM_PID=$!
for _ in $(seq 1 20); do
  [[ -S "${TPM_SOCK}" ]] && break
  sleep 0.5
done
[[ -S "${TPM_SOCK}" ]] || fail "swtpm did not create its control socket at ${TPM_SOCK} within 10s"

PACKER_VARS=(
  -var "iso_url=file://${WIN11_ISO_PATH}"
  -var "iso_url_local_path=${WIN11_ISO_PATH}"
  -var "iso_checksum=${WIN11_ISO_CHECKSUM}"
  -var "virtio_iso_path=${VIRTIO_ISO_PATH}"
  -var "services_yaml_path=${SERVICES_YAML_PATH}"
  -var "tpm_socket_path=${TPM_SOCK}"
)

echo "==> Initializing Packer plugins"
packer init "${PACKER_DIR}/windows11.pkr.hcl"

echo "==> Validating template"
packer validate "${PACKER_VARS[@]}" "${PACKER_DIR}"

echo "==> Building Windows 11 Enterprise Evaluation VM"
packer build "${PACKER_VARS[@]}" "${PACKER_DIR}"

echo "==> Build complete. Disk artifact in ${PACKER_DIR}/output/"

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

# Status/progress lines go to stderr, not stdout — several functions below
# are called via command substitution ($(...)) to return a resolved file
# path on stdout, and log() output must never leak into that captured value.
log() {
  echo "==> $*" >&2
}

echo "==> Checking prerequisites"
command -v packer >/dev/null 2>&1 || fail "packer is not installed or not on PATH"
command -v qemu-img >/dev/null 2>&1 || fail "qemu-img is not installed or not on PATH"
command -v virsh >/dev/null 2>&1 || fail "virsh is not installed or not on PATH"
command -v xorriso >/dev/null 2>&1 || fail "xorriso is not installed or not on PATH (needed to extract virtio drivers)"
command -v curl >/dev/null 2>&1 || fail "curl is not installed or not on PATH (needed for ISO cache/currency checks)"

virsh -c qemu:///system list >/dev/null 2>&1 \
  || fail "cannot reach libvirt at qemu:///system — is libvirtd running, and is this user in the 'libvirt' group?"

# ISO_CACHE_DIR holds all locally-cached binary install media (Windows ISO,
# virtio-win driver ISO) so repeat builds don't re-fetch multi-GB files
# unnecessarily. It lives one level above this repo (../iso_cache) so it can
# be shared with the sibling windows-auto-build-pipeline project rather than
# duplicated per-repo. Each cached ISO has two small tracked sidecars, both
# named "<iso-filename>.<ext>":
#   .sha256  standard sha256sum-format checksum of our own cached copy
#            (verifiable directly: sha256sum -c ../iso_cache/<name>.sha256)
#   .meta    key=value lines recording the source URL and an upstream
#            "freshness fingerprint" captured when we last verified/
#            downloaded this file — an HTTP ETag for the Windows ISO, the
#            resolved versioned filename for virtio-win. Compared against
#            the live public source before every build; see
#            check_windows_iso_cache/check_virtio_iso_cache below.
# The .iso files themselves are gitignored (*.iso); the sidecars are small
# text and get tracked.
ISO_CACHE_DIR="${ISO_CACHE_DIR:-${REPO_ROOT}/../iso_cache}"
mkdir -p "${ISO_CACHE_DIR}"

WINDOWS_VERSION="${WINDOWS_VERSION:-2022}"

# Only Server 2025 needs this (see build_noprompt_iso below) — not required
# for a 2022-only host, so it's checked here rather than in the main
# prerequisites block above.
if [[ "${WINDOWS_VERSION}" == "2025" ]]; then
  command -v 7z >/dev/null 2>&1 || fail "7z is not installed or not on PATH (needed to patch Server 2025 install media — p7zip-full on Debian/Ubuntu)"
fi

VM_NAME="${PKR_VAR_vm_name:-win${WINDOWS_VERSION}-dc}"
OUTPUT_DIR="${PACKER_DIR}/output/${VM_NAME}"
# vm_name doubles as the guest's ComputerName (autounattend.xml.pkrtpl), and
# NetBIOS hard-caps that at 15 characters. Packer itself doesn't check this
# — Setup just fails partway through with a generic "restarted unexpectedly
# ... installation cannot proceed" dialog and no other clue, which cost real
# time to root-cause against Server 2025 (confirmed live: identical failure
# with packer's default CD-ROM wiring and with a from-scratch explicit
# ide-cd/bus-pinned qemuargs override — pinning wasn't the fix, a short name
# was). Checked early, before any ISO cache work, so a bad name fails fast.
# The default "win<version>-dc" is always safe; only a custom -var
# vm_name/PKR_VAR_vm_name can trigger this. packer/variables.pkr.hcl's own
# vm_name validation catches the same thing for a direct `packer build` that
# bypasses this script entirely.
if [[ ${#VM_NAME} -gt 15 ]]; then
  fail "vm_name '${VM_NAME}' is ${#VM_NAME} characters — NetBIOS ComputerName has a hard 15-character limit. Choose a shorter -var vm_name/PKR_VAR_vm_name."
fi

# Pulls one field's value out of the windows_profiles map in
# packer/locals.pkr.hcl for a given version, e.g.
# `profile_field 2022 iso_checksum`. Deliberately plain grep/sed, not gawk's
# match()-with-capture-array extension, since mawk (Ubuntu/Mint's default
# /usr/bin/awk) doesn't support it. Fragile if locals.pkr.hcl's formatting
# changes shape — kept in one place, only used here.
profile_field() {
  local version="$1" field="$2"
  grep -A 10 "\"${version}\" = {" "${PACKER_DIR}/locals.pkr.hcl" \
    | awk '/^\s*}/{exit} {print}' \
    | grep -E "^\s*${field}\s*=" | head -n1 \
    | sed -E 's/^[^=]+=\s*"([^"]*)".*/\1/'
}

# Checks whether a cached Windows install ISO for $1 (version) exists in $2
# (cache dir) and still matches what Microsoft currently publishes. Prints
# the cached ISO path on stdout and returns 0 on a usable cache hit; returns
# 1 (nothing on stdout) if the cache is missing, untrusted, or stale.
check_windows_iso_cache() {
  local version="$1" cache_dir="$2"
  local cached_iso cached_sum_file cached_meta pinned_checksum fwlink_url headers remote_etag recorded_etag

  cached_iso="$(find "${cache_dir}" -maxdepth 1 -name "${version}-*.iso" 2>/dev/null | head -n1)"
  [[ -n "${cached_iso}" ]] || return 1

  cached_sum_file="${cached_iso}.sha256"
  cached_meta="${cached_iso}.meta"
  if [[ ! -f "${cached_sum_file}" || ! -f "${cached_meta}" ]]; then
    log "Found ${cached_iso} but it's missing its .sha256/.meta sidecar — treating as untrusted, will re-download"
    return 1
  fi

  pinned_checksum="$(profile_field "${version}" iso_checksum | sed 's/^sha256://')"
  if [[ -z "${pinned_checksum}" || "${pinned_checksum}" == "none" ]]; then
    log "No published checksum pinned for windows_version=${version} in locals.pkr.hcl — cannot verify currency; trusting existing cache as-is"
    echo "${cached_iso}"
    return 0
  fi

  fwlink_url="$(profile_field "${version}" iso_url)"
  headers="$(curl -sI --max-time 20 -L "${fwlink_url}" 2>/dev/null)" || true
  remote_etag="$(grep -i '^etag:' <<<"${headers}" | tail -n1 | tr -d '\r' | sed -E 's/^[Ee][Tt][Aa][Gg]:\s*"?([^"]*)"?.*/\1/')"

  if [[ -z "${remote_etag}" ]]; then
    log "Could not reach Microsoft to check windows_version=${version} ISO currency (network issue?) — falling back to cached ISO"
    echo "${cached_iso}"
    return 0
  fi

  recorded_etag="$(grep -E '^etag=' "${cached_meta}" | cut -d= -f2-)"
  if [[ "${remote_etag}" == "${recorded_etag}" ]]; then
    log "Cached Windows ${version} ISO matches the currently published ETag — using cache, no download needed"
    echo "${cached_iso}"
    return 0
  fi

  log "Published Windows ${version} ISO has changed since it was cached (ETag differs) — cache is stale"
  return 1
}

# Downloads the current Windows install ISO for $1 (version) into $2 (cache
# dir), verifies it against locals.pkr.hcl's pinned checksum, writes the
# .sha256/.meta sidecars, and prints the final cached path on stdout.
download_windows_iso() {
  local version="$1" cache_dir="$2"
  local fwlink_url pinned_checksum headers remote_etag remote_name dest tmp actual_sum

  fwlink_url="$(profile_field "${version}" iso_url)"
  pinned_checksum="$(profile_field "${version}" iso_checksum | sed 's/^sha256://')"

  headers="$(curl -sI --max-time 20 -L "${fwlink_url}")" \
    || fail "Could not reach Microsoft to resolve the windows_version=${version} ISO download (${fwlink_url})"
  remote_etag="$(grep -i '^etag:' <<<"${headers}" | tail -n1 | tr -d '\r' | sed -E 's/^[Ee][Tt][Aa][Gg]:\s*"?([^"]*)"?.*/\1/')"
  remote_name="$(grep -i '^content-disposition:' <<<"${headers}" | tail -n1 | tr -d '\r' | sed -E 's/.*filename="?([^";]+)"?.*/\1/')"
  [[ -n "${remote_name}" ]] || remote_name="windows-server-${version}.iso"

  dest="${cache_dir}/${version}-${remote_name}"
  tmp="$(mktemp "${dest}.XXXXXX.part")"
  log "Downloading Windows ${version} install ISO from Microsoft (several GB — this will take a while)..."
  curl -fL --max-time 3600 -o "${tmp}" "${fwlink_url}" || { rm -f "${tmp}"; fail "Failed to download Windows ${version} ISO from ${fwlink_url}"; }

  actual_sum="$(sha256sum "${tmp}" | awk '{print $1}')"
  if [[ -n "${pinned_checksum}" && "${pinned_checksum}" != "none" && "${actual_sum}" != "${pinned_checksum}" ]]; then
    rm -f "${tmp}"
    fail "Downloaded Windows ${version} ISO checksum (${actual_sum}) does not match the pinned checksum in locals.pkr.hcl (${pinned_checksum}). Refusing to use a file that doesn't match the known-good value — if Microsoft has legitimately republished this ISO, verify independently and update locals.pkr.hcl's iso_checksum before retrying."
  fi

  rm -f "${cache_dir}/${version}"-*.iso "${cache_dir}/${version}"-*.iso.sha256 "${cache_dir}/${version}"-*.iso.meta
  mv "${tmp}" "${dest}"
  echo "${actual_sum}  $(basename "${dest}")" > "${dest}.sha256"
  {
    echo "source_url=${fwlink_url}"
    echo "etag=${remote_etag}"
    echo "checked=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${dest}.meta"
  log "Cached fresh Windows ${version} ISO at ${dest}"
  echo "${dest}"
}

# Windows Server 2025 only (see Finding 15, WINDOWS_SERVER_UNATTENDED_THRU_
# PHASE2.md): the stock eval ISO's UEFI bootloader loses the interactive
# "press any key" keystroke race unfixably, in a way 2022's identical
# mechanism never does. The fix isn't tuning the keystroke — it's not needing
# one: Microsoft ships an alternate pair of boot files on the same media
# (efisys_noprompt.bin/cdboot_noprompt.efi) that skip the prompt entirely.
# This derives a patched ISO from the already-verified stock one before
# packer ever sees it, cached under ISO_CACHE_DIR/derived/ and keyed off the
# stock ISO's own checksum (not re-downloaded/re-verified itself — currency
# of the stock ISO is already handled above). windows-server.pkr.hcl pairs
# this with an empty boot_command for windows_version=2025
# (packer/locals.pkr.hcl) — no prompt on the media, so nothing to send.
NOPROMPT_CACHE_DIR_NAME="derived"

# Checks whether a cached _noprompt-patched Server 2025 ISO in $2 (cache dir)
# was derived from the exact stock ISO checksum in $1. Prints the cached
# path on stdout and returns 0 on a usable hit; returns 1 if missing, or
# derived from a since-superseded stock ISO.
check_noprompt_iso_cache() {
  local stock_checksum="$1" cache_dir="$2"
  local cached_iso cached_meta recorded_source_sum

  cached_iso="${cache_dir}/2025-noprompt.iso"
  cached_meta="${cached_iso}.meta"
  [[ -f "${cached_iso}" && -f "${cached_meta}" ]] || return 1

  recorded_source_sum="$(grep -E '^source_iso_sha256=' "${cached_meta}" | cut -d= -f2-)"
  if [[ "${recorded_source_sum}" != "${stock_checksum}" ]]; then
    log "Cached noprompt ISO was derived from a different stock ISO (stock has since changed) — will re-derive"
    return 1
  fi

  log "Cached _noprompt-patched Server 2025 ISO matches the current stock ISO — reusing, no re-derive needed"
  echo "${cached_iso}"
}

# Derives a _noprompt-patched copy of $1 (verified stock Server 2025 ISO,
# checksum $2) into $3 (cache dir), records the source checksum it was
# derived from in .meta so check_noprompt_iso_cache can detect staleness,
# and prints the final derived path on stdout.
build_noprompt_iso() {
  local stock_iso="$1" stock_checksum="$2" cache_dir="$3"
  local out_iso="${cache_dir}/2025-noprompt.iso" boot_dir tmp_out actual_sum
  # Deliberately NOT `local`: an EXIT trap fires after the function's own
  # local scope has already ended (confirmed live — a `local extract_dir`
  # here left the trap referencing an unbound variable under `set -u`, a
  # real bug caught by testing, not theoretical). This function only ever
  # runs inside the $(...) subshell that captures its stdout, so a plain
  # variable is scoped to that subshell alone regardless.
  extract_dir="$(mktemp -d)"
  # Fires whether the function returns normally or fail() below calls exit
  # (a RETURN trap would miss the latter); never touches the main script's
  # own trap cleanup EXIT set further down, since that's a separate subshell.
  trap 'rm -rf "${extract_dir}"' EXIT

  log "Extracting ${stock_iso} to patch in Microsoft's _noprompt boot files (a few minutes)..."
  # 7z, not xorriso: this media is UDF-formatted, and xorriso's -osirrox
  # extraction only reads the ISO9660 tree by default — confirmed live, it
  # sees nothing but a stray README.TXT stub there, not the real content.
  # 7z reads UDF natively. xorriso is still the right tool for the mkisofs
  # rebuild below (matches the existing virtio-win extraction elsewhere in
  # this script, which only ever reads small ISO9660-tree driver subdirs).
  7z x -y -o"${extract_dir}" "${stock_iso}" >/dev/null
  chmod -R u+rwX "${extract_dir}"

  boot_dir="${extract_dir}/efi/microsoft/boot"
  for f in efisys.bin efisys_noprompt.bin cdboot.efi cdboot_noprompt.efi; do
    [[ -f "${boot_dir}/${f}" ]] || fail "expected ${boot_dir}/${f} not found on the Server 2025 ISO — is this really the eval media the _noprompt technique was verified against?"
  done
  [[ -f "${extract_dir}/boot/etfsboot.com" ]] || fail "expected ${extract_dir}/boot/etfsboot.com not found on the Server 2025 ISO"

  log "Overwriting stock efisys.bin/cdboot.efi with their _noprompt counterparts"
  cp "${boot_dir}/efisys_noprompt.bin" "${boot_dir}/efisys.bin"
  cp "${boot_dir}/cdboot_noprompt.efi" "${boot_dir}/cdboot.efi"

  log "Rebuilding ISO via xorriso (dual boot catalog: BIOS + UEFI)"
  tmp_out="$(mktemp "${out_iso}.XXXXXX.part")"
  xorriso -as mkisofs \
    -iso-level 3 \
    -volid "WINSETUP2025" \
    -eltorito-boot boot/etfsboot.com \
      -eltorito-catalog boot/boot.cat \
      -no-emul-boot \
      -boot-load-size 8 \
      -boot-info-table \
    -eltorito-alt-boot \
      -e efi/microsoft/boot/efisys.bin \
      -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "${tmp_out}" \
    "${extract_dir}" \
    >/dev/null || { rm -f "${tmp_out}"; fail "xorriso failed to rebuild the _noprompt Server 2025 ISO"; }

  actual_sum="$(sha256sum "${tmp_out}" | awk '{print $1}')"
  mv "${tmp_out}" "${out_iso}"
  echo "${actual_sum}  $(basename "${out_iso}")" > "${out_iso}.sha256"
  {
    echo "source_iso=${stock_iso}"
    echo "source_iso_sha256=${stock_checksum}"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${out_iso}.meta"
  log "Cached fresh _noprompt-patched Server 2025 ISO at ${out_iso}"
  echo "${out_iso}"
}

readonly VIRTIO_STABLE_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# Same idea as check_windows_iso_cache, but for the virtio-win driver ISO:
# "currency" means the cached file's version matches whatever filename the
# stable-virtio symlink currently resolves to (no checksum is published
# upstream for the ISO itself, only for its RPM packages, so there's no
# integrity pin to check here — just version freshness).
check_virtio_iso_cache() {
  local cache_dir="$1"
  local cached_iso cached_meta headers remote_name recorded_name

  cached_iso="$(find "${cache_dir}" -maxdepth 1 -name 'virtio-win-*.iso' 2>/dev/null | sort -V | tail -n1)"
  [[ -n "${cached_iso}" ]] || return 1

  cached_meta="${cached_iso}.meta"
  if [[ ! -f "${cached_meta}" ]]; then
    log "Found ${cached_iso} but it's missing its .meta sidecar — treating as untrusted, will re-download"
    return 1
  fi

  headers="$(curl -sI --max-time 20 -L "${VIRTIO_STABLE_URL}" 2>/dev/null)" || true
  remote_name="$(grep -i '^location:' <<<"${headers}" | tail -n1 | tr -d '\r' | sed -E 's#.*/##')"

  if [[ -z "${remote_name}" ]]; then
    log "Could not reach fedorapeople.org to check virtio-win currency (network issue?) — falling back to cached ISO"
    echo "${cached_iso}"
    return 0
  fi

  recorded_name="$(grep -E '^resolved_name=' "${cached_meta}" | cut -d= -f2-)"
  if [[ "${remote_name}" == "${recorded_name}" ]]; then
    log "Cached virtio-win driver ISO ($(basename "${cached_iso}")) matches the current stable release — using cache"
    echo "${cached_iso}"
    return 0
  fi

  log "A newer virtio-win driver ISO is published (${remote_name} vs cached ${recorded_name:-unknown}) — cache is stale"
  return 1
}

# Downloads the current stable virtio-win driver ISO into $1 (cache dir),
# records its own computed checksum (trust-on-download — no upstream
# checksum exists for the ISO itself) plus the resolved version in .meta,
# and prints the final cached path on stdout.
download_virtio_iso() {
  local cache_dir="$1"
  local headers remote_name dest tmp actual_sum

  headers="$(curl -sI --max-time 20 -L "${VIRTIO_STABLE_URL}")" \
    || fail "Could not reach fedorapeople.org to resolve the current virtio-win driver ISO"
  remote_name="$(grep -i '^location:' <<<"${headers}" | tail -n1 | tr -d '\r' | sed -E 's#.*/##')"
  [[ -n "${remote_name}" ]] || fail "Could not determine the current virtio-win ISO filename from ${VIRTIO_STABLE_URL}"

  dest="${cache_dir}/${remote_name}"
  tmp="$(mktemp "${dest}.XXXXXX.part")"
  log "Downloading virtio-win drivers (${remote_name})..."
  curl -fL --max-time 1800 -o "${tmp}" "${VIRTIO_STABLE_URL}" || { rm -f "${tmp}"; fail "Failed to download virtio-win ISO from ${VIRTIO_STABLE_URL}"; }

  actual_sum="$(sha256sum "${tmp}" | awk '{print $1}')"
  rm -f "${cache_dir}"/virtio-win-*.iso "${cache_dir}"/virtio-win-*.iso.sha256 "${cache_dir}"/virtio-win-*.iso.meta
  mv "${tmp}" "${dest}"
  echo "${actual_sum}  $(basename "${dest}")" > "${dest}.sha256"
  {
    echo "source_url=${VIRTIO_STABLE_URL}"
    echo "resolved_name=${remote_name}"
    echo "checked=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${dest}.meta"
  log "Cached fresh virtio-win ISO at ${dest}"
  echo "${dest}"
}

# WIN_ISO_PATH/WIN_ISO_CHECKSUM, if already set by the caller, always win
# over the cache (explicit override — e.g. testing against an arbitrary
# local file). Otherwise iso_cache/ is checked for currency and used if
# still current, or refreshed via download_windows_iso if not.
if [[ -n "${WIN_ISO_PATH:-}" ]]; then
  [[ -f "${WIN_ISO_PATH}" ]] || fail "WIN_ISO_PATH does not point to a file: ${WIN_ISO_PATH}"
  : "${WIN_ISO_CHECKSUM:?WIN_ISO_PATH is set but WIN_ISO_CHECKSUM is not — set it to the ISO checksum, e.g. sha256:abcd...}"
else
  log "Checking Windows ${WINDOWS_VERSION} install ISO cache/currency..."
  if ! WIN_ISO_PATH="$(check_windows_iso_cache "${WINDOWS_VERSION}" "${ISO_CACHE_DIR}")"; then
    WIN_ISO_PATH="$(download_windows_iso "${WINDOWS_VERSION}" "${ISO_CACHE_DIR}")"
  fi
  WIN_ISO_CHECKSUM="sha256:$(awk '{print $1}' "${WIN_ISO_PATH}.sha256")"

  if [[ "${WINDOWS_VERSION}" == "2025" ]]; then
    NOPROMPT_CACHE_DIR="${ISO_CACHE_DIR}/${NOPROMPT_CACHE_DIR_NAME}"
    STOCK_ISO_CHECKSUM="${WIN_ISO_CHECKSUM#sha256:}"
    log "Windows Server 2025: preparing _noprompt-patched install media (Finding 15)"
    if ! NOPROMPT_ISO_PATH="$(check_noprompt_iso_cache "${STOCK_ISO_CHECKSUM}" "${NOPROMPT_CACHE_DIR}")"; then
      NOPROMPT_ISO_PATH="$(build_noprompt_iso "${WIN_ISO_PATH}" "${STOCK_ISO_CHECKSUM}" "${NOPROMPT_CACHE_DIR}")"
    fi
    WIN_ISO_PATH="${NOPROMPT_ISO_PATH}"
    WIN_ISO_CHECKSUM="sha256:$(awk '{print $1}' "${NOPROMPT_ISO_PATH}.sha256")"
  fi
fi

# Same override-vs-cache logic for the virtio driver ISO. Unlike before,
# VIRTIO_ISO_PATH is no longer required to be set by the caller — it's
# self-managed via iso_cache/ same as the Windows ISO.
if [[ -n "${VIRTIO_ISO_PATH:-}" ]]; then
  [[ -f "${VIRTIO_ISO_PATH}" ]] || fail "VIRTIO_ISO_PATH does not point to a file: ${VIRTIO_ISO_PATH}"
else
  log "Checking virtio-win driver ISO cache/currency..."
  if ! VIRTIO_ISO_PATH="$(check_virtio_iso_cache "${ISO_CACHE_DIR}")"; then
    VIRTIO_ISO_PATH="$(download_virtio_iso "${ISO_CACHE_DIR}")"
  fi
fi

SERVICES_YAML_PATH="${SERVICES_YAML_PATH:-${REPO_ROOT}/services.yaml}"
[[ -f "${SERVICES_YAML_PATH}" ]] || fail "SERVICES_YAML_PATH does not point to a file: ${SERVICES_YAML_PATH}"

PACKER_EXTRA_VARS=(-var "windows_version=${WINDOWS_VERSION}" -var "iso_url=file://${WIN_ISO_PATH}" -var "iso_checksum=${WIN_ISO_CHECKSUM}" -var "services_yaml_path=${SERVICES_YAML_PATH}")

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

echo "==> Build complete. Disk artifact in ${OUTPUT_DIR}/"

# Off by default: Packer's QEMU builder never touches libvirt, so nothing
# is registered as a VM anywhere unless asked for explicitly. See
# register-vm.sh for what this actually does and why it's a separate
# script rather than folded into the packer build itself.
if [[ "${REGISTER_VM:-false}" == "true" ]]; then
  echo "==> Registering VM with libvirt (REGISTER_VM=true)"
  CPUS="${PKR_VAR_cpus:-4}" MEMORY_MB="${PKR_VAR_memory_size:-16384}" WINDOWS_VERSION="${WINDOWS_VERSION}" \
    "${REPO_ROOT}/register-vm.sh" "${VM_NAME}" "${OUTPUT_DIR}"
else
  echo "==> Not registered with libvirt/virt-manager (set REGISTER_VM=true to do so, or run ./register-vm.sh ${VM_NAME} afterward)"
fi

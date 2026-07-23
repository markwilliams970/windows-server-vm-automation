# Windows Server VM Automation

Fully unattended Windows Server 2022 lab builds on local KVM/libvirt: clean install media in,
a configured, validated Windows Server VM out — no manual installer clicks, no golden image,
disposable by design.

This README is the quick-start: install prerequisites, run a build, understand what you get.
For *why* the project is built this way, see [`CLAUDE.md`](CLAUDE.md). For the deep engineering
detail behind each script and what's still open, see [`ENGINEERING_GUIDE.md`](ENGINEERING_GUIDE.md).

---

## Status

| Phase | What it is | Status |
|---|---|---|
| 1 | Architecture, repo structure | Done |
| 2 | Unattended Windows install (Packer + QEMU/KVM) | Done for **Windows Server 2022**. Server 2025 and Windows 11 client are implemented but **blocked** on an unresolved upstream Packer/QEMU UEFI-boot issue — see [`WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`](WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md) Finding 15 and [`WINDOWS11_UNATTENDED.md`](WINDOWS11_UNATTENDED.md). |
| 3 | Role configuration (IIS, AD DS, SQL Server) via `services.yaml` | Done and independently verified, **one role at a time**, against the Server 2022 baseline. The worst-case combination — all three roles together — was tested twice and **fails**: SQL Server setup errors after IIS and AD DS both succeed; root cause not yet confirmed and this investigation is paused for now — see [`ENGINEERING_GUIDE.md`](ENGINEERING_GUIDE.md#next-steps--roadmap). An empty `services.yaml` remains untested separately. |
| 4 | Datadog Agent install/validation | Not started. |
| 5 | Lifecycle automation (build/verify/destroy tooling) | Not started — see [`ENGINEERING_GUIDE.md`](ENGINEERING_GUIDE.md#next-steps--roadmap). |
| 6 | Golden snapshot: 180-day build acceleration | Not started — a project goal, not yet designed in implementation detail. See `CLAUDE.md`'s Phase 6 section and [`ENGINEERING_GUIDE.md`](ENGINEERING_GUIDE.md#next-steps--roadmap) for the proposed mechanism. |

**Practical takeaway:** this project reliably builds a real Windows Server 2022 VM with any one
of IIS, Active Directory Domain Services, or SQL Server 2022 today. Everything else below
documents that working path.

---

## Prerequisites

Written for a clean Ubuntu/Debian-family host (developed and tested on Linux Mint 22.3 / Ubuntu
24.04-based). Adjust package names if you're on a different distro.

### 1. KVM/QEMU/libvirt

```bash
sudo apt update
sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
    bridge-utils ovmf xorriso curl
```

Add yourself to the groups that let you talk to libvirt/KVM without `sudo`, then **log out and
back in** (group membership only takes effect in a new login session):

```bash
sudo usermod -aG libvirt,kvm "$USER"
```

Verify:

```bash
virsh -c qemu:///system list --all
```

If that fails with a permission or connection error, `libvirtd` isn't running or your group
membership hasn't taken effect yet — don't proceed until this works.

Confirm OVMF (UEFI firmware) is present at the paths this project expects by default:

```bash
ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
```

The `_4M` variant ships on Ubuntu 24.02+/current Mint. If your distro's `ovmf` package doesn't
produce these exact filenames, find the equivalents under `/usr/share/OVMF/` and override them
via `packer/variables.pkr.hcl`'s `efi_firmware_code`/`efi_firmware_vars` (or `-var` flags —
see [Build variables reference](#build-variables-reference)).

### 2. Packer

Install the official HashiCorp apt repo, then the `packer` package:

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | \
    sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install packer
```

Verify:

```bash
packer version   # this project was built/tested against v1.15.4
```

You do **not** need to manually install the QEMU plugin — `build.sh` runs `packer init`, which
downloads `github.com/hashicorp/qemu` automatically on first run.

### 3. Disk space and network

- Windows Server 2022 Evaluation ISO: ~5 GB (auto-downloaded and cached under `iso_cache/`).
- `virtio-win.iso` (VirtIO drivers): under 1 GB (also cached under `iso_cache/`).
- Output VM disk: up to 60 GB provisioned, but qcow2 is thin/compressed — actual builds land
  around 5 GB on disk.
- If you select the `sql-server` role, `install-sql-server.ps1` downloads the SQL Server 2022
  Developer Edition installer *inside the guest* during the build — budget several more GB and
  several more minutes for that role specifically.
- Outbound internet access is required (Microsoft's Windows ISO fwlink, the virtio-win stable
  release, and — if `sql-server` is selected — Microsoft's SQL Server bootstrapper).

### 4. Optional: GitHub CLI

Only needed if you intend to push this repo to a private GitHub remote yourself. Not required to
build or run anything.

---

## Quick start

```bash
git clone <this-repo> windows-server-vm-automation
cd windows-server-vm-automation

# Review/edit which roles this build installs — see below.
${EDITOR:-vi} services.yaml

./build.sh
```

That's it. `build.sh`:

1. Checks all prerequisites are present (`packer`, `qemu-img`, `virsh`, `xorriso`, `curl`,
   reachable libvirt).
2. Checks `iso_cache/` for a current Windows Server 2022 ISO and `virtio-win.iso`; downloads and
   caches whichever is missing or stale (compared against Microsoft's/fedorapeople.org's
   currently-published versions).
3. Extracts only the VirtIO driver variant this build needs (`vioscsi`, `viostor`, `NetKVM` for
   Server 2022) from the cached `virtio-win.iso`.
4. Runs `packer validate` then `packer build` against `packer/windows-server.pkr.hcl`, which:
   - Boots a UEFI QEMU/KVM VM from the Windows ISO plus a second, Packer-generated CD-ROM
     carrying `autounattend.xml` and the VirtIO drivers.
   - Lets Windows Setup run fully unattended (partitioning, driver injection, `Administrator`
     account, WinRM enablement).
   - Uploads `services.yaml` and `scripts/`, then runs `scripts/run-services.ps1`, which installs
     exactly the roles listed in `services.yaml`.
   - Reboots (handled by Packer's `windows-restart` provisioner) and runs
     `scripts/verify-post-reboot.ps1`, which checks anything that can only be verified after a
     reboot (currently: AD DS/DNS, if `ad-ds` was selected).
5. Leaves the finished VM disk under `packer/output/<vm_name>/`.

A build with no roles selected in `services.yaml` (or the file emptied to just comments) still
completes — it produces a bare Windows Server 2022 VM with no roles installed.

**Expected build time:** roughly 20–25 minutes for a bare build or one role, per
[`WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`](WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md)'s measured
runs. `sql-server` adds real extra time for its in-guest download+install step.

---

## Configuring `services.yaml`

`services.yaml` at the repo root is a flat YAML list under one `services:` key. Uncomment (or
add) the roles you want; each maps to one script under `scripts/`:

```yaml
services:
  - iis          # IIS Web Server role + default site
  - ad-ds        # Active Directory Domain Services + DNS, new forest/domain
  - sql-server   # SQL Server 2022 Developer Edition, Mixed Mode auth
```

| Role | Script | What it does | Verified standalone? |
|---|---|---|---|
| `iis` | `scripts/install-iis.ps1` | Installs the IIS Web Server role, confirms `W3SVC` is running, confirms the default site returns HTTP 200. | Yes |
| `ad-ds` | `scripts/install-ad.ps1` (+ `scripts/verify-post-reboot.ps1` after the reboot) | Promotes the server to the first Domain Controller of a **new forest**, with DNS installed alongside. Confirms `NTDS`/`DNS` services and `Get-ADDomain` succeed after the promotion reboot. | Yes |
| `sql-server` | `scripts/install-sql-server.ps1` | Downloads and installs SQL Server 2022 Developer Edition in Mixed Mode auth, confirms `MSSQLSERVER`/`SQLSERVERAGENT` are running, confirms a `SELECT 1` query succeeds over a SQL login. | Yes |

Each was built and confirmed working **individually**. All three together in one build (`iis` +
`ad-ds` + `sql-server` — the worst-case combination) was tested and currently **fails**: SQL
Server setup errors out after IIS and AD DS both succeed. Don't select all three in the same
`services.yaml` yet — see [`ENGINEERING_GUIDE.md`](ENGINEERING_GUIDE.md#next-steps--roadmap) for
what's known about the failure. The empty-`services.yaml` bare-server path remains untested
separately.

The domain name for `ad-ds` defaults to `corp.example.internal` and can be overridden:

```bash
PKR_VAR_domain_name=lab.internal ./build.sh
```

---

## Build variables reference

Set any of these as environment variables before running `build.sh` (the shell-level ones), or
as `PKR_VAR_<name>=...` (picked up automatically by Packer for anything defined in
`packer/variables.pkr.hcl`).

**`build.sh`-level (shell environment variables):**

| Variable | Default | Purpose |
|---|---|---|
| `WINDOWS_VERSION` | `2022` | Which profile in `packer/locals.pkr.hcl` to build. `2025` is defined but **blocked** — see Status above. |
| `ISO_CACHE_DIR` | `iso_cache/` at repo root | Where cached install/driver media lives. |
| `WIN_ISO_PATH` / `WIN_ISO_CHECKSUM` | unset | Set both to point at a specific local Windows ISO instead of the cache/download flow. |
| `VIRTIO_ISO_PATH` | unset | Set to point at a specific local `virtio-win.iso` instead of the cache/download flow. |
| `SERVICES_YAML_PATH` | `services.yaml` at repo root | Use an alternate services file for a given run. |
| `REGISTER_VM` | `false` | Set `true` to register the finished build as a libvirt domain automatically — see [Registering the VM with virt-manager](#registering-the-vm-with-virt-manager). |

**Packer-level (`PKR_VAR_<name>`, defined in `packer/variables.pkr.hcl`):**

| Variable | Default | Purpose |
|---|---|---|
| `domain_name` | `corp.example.internal` | FQDN for the new AD forest, if `ad-ds` is selected. |
| `admin_password` | `ChangeMe-Lab123!` | Local Administrator / WinRM password. A disposable-lab placeholder, not treated as a secret in this project — see `variables.pkr.hcl`'s own note. |
| `cpus` | `4` | VM vCPU count. |
| `memory_size` | `16384` | VM RAM in MB. |
| `disk_size` | `61440` | VM disk size in MB (thin-provisioned qcow2). |
| `headless` | `true` | Set `false` to see the QEMU display (e.g. via `virt-viewer`) during a build. |
| `winrm_timeout` | `45m` | How long Packer waits for WinRM to come up before failing. |
| `efi_firmware_code` / `efi_firmware_vars` | `/usr/share/OVMF/OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd` | Override if your distro's `ovmf` package uses different filenames. |
| `vm_name` | `win<version>-dc` | Output directory/computer name. |
| `iso_url` / `iso_checksum` / `product_key` / `windows_edition` / `virtio_os_dir` | per-version defaults in `locals.pkr.hcl` | Advanced per-field overrides — most people won't need these. |

Example combining both:

```bash
WINDOWS_VERSION=2022 PKR_VAR_domain_name=lab.internal PKR_VAR_cpus=2 ./build.sh
```

---

## Output and connecting to the VM

The finished disk lands at `packer/output/<vm_name>/<vm_name>.qcow2` (default
`packer/output/win2022-dc/win2022-dc.qcow2`), alongside a per-build `efivars.fd` (its UEFI NVRAM
state). This directory is gitignored — treat every build as disposable, per this project's core
design principle (see `CLAUDE.md`).

### Registering the VM with virt-manager

Packer's QEMU builder runs `qemu-system-x86_64` directly and never talks to libvirt, so a plain
`build.sh` run leaves you with that qcow2 file but **nothing registered in libvirt** — it won't
appear in `virt-manager` or `virsh list --all` on its own.

To fix that, either pass `REGISTER_VM=true` to `build.sh` so it happens automatically once the
build finishes:

```bash
REGISTER_VM=true ./build.sh
```

or run `register-vm.sh` yourself afterward, against any already-built output directory:

```bash
./register-vm.sh win2022-dc                       # uses packer/output/win2022-dc by default
```

This defines a libvirt domain (`virsh define`) using the same device model Packer built the disk
with — `q35` machine type, OVMF UEFI (the real code file plus *this build's own* `efivars.fd`, not
a shared template), `virtio-scsi` disk, `virtio-net` NIC on libvirt's `default` NAT network — so
the VirtIO drivers already installed in the guest keep working. The domain is left **shut off**;
start it yourself once it's showing up in virt-manager, or via:

```bash
virsh -c qemu:///system start win2022-dc
```

Because the network is now libvirt's own NAT network (DHCP), not the isolated networking Packer
used for WinRM during the build, expect the guest to come up with a different IP than it had
during provisioning — check `virsh -c qemu:///system domifaddr win2022-dc` once it's booted, then
connect over RDP as `Administrator` with the password set above (default `ChangeMe-Lab123!`).

Re-running `register-vm.sh` (or `REGISTER_VM=true ./build.sh` again) after a rebuild with the same
`vm_name` automatically replaces the old registration — matching this project's "rebuild the same
environment repeatedly" principle — but only if that old domain is shut off; it refuses to touch
one that's currently running.

---

## Verifying a build

There is no standalone `verify.sh`/`tests/*.ps1` yet (see
[`ENGINEERING_GUIDE.md`](ENGINEERING_GUIDE.md#next-steps--roadmap)) — today, verification of each
selected role happens *inline*, during the build itself: each `install-<role>.ps1` script checks
its own work and throws (failing the whole Packer build loudly) if something didn't come up
correctly. A `build.sh` run that finishes without error means every role you selected is confirmed
working at that moment.

To manually re-check after the fact (e.g. after rebooting the VM standalone):

- **IIS:** browse to the VM's IP over HTTP; you should get the default IIS page.
- **AD DS:** `Get-ADDomain` in an elevated PowerShell session on the VM, or `dsa.msc`.
- **SQL Server:** `sqlcmd -S localhost -U sa -P ChangeMe-Lab123!  -Q "SELECT 1"` (or your own
  `admin_password` override) from the VM, or connect with SSMS/Azure Data Studio from another
  machine if you've opened the firewall for TCP 1433.

---

## Faster role iteration during development

`dev/test-role.sh` boots a disposable copy-on-write overlay of a previously-captured Server 2022
baseline disk, instead of running a full ~20-minute install each time — useful if you're editing
`scripts/install-*.ps1` and want a few-minutes iteration loop. It is **not** part of the
documented build/verify/destroy workflow and the whole `dev/` directory is gitignored — see
`dev/README.md`.

---

## Repository structure

See `CLAUDE.md`'s [Repository Structure](CLAUDE.md#repository-structure) section for the full
annotated tree.

---

## Further reading

- [`CLAUDE.md`](CLAUDE.md) — project purpose, architectural principles, phased plan.
- [`ENGINEERING_GUIDE.md`](ENGINEERING_GUIDE.md) — how each script/provisioner actually works, a
  troubleshooting index into the engineering logs below, and the roadmap for what's left.
- [`WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`](WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md) — the
  full Phase 2 investigation log (every bug hit building the Server 2022/2025 unattended install,
  root-caused). Read before touching `packer/answer_files/autounattend.xml.pkrtpl` or
  `packer/windows-server.pkr.hcl`.
- [`WINDOWS11_UNATTENDED.md`](WINDOWS11_UNATTENDED.md) — the parallel Windows 11 client
  investigation, currently blocked on the same underlying issue as Server 2025.

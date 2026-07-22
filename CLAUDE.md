# CLAUDE.md

# Project: Windows Server 2022 Automated Lab Environment

## Purpose

This project creates a fully reproducible Windows Server 2022 test environment on KVM/libvirt.

The goal is not to create or maintain a golden image.

The goal is:

> Starting from a clean Windows Server 2022 installation source, automatically create a realistic Windows Server environment, configure enterprise services, validate functionality, and provide complete lifecycle automation to build and destroy the environment repeatedly.

The resulting environment is intended for:

- Datadog Agent testing
- Windows infrastructure monitoring
- Active Directory monitoring scenarios
- IIS monitoring
- Windows service troubleshooting
- Windows event log testing
- Performance counter testing
- Support engineering practice

The environment should be disposable and reproducible.

---

# Implementation Status

**Phase 1** (architecture) and **Phase 2** (unattended Windows install, Server 2022) are implemented and confirmed reliable under `packer/`, `build.sh` — a fully unattended build with no manual intervention has succeeded, including the WinRM auth fix (Finding 12) and the `oobeSystem`/`<Description>`-length fix (Finding 14) that blocked it initially. Windows Server 2025 is implemented but **blocked** on a known, unresolved upstream Packer/QEMU/OVMF boot issue — see Finding 15. Phase 2's detailed engineering log — every bug hit, how each was root-caused, and what's still open — lives in `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md` at the repo root. Read it before touching `packer/answer_files/autounattend.xml.pkrtpl` or `packer/windows-server.pkr.hcl`; several fixes in there (character encoding/length limits in unattend `<Description>` elements, `winrm.exe` boolean config syntax, driver file dependencies, CD-ROM vs. floppy delivery) are non-obvious and easy to accidentally regress.

**Phase 3** (Windows role configuration) is implemented and verified: IIS, AD DS, and SQL Server 2022 Developer Edition all work against the Server 2022 baseline, driven by `services.yaml` per the Service Selection design below. A Windows 11 client track was also attempted for both Phase 2 and Phase 3 (OS-aware `install-iis.ps1`) but is blocked by the same underlying issue as Server 2025 — see `WINDOWS11_UNATTENDED.md`. A separate project, `../windows-auto-build-pipeline/`, is pursuing an offline image-application approach to unblock both; see `HANDOFF_FROM_UNATTENDED_INSTALL.md` there.

**Phases 4-5** (Datadog integration, lifecycle automation) are not yet implemented.

---

# Architectural Principles

## Ephemeral Infrastructure

Every Windows Server instance should be considered temporary.

The expected lifecycle:

```
Create
  |
  v
Install Windows automatically
  |
  v
Configure services automatically
  |
  v
Validate functionality
  |
  v
Perform testing
  |
  v
Destroy completely
```

A successful outcome is the ability to recreate the same environment repeatedly.

Do not depend on manual GUI steps.

---

# Tool Responsibilities

Each tool should have a clear responsibility.

## Packer

Packer is used primarily for:

- unattended Windows installation
- QEMU/KVM VM creation
- VirtIO driver integration
- Windows bootstrap
- WinRM communication
- initial provisioning handoff

Packer is NOT being used to create a long-lived golden image.

Any generated VM artifact should be considered disposable.

The value of Packer is eliminating manual Windows installation complexity.

---

## QEMU/KVM/libvirt

Responsible for:

- virtualization
- VM lifecycle
- CPU/memory allocation
- disks
- networking
- device models

The environment should use appropriate virtualization devices:

- UEFI firmware
- VirtIO storage
- VirtIO networking
- QEMU Guest Agent

---

## OpenTofu

Use OpenTofu where it provides value.

Potential responsibilities:

- libvirt resource management
- network definitions
- VM lifecycle
- storage lifecycle
- repeatable infrastructure deployment

Do not add OpenTofu complexity if Packer and libvirt commands are sufficient.

Prefer simplicity.

---

## PowerShell

PowerShell is responsible for Windows configuration.

All Windows configuration should be:

- automated
- repeatable
- idempotent where possible
- logged clearly

Avoid:

- manual GUI configuration
- undocumented registry modifications
- fragile one-time commands

---

# Target Platform

## Host

Expected host environment:

- Linux Mint / Ubuntu-based Linux
- KVM enabled
- QEMU installed
- libvirt configured

## Guest

Windows:

- Windows Server 2022 Evaluation
- UEFI boot
- VirtIO devices
- QEMU Guest Agent

---

# Windows Server Configuration Goals

The final server should resemble a realistic enterprise Windows environment.

## Service Selection

**Design decision (post-Phase-2, pre-Phase-3):** roles are not all installed on every build. Few real Windows Server deployments layer AD DS + IIS + other roles on a single box — most are single-purpose. Bundling everything by default doesn't reflect realistic customer environments to test against, particularly for FedRAMP/GovCloud-style scenarios this lab is meant to simulate.

Instead, which roles a given build installs is controlled by a YAML config file (e.g. `services.yaml` at the repo root, or passed via a build variable), something like:

```yaml
services:
  - ad-ds      # Active Directory Domain Services + DNS, new forest/domain
  - iis        # IIS Web Server role + default site
  # - sql-server   (future)
```

Each entry maps to one provisioning script under `scripts/` (e.g. `install-ad.ps1`, `install-iis.ps1`). The build only runs the scripts for roles actually listed. A build with an empty or minimal `services.yaml` should still succeed — it just produces a bare Windows Server with the Datadog Agent and nothing else, which is itself a valid, realistic environment to simulate.

This is a design decision only — not yet implemented. It supersedes the earlier assumption (visible in the subsections below) that AD DS and IIS are both always configured. Treat the "Active Directory" and "IIS" subsections as *available roles*, each gated behind `services.yaml` selection, not as unconditional requirements of every build.

---

## Active Directory

When `ad-ds` is selected, automatically configure:

- Active Directory Domain Services
- DNS Server role
- New forest/domain

The domain should be configurable.

Example:

```
corp.example.internal
```

Requirements:

- Promote server to Domain Controller automatically
- Handle required reboots
- Verify AD services after promotion

---

## IIS

When `iis` is selected, automatically configure:

- IIS Web Server role
- Common IIS features
- Default website

Validation:

- IIS service running
- HTTP request succeeds

---

## Datadog Agent

The Datadog Agent must be automatically installed.

Credentials must never be stored in source control.

The build must accept:

```
DD_API_KEY
DD_SITE
```

Example:

```
DD_SITE=ddog-gov.com
```

The Agent installation must:

- download/install automatically
- configure the API key
- configure the site
- start the service
- survive reboots

---

# Datadog Validation Requirements

The build is not successful until Datadog functionality is validated.

Validation should include:

- Windows service exists
- Datadog Agent service is running
- Agent status is healthy
- Agent connectivity succeeds
- Host registration is confirmed if practical

The implementation should clearly report failures.

---

# Repository Structure

Use a clear structure similar to:

```
windows-lab/

├── README.md                                   # quick start: prerequisites, build, services.yaml, verifying a build
├── ENGINEERING_GUIDE.md                        # script/provisioner mechanism detail, troubleshooting index into the logs below, roadmap
├── CLAUDE.md
├── WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md   # Phase 2 engineering log (Server 2022/2025) — read before editing packer/answer_files/autounattend.xml.pkrtpl
├── WINDOWS11_UNATTENDED.md                    # Windows 11 client engineering log — currently blocked, see its Open Issues before touching packer-windows11/
├── services.yaml                              # which roles this build installs (see Service Selection)
├── build.sh                                    # Windows Server 2022/2025 build entrypoint
├── build-windows11.sh                          # Windows 11 client build entrypoint — separate from build.sh, see WINDOWS11_UNATTENDED.md for why
├── register-vm.sh                              # registers an already-built disk as a libvirt domain (virt-manager visibility) — Packer's qemu builder never does this itself; also invoked by build.sh when REGISTER_VM=true
├── iso_cache/                                  # all cached binary install media (Windows ISOs, virtio-win ISO)
│   ├── <name>.iso                              # gitignored (*.iso); build.sh/build-windows11.sh check currency vs. public source first
│   ├── <name>.iso.sha256                       # sha256sum-format checksum sidecar, tracked in git
│   └── <name>.iso.meta                         # source URL + upstream freshness fingerprint (ETag/version), tracked in git

├── packer/                            # Windows Server 2022/2025
│   ├── windows-server.pkr.hcl
│   ├── variables.pkr.hcl
│   ├── locals.pkr.hcl                # per-Windows-version defaults (ISO URL/checksum, edition, KMS key)
│   └── answer_files/
│       └── autounattend.xml.pkrtpl   # templatefile()-rendered; see the Phase 2 doc above before editing

├── packer-windows11/                  # Windows 11 client — separate directory, not a third source in packer/
│   ├── windows11.pkr.hcl             # fully-manual qemuargs (not native fields) for most drives — see WINDOWS11_UNATTENDED.md before editing
│   ├── variables.pkr.hcl
│   └── answer_files/
│       └── autounattend-windows11.xml.pkrtpl

├── scripts/
│   ├── run-services.ps1              # Phase 3 orchestrator — reads services.yaml, dispatches to install-<role>.ps1
│   ├── install-iis.ps1                # OS-aware: Install-WindowsFeature (Server) vs Enable-WindowsOptionalFeature (client)
│   ├── install-ad.ps1                 # Server-only; needs the reboot handoff to windows-restart, see run-services.ps1's caller
│   ├── install-sql-server.ps1         # Server-only
│   ├── verify-post-reboot.ps1         # always invoked; no-ops unless install-ad.ps1's marker file is present
│   ├── install-datadog.ps1            # Phase 4, not yet implemented
│   └── cleanup.ps1                    # Phase 5, not yet implemented

├── tofu/                # only if OpenTofu ends up providing real value — currently unused, Packer + libvirt suffice
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf

├── tests/
│   ├── verify-connectivity.ps1
│   ├── verify-iis.ps1
│   ├── verify-ad.ps1
│   └── verify-datadog.ps1

└── docs/
    └── architecture.md
```

Adjust this structure if there is a strong technical reason. (This reflects what actually exists after Phase 2, not just the original plan — `packer/` doesn't have its own `scripts/` subdirectory since Phase 3+ provisioning runs as ordinary Packer `powershell` provisioners uploading straight from the top-level `scripts/`, not staged via removable media the way the Phase 2 bootstrap files are.)

---

# Lifecycle Requirements

The project must support:

## Build

A documented process that:

1. Validates prerequisites.
2. Uses Windows Server 2022 installation media.
3. Creates a VM.
4. Performs unattended installation.
5. Installs required drivers.
6. Enables remote management.
7. Configures Windows roles.
8. Installs Datadog Agent.
9. Runs validation.

---

## Verify

The project must provide explicit validation commands.

Verification should test:

- VM accessibility
- Windows services
- Active Directory (only if `ad-ds` was selected in `services.yaml`)
- IIS (only if `iis` was selected in `services.yaml`)
- Datadog Agent (always — installed regardless of `services.yaml` selection)

---

## Destroy

The project must provide complete cleanup.

Destroy should remove:

- VM definitions
- VM disks
- temporary resources
- transient configuration

Destroy should be safe to execute repeatedly.

---

# Development Approach

Work incrementally.

Do not generate the entire implementation immediately.

Build and validate each phase.

---

# Phase 1: Architecture and Repository

Deliver:

- repository structure
- tool decisions
- dependency list
- workflow documentation

Do not generate large code blocks yet.

---

# Phase 2: Automated Windows Installation

Implement:

- Packer configuration
- QEMU builder
- unattended installation
- VirtIO integration
- WinRM/bootstrap

Success criteria:

A Windows Server 2022 VM installs without manual interaction.

**Status:** implemented under `packer/` and `build.sh`, and confirmed: a fully unattended build (no manual intervention at any point) completes in ~18 minutes, per `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`'s Finding 14. Only one such confirmed run exists so far — see that doc's Open Issues before treating reliability as fully proven across many runs. Windows Server 2025 uses the same template but is blocked on a separate, known upstream issue (Finding 15) unrelated to anything in this phase's own scope.

---

# Phase 3: Windows Configuration

Implement:

- PowerShell provisioning
- Role installation driven by `services.yaml` (see Service Selection, above) rather than always installing every role
- IIS installation script (runs only if `iis` is selected)
- Active Directory installation script (runs only if `ad-ds` is selected)
- DNS configuration (part of the `ad-ds` script)

Success criteria:

The Windows server has exactly the services listed in `services.yaml` running — no more, no less. A build with no roles selected still succeeds, producing a bare Windows Server with just the Datadog Agent (Phase 4).

**Status:** implemented and verified under `scripts/`. `run-services.ps1` orchestrates role dispatch from `services.yaml`; `install-iis.ps1` (OS-aware — also usable on Windows 11 client SKUs once that track unblocks), `install-ad.ps1` + `verify-post-reboot.ps1` (AD DS promotion, including the reboot handoff to Packer's `windows-restart` provisioner), and `install-sql-server.ps1` (SQL Server 2022 Developer Edition, Mixed Mode auth) are all independently confirmed working against the Server 2022 baseline. The "no roles selected still succeeds" and "multiple roles together" cases are not yet explicitly tested, only individually.

---

# Phase 4: Datadog Integration

Implement:

- runtime secret injection
- Agent installation
- configuration
- validation

Success criteria:

Datadog Agent is healthy.

---

# Phase 5: Lifecycle Automation

Implement:

- build workflow
- verification workflow
- destroy workflow

Success criteria:

The environment can be repeatedly created and destroyed.

---

# Engineering Standards

Prefer:

- simple designs
- explicit commands
- readable scripts
- strong documentation
- reproducibility

Avoid:

- unnecessary abstractions
- hidden dependencies
- manual intervention
- storing secrets
- overly complex frameworks

---

# Claude Instructions

Before generating significant implementation code:

1. Explain the proposed design.
2. Identify assumptions.
3. Identify risks.
4. Ask questions where requirements are unclear.

Do not produce a large monolithic implementation.

Work in phases.

Optimize for maintainability and reproducibility.

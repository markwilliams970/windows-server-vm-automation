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

Phase 1 (architecture) and Phase 2 (unattended Windows install) are implemented under `packer/`, `build.sh`. Phase 2's detailed engineering log — every bug hit, how each was root-caused, and what's still open — lives in `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md` at the repo root. Read it before touching `packer/answer_files/autounattend.xml.pkrtpl` or `packer/windows-server.pkr.hcl`; several fixes in there (character encoding in unattend `<Description>` elements, `winrm.exe` boolean config syntax, driver file dependencies, CD-ROM vs. floppy delivery) are non-obvious and easy to accidentally regress.

Phases 3-5 (Windows role configuration, Datadog integration, lifecycle automation) are not yet implemented. See the "Service Selection" note under Windows Server Configuration Goals below for a design change made before Phase 3 started.

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

├── README.md
├── CLAUDE.md
├── WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md   # Phase 2 engineering log — read before editing autounattend.xml.pkrtpl
├── services.yaml                              # which roles this build installs (see Service Selection) — Phase 3, not yet implemented
├── build.sh

├── packer/
│   ├── windows-server.pkr.hcl
│   ├── variables.pkr.hcl
│   ├── locals.pkr.hcl                # per-Windows-version defaults (ISO URL/checksum, edition, KMS key)
│   └── answer_files/
│       └── autounattend.xml.pkrtpl   # templatefile()-rendered; see the doc above before editing

├── scripts/
│   ├── install-datadog.ps1
│   ├── install-iis.ps1
│   ├── install-ad.ps1
│   ├── verify.ps1
│   └── cleanup.ps1

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

**Status:** implemented under `packer/` and `build.sh`. One full build has succeeded end-to-end (with one manual live intervention for a bug since fixed in the template); the very next attempt, with that fix templated in and no manual steps, timed out waiting for WinRM. Not yet confirmed reliably unattended — see the Open Issues section of `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md` before treating this phase as fully closed out. A clean, undisturbed confirmation run is the next step.

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

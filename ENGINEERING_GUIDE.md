# Engineering Guide

This is the "how it actually works, and what's not done yet" document for engineers picking up
this project. [`README.md`](README.md) is the quick-start; the two Phase 2 investigation logs
(`WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`, `WINDOWS11_UNATTENDED.md`) are the exhaustive
bug-by-bug record. This document sits between them: enough mechanism detail to modify Phase 3
scripts confidently, a pointer index into the investigation logs so you don't have to read 290
lines to find the one Finding you need, and an honest roadmap of what's left.

---

## How a build actually flows

```
build.sh
  │
  ├─ prereq checks (packer, qemu-img, virsh, xorriso, curl, libvirt reachable)
  ├─ iso_cache/ currency check + download (Windows ISO, virtio-win.iso)
  ├─ xorriso-extract only the needed virtio driver variant (vioscsi/viostor/NetKVM)
  │
  └─ packer build packer/windows-server.pkr.hcl
       │
       ├─ QEMU boots: Windows ISO (CD 1) + Packer-generated "unattend" CD (CD 2:
       │  autounattend.xml + virtio drivers)
       ├─ boot_command spams <spacebar> for ~25s to catch the UEFI "press any key"
       │  prompt (timing is unpredictable — see Finding 1)
       ├─ Windows Setup runs unattended off autounattend.xml.pkrtpl:
       │    windowsPE pass   → partitions disk, injects vioscsi (Setup needs to see
       │                        the disk at all)
       │    specialize pass  → injects NetKVM (so the installed OS's driver store has
       │                        it for PnP matching post-boot)
       │    oobeSystem pass  → Administrator account, FirstLogonCommands bring up
       │                        WinRM (winrm quickconfig, Basic auth, firewall rule)
       ├─ Packer's WinRM communicator connects once FirstLogonCommands finish
       ├─ provisioner "file": services.yaml → C:\Windows\Temp\services.yaml
       ├─ provisioner "file": scripts/      → C:\Windows\Temp\scripts\
       ├─ provisioner "powershell": run-services.ps1 -DomainName <domain_name>
       │     → dispatches to install-<role>.ps1 for each role in services.yaml
       ├─ provisioner "windows-restart"  (always runs — see below for why)
       ├─ provisioner "powershell": verify-post-reboot.ps1
       │     → no-ops unless install-ad.ps1 left its marker file
       └─ shutdown_command → qemu-img convert -c compresses the final qcow2
```

### Why the reboot provisioner always runs, even if `ad-ds` wasn't selected

Packer's HCL provisioner list is static — it can't be conditionally included based on a value
inside `services.yaml`, which is only parsed at runtime by PowerShell. Rather than trying to hack
around that in HCL, the design puts the decision inside the scripts themselves
(`run-services.ps1` decides what to install, `verify-post-reboot.ps1` decides what to verify) and
accepts a fixed, always-present `windows-restart` provisioner as a no-op cost when nothing needed
it. This is the same "PowerShell decides, HCL stays static" pattern used in both provisioning
scripts — recognize it if you're adding a fourth role.

### Why `install-ad.ps1` doesn't verify its own work

`Install-ADDSForest` is called with `-NoRebootOnCompletion` specifically so the reboot happens
under Packer's `windows-restart` provisioner (which knows how to survive a WinRM disconnect and
reconnect), not as an uncontrolled reboot in the middle of the still-running `powershell`
provisioner — that would just drop the connection with no recovery path. But that also means AD
DS/DNS genuinely aren't up yet when `install-ad.ps1` returns. It leaves a marker file
(`C:\Windows\Temp\.ad-ds-installed`) and defers all real verification (`NTDS`/`DNS` service state,
`Get-ADDomain`) to `verify-post-reboot.ps1`, which runs after the restart.

---

## Per-script reference

### `scripts/run-services.ps1` — the orchestrator

Parses `services.yaml` with a plain regex (`^-\s*([A-Za-z0-9_-]+)`), not a YAML library —
deliberate, since the file's shape (a flat list under one key) doesn't need one. For each role
found, it resolves `install-<role>.ps1` by convention, with one explicit override:
`ad-ds → install-ad.ps1` (`$roleScriptOverrides` hashtable at the top of the script — add entries
here if a future role's YAML name doesn't mechanically match its script filename). Missing scripts
are a warning + skip, not a hard failure. Any role script throwing collects into `$failedRoles`
and is only re-raised (failing the whole provisioner) after every role has had a chance to run —
so one broken role doesn't prevent you from seeing whether the others also failed in the same
run.

Adding a fifth role: write `scripts/install-<role>.ps1` following the existing scripts' shape
(install, then verify inline, `throw` on anything unexpected), add it to `services.yaml`'s
comments/example, and add a row to the README's role table. No orchestrator changes needed unless
the YAML key doesn't match the filename convention.

### `scripts/install-iis.ps1`

OS-aware by design: `Install-WindowsFeature`/`Get-WindowsFeature` are Server-only cmdlets and
don't exist on client SKUs, which instead need the DISM-backed
`Enable-WindowsOptionalFeature`/`Get-WindowsOptionalFeature`. The script branches on
`(Get-ComputerInfo).OsProductType` so the same `iis` entry in `services.yaml` works unchanged if
this is ever pointed at a Windows 11 client build once that track unblocks (see
`WINDOWS11_UNATTENDED.md`). Verification is a real HTTP GET to `http://localhost/`, not just a
service-state check — a "feature says Installed but the site 500s" scenario would otherwise pass
silently.

### `scripts/install-ad.ps1` + `scripts/verify-post-reboot.ps1`

See "Why `install-ad.ps1` doesn't verify its own work," above. The DSRM password is hardcoded to
the same placeholder as the local Administrator/WinRM password — intentional, to keep this lab to
one password to remember, and consistent with this project's stance that these are disposable-lab
placeholders, not real secrets (see `variables.pkr.hcl`'s `admin_password` description).
`-SkipPreChecks -Force` are both necessary for unattended promotion in this single-NIC,
no-existing-forest lab context; don't remove them without understanding what prechecks they're
bypassing (mainly: DNS delegation warnings that don't apply to a brand-new forest).

### `scripts/install-sql-server.ps1`

The one role script that reaches out to the internet *during* provisioning (downloads the
Developer Edition bootstrapper, then uses it to download the full ISO media, then mounts and
installs from that). Developer Edition — not Express — was chosen specifically because it
includes SQL Server Agent, which a realistic enterprise box (and Datadog's own SQL Server
integration, which watches job/agent state) would have. Two non-obvious details if you touch this
script:

- `/UPDATEENABLED=False` is required whenever `/Q` (quiet) is passed — without it, setup tries to
  check Windows Update for product updates as part of unattended install and fails with
  `0x876E0003` in this network-isolated lab context.
- Account names with spaces (`"NT AUTHORITY\NETWORK SERVICE"`) must carry their own embedded
  quotes in the `$setupArgs` array elements. `Start-Process -ArgumentList` does not auto-quote
  array elements, so an unquoted value gets split into multiple broken argv tokens by the child
  process's own parser — this specific bug produced a generic, unhelpful `0x80004003` (`E_POINTER`)
  from `setup.exe` and cost real debugging time to trace back to quoting.

Verification connects as `sa` over Mixed Mode auth and runs `SELECT 1` — confirms not just that
the service is running, but that SQL auth is actually configured and reachable, which is the
precondition most downstream Datadog SQL Server integration testing will need.

---

## `build.sh` internals worth knowing

- **ISO currency, not just presence.** `check_windows_iso_cache`/`check_virtio_iso_cache` don't
  just check a cached file exists — they compare against what's *currently* published (an HTTP
  `ETag` for the Windows ISO fwlink, the resolved redirect filename for virtio-win's stable
  symlink) before trusting the cache. A stale cache is re-downloaded automatically; a checksum
  mismatch on a fresh download is a hard failure (`fail`), not a warning — see
  `download_windows_iso`.
- **`profile_field()` is deliberately plain `grep`/`sed`, not `awk`'s `match()` capture-array
  extension** — Ubuntu/Mint's default `/usr/bin/awk` is `mawk`, which doesn't support it. If you
  extend `locals.pkr.hcl`'s per-version profile map, keep the `"<version>" = { ... }` block shape
  this function's `grep -A 10` depends on.
- **`log()` writes to stderr, not stdout, on purpose.** Several `build.sh` functions
  (`check_windows_iso_cache`, `download_windows_iso`, etc.) are called via `$(...)` command
  substitution specifically to capture a resolved file path on stdout — any progress output that
  leaked onto stdout would corrupt that captured value.
- **Only the one virtio driver variant actually needed gets extracted** (`vioscsi`/`viostor`/
  `NetKVM` for the specific `WINDOWS_VERSION`, not every OS folder virtio-win.iso ships), and only
  `.pdb` (debug symbols) get filtered out of that — see `windows-server.pkr.hcl`'s comment on why
  more aggressive filtering isn't safe (`netkvm.inf`'s `CopyFiles` directive needs `netkvmp.exe`
  alongside `netkvm.sys`, a dependency that cost real debugging time when deleted).

---

## `register-vm.sh` internals worth knowing

Packer's QEMU builder runs `qemu-system-x86_64` directly, entirely bypassing libvirt — no domain
is ever registered as a side effect of `build.sh`, which is why a finished build doesn't show up
in virt-manager. `register-vm.sh` closes that gap after the fact, as a deliberately separate
script (build.sh's job stays "produce a disposable disk artifact"; libvirt lifecycle is its own
concern, per `CLAUDE.md`'s tool-responsibility split).

- **Hand-rolled domain XML, not `virt-install`.** `virt-install`'s CLI flag syntax for pinning an
  exact `loader`/`nvram` pair (rather than letting it auto-select/copy a template) has shifted
  across versions; a small heredoc template mirroring exactly what Packer's qemu builder used
  (`q35`, OVMF code + this build's own `efivars.fd`, `virtio-scsi`, `virtio-net`) is simpler and
  more predictable than chasing that flag surface. Same instinct as `autounattend.xml.pkrtpl`
  elsewhere in this repo.
- **`virsh undefine` needs an explicit nvram choice once a domain has one.** Plain `virsh undefine`
  refuses outright on a domain with an `<nvram>` element — it forces a choice between `--nvram`
  (delete the file) and `--keep-nvram` (leave it). This script always uses `--keep-nvram`: on a
  re-register, the domain's nvram path is `OUTPUT_DIR/efivars.fd`, which the *new* Packer build has
  already overwritten with fresh UEFI vars by the time re-registration runs — `--nvram` would
  delete the file the new build just wrote, not some stale leftover. Confirmed directly: an
  `--nvram` attempt during development did exactly that.
- **Refuses to touch a running domain.** Re-registering after a rebuild is the expected common
  case (same `vm_name` every time), but only auto-replaces a domain that's `shut off` — a
  `running`/`paused` domain fails loudly instead of being silently destroyed.
- **Network is libvirt's `default` NAT network, not Packer's build-time networking.** Packer's own
  build used QEMU's isolated usermode networking (with WinRM port-forwarded in) to provision the
  VM — that's gone once it's a normal libvirt domain. The guest gets a fresh DHCP lease on
  `default` and a different IP; there's no way to predict it in advance, only to check
  `virsh domifaddr <name>` after boot.

---

## Troubleshooting index

If a build fails, check whether it's a known, already-root-caused issue before re-investigating
from scratch. Findings are in `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md` unless marked otherwise.

| Symptom | Likely cause | See |
|---|---|---|
| VM never boots off the install ISO at all; falls through to PXE/UEFI shell | UEFI "press any key" timing miss | Finding 1 (Server 2022 — fixed by the spacebar-spam `boot_command`); Finding 15 / `WINDOWS11_UNATTENDED.md` Finding W3 (Server 2025 / Win11 — **unresolved**, do not re-tune `boot_wait`/`boot_command` without new evidence) |
| Whole VM fails to start, weird `-drive` errors | `qemuargs` used instead of native fields | Finding 2 |
| Copied driver files present on the CD but `pnputil`/Setup can't read them | Permission bits or read timing | Finding 3 (xorriso read-only inheritance), Finding 7 (media not immediately readable) |
| Two QEMU processes, VNC behaving strangely | Orphaned process from a prior run | Finding 4 — always `ps aux \| grep qemu-system-x86_64` before a new build |
| "No images are available" in Setup's edition picker | Mismatched `<ProductKey>` against eval media, not the CD-ROM itself | Finding 5 |
| NIC never comes up in the installed OS | Driver declared in the wrong unattend pass | Finding 6 |
| Driver install fails right after boot, works if retried | Media not instantly readable | Finding 7 |
| `pnputil` fails on a specific `.sys` file only, "cannot find file specified" | Floppy delivery flakiness (large files) or a missing dependency file | Finding 8, Finding 9 (`netkvmp.exe`) |
| OOBE hangs waiting for input | `SkipUserOOB`/`SkipMachineOOB` typo | Finding 10 |
| `oobeSystem` parse failure | Non-ASCII/quote characters *or* `<Description>` length | Finding 11, Finding 13 (partially wrong — kept for context), **Finding 14 is the real fix** — check `<Description>` length (>~200 chars is suspect) before anything else |
| WinRM never comes up, Basic auth seems ignored | `winrm set` boolean syntax | Finding 12 — must be the string `"true"`, not PowerShell `$true` |
| Build works once, then fails the same way again | Only one clean unattended run has ever been confirmed | `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md` Open Issue 1 — don't assume full reliability yet |

Operating notes worth internalizing (full detail in that doc's "Practical Operating Notes"
section): never connect a VNC client while `boot_command` is being typed (only one VNC client is
supported and it can knock Packer's own connection off); always `rm -rf packer/output` and check
for orphaned `qemu-system-x86_64` processes before a new build; kill a stuck build with `kill -9`
if you need the qcow2 to survive for forensics (plain `kill`/SIGTERM lets Packer run its own
cleanup, which deletes `packer/output/`).

---

## Next steps / roadmap

In priority order, based on what's actually blocking real use of this lab:

### 1. Combined-role builds: known-failing, root cause paused pending forensics

Every role (`iis`, `ad-ds`, `sql-server`) is confirmed working **individually** against the Server
2022 baseline. The worst-case combination — all three together — was tested twice via
`dev/test-role.sh` against `dev/baseline/win2022-dc.qcow2` (a `dev/test-services-all.yaml` with
all three roles uncommented), once at the dev harness's original 8GB memory allocation and once
at 16GB (matching production's `packer/variables.pkr.hcl` default):

- **Both runs, identical result:** `iis` installs and verifies successfully, `ad-ds` promotion
  configures successfully, then `sql-server` setup fails with the identical exit code
  `-2068119551`, at the identical point — roughly 16 minutes in, right after mounting the
  downloaded SQL Server media and launching `setup.exe`.
- **Identical failure at both memory levels rules out resource pressure as the cause.** Bumping
  `dev/role-test.pkr.hcl`'s `memory` from 8192 to 16384 changed nothing.
- **Leading unconfirmed hypothesis:** SQL Server setup runs while the machine is in AD DS's
  post-promotion, pre-reboot state. `install-ad.ps1` calls `Install-ADDSForest
  -NoRebootOnCompletion` deliberately (see "Why `install-ad.ps1` doesn't verify its own work,"
  above) — the actual reboot only happens later, in Packer's `windows-restart` provisioner, after
  every role in `run-services.ps1` has run. So by the time `sql-server` installs, the box is in a
  real, non-default in-between state (DNS Server role just installed, forest configuration written
  but not yet active) — not nothing, and a plausible source of the interaction.
- **Root cause is not actually confirmed, only hypothesized** — Packer's default on-error behavior
  tears down the VM and deletes `dev/output/` the instant a provisioner throws, so the one file
  that would say what really happened,
  `C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt`, has been
  unrecoverable both times.
- **This investigation is deliberately paused here.** The worst-case combination has been tried
  and the failure is documented as a known limitation — not a silent gap — but going from
  hypothesis to confirmed cause needs the VM preserved on failure, which hasn't been done yet. If
  picked back up: re-run with `packer build -on-error=abort` added to `dev/test-role.sh` (the VM
  stays running instead of being torn down) and read `Summary.txt` directly off it — either over
  WinRM/RDP before manually tearing it down, or by mounting the disk read-only (same NBD procedure
  `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`'s Practical Operating Notes already documents for
  post-mortem forensics on a preserved Phase 2 failure).
- **Until root-caused, don't select `iis` + `ad-ds` + `sql-server` together** in a real
  `services.yaml` — README's role table and Status section both flag this.
- The empty/all-commented `services.yaml` "bare server" path remains untested separately, and is
  unrelated to this finding — `run-services.ps1` has an explicit early-exit for zero roles, but it
  has never actually been driven by a real `packer build` run either.

### 2. Phase 4 — Datadog Agent integration

Not started. Per `CLAUDE.md`'s requirements:

- Accept `DD_API_KEY`/`DD_SITE` at build time without ever writing them to source control — likely
  as `PKR_VAR_` values passed through the environment at `./build.sh` invocation time, the same
  pattern `domain_name` already uses, *not* baked into `services.yaml` or any committed file.
- A new `scripts/install-datadog.ps1`, dispatched unconditionally (like the Datadog Agent itself
  is meant to be — CLAUDE.md is explicit that it's installed regardless of `services.yaml`
  role selection), using Datadog's official Windows install script/MSI.
- Validation needs to be real, not just "service exists": service running, `datadog-agent status`
  reporting healthy, and connectivity/host-registration confirmed against the configured `DD_SITE`
  (e.g. `ddog-gov.com` for GovCloud scenarios — see `CLAUDE.md`'s FedRAMP/GovCloud framing for why
  that matters here specifically).
- This is a good candidate for its own `tests/verify-datadog.ps1` (see Phase 5 below) so Datadog
  health can be checked standalone, not only inline during the build.

### 3. Phase 5 — lifecycle automation

Not started. Two concrete gaps:

- **`tests/` is currently empty**, despite being in `CLAUDE.md`'s target repo structure. Today,
  verification is entirely inline (each `install-<role>.ps1` throws on its own failures during the
  build) — there's no way to re-verify a build after the fact without re-running Packer. Standalone
  scripts worth writing: `verify-connectivity.ps1` (VM reachable at all), `verify-iis.ps1`,
  `verify-ad.ps1`, `verify-datadog.ps1` (blocked on Phase 4 existing first) — each usable against
  an already-running VM, driven by the same `services.yaml` to know what *should* be present.
- **No `destroy.sh`.** Tearing down a build today means manually finding and killing orphaned
  `qemu-system-x86_64` processes and `rm -rf packer/output` — noted as a known gap as far back as
  Phase 2's own Open Issues. A real `destroy.sh` should undefine any registered libvirt domain,
  remove its disk(s), and be safe to run repeatedly (a no-op if there's nothing to destroy),
  matching `CLAUDE.md`'s Destroy lifecycle requirement.

### 4. Phase 6 — golden snapshot (180-day eval window)

Not started; recorded as a project goal per `CLAUDE.md`'s Phase 6 section. Windows Server
Evaluation media's real ~180-day license window (from install completion, not ISO download) means
a completed unattended install — the golden snapshot — can be reused as the starting point for a
lot of rapid Phase 3+ prototyping before it needs to be redone from scratch. This is the real
payoff: build cycles collapse from ~20-25 minutes of Setup down to however long service-layering
itself takes.

Proposed mechanism:

- Right after a Phase 2 build finishes (before any Phase 3 role provisioners run), capture the
  golden snapshot — that clean, unconfigured disk — plus the date/time it was taken. Likely a new
  `image_cache/` directory, sidecar-metadata pattern mirroring `iso_cache/`'s existing
  `.sha256`/`.meta` convention (see `build.sh`'s `check_windows_iso_cache`/`download_windows_iso`
  for the shape to follow — a currency check that falls back to a real rebuild when stale).
- Any build within the golden snapshot's 180-day window starts from it via a copy-on-write overlay
  instead of a fresh install — the exact mechanism `dev/role-test.pkr.hcl` already uses
  (`disk_image = true`, `use_backing_file = true`) for local role-script iteration, just promoted
  from a dev-only, manually-refreshed harness to a first-class, automatically-aged part of
  `build.sh` itself.
- Past 180 days, the golden snapshot expires and the next build does a full install from ISO media
  again, capturing a fresh one for the next window.
- Worth deciding at implementation time: whether this shares a mechanism with `dev/baseline`
  (today unbounded and manually refreshed, per `dev/README.md`) or stays a separate, parallel
  cache — they solve related but distinct problems (dev-only fast iteration vs. a
  production-facing, expiring build accelerator).

### 5. Server 2025 / Windows 11 (lower priority, blocked on upstream)

Both are blocked on the same unresolved upstream Packer/QEMU/OVMF UEFI boot-key issue (Finding 15
/ Finding W3) — not something fixable from this project alone without new evidence. The sibling
project, `../windows-auto-build-pipeline/`, is independently pursuing an offline image-application
approach (WinPE + direct disk apply, bypassing Setup.exe's boot path entirely) to unblock this; see
its `START_PROMPT.md` for current status before duplicating that investigation here. Not worth
picking back up on this side without a genuinely new lead — see the "Do not re-attempt" notes on
both relevant Findings.

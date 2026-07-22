# Windows Server 2022 Unattended Install — Phase 2 Engineering Log

Status as of this writing: **one confirmed successful end-to-end build** (with one manual live intervention), **one confirmed unattended-failure** (45-minute WinRM timeout, cause not yet isolated) on the very next run using the same, presumably-fixed configuration. Phase 2 is not yet closed out — see [Open Issues](#open-issues) before trusting this as reliable.

This document is the detailed record of how we got a Windows Server 2022 Evaluation ISO to install unattended under Packer + QEMU/KVM, and to hand off successfully to Packer's WinRM communicator. It exists so the next engineer (or the next session) doesn't have to re-derive any of this from scratch. Read [Current Architecture](#current-architecture) first if you just want to know how it works today; read the [Investigation Log](#investigation-log) if something breaks and you want to know whether it's a regression of something already solved.

---

## Current Architecture

**Pipeline:** `build.sh` → extracts virtio drivers from `virtio-win.iso` via `xorriso` → invokes `packer build` against `packer/windows-server.pkr.hcl` → QEMU boots the real Windows install ISO (as CD-ROM #1) plus a Packer-generated CD-ROM (as CD-ROM #2, label `unattend`) containing `autounattend.xml` and the virtio driver files → unattended install runs → OOBE `FirstLogonCommands` bring up networking and WinRM → Packer's WinRM communicator connects → build finalizes the qcow2 disk.

**Files:**

| File | Role |
|---|---|
| `build.sh` | Prereq checks, extracts the one virtio-win driver variant needed (`vioscsi`/`viostor`/`NetKVM`, filtered to drop only `.pdb`), invokes `packer validate` then `packer build`. |
| `packer/windows-server.pkr.hcl` | The QEMU builder source block: disk/UEFI/network device config, the second-CD-ROM driver delivery mechanism, `boot_command`, WinRM communicator config. |
| `packer/variables.pkr.hcl` | All user-facing variables. Most default to `null` and get resolved through `locals.pkr.hcl`'s per-version profile map. |
| `packer/locals.pkr.hcl` | `windows_profiles` map — per-Windows-version defaults (ISO URL/checksum, edition name, KMS key, driver folder name). Add a new Windows version here (and in `build.sh`'s matching case statement). |
| `packer/answer_files/autounattend.xml.pkrtpl` | The unattend answer file, as a Packer `templatefile()` template. This is where almost all of the hard-won knowledge below is encoded, with comments at each relevant point. |

**Key design choices and why:**

- **UEFI + q35 + virtio-scsi + virtio-net.** Matches CLAUDE.md's target platform. Storage is `virtio-scsi` specifically (not legacy `virtio-blk`/`"virtio"`), which needs the `vioscsi` driver, not `viostor` — `viostor` is bundled anyway as a cheap safety net but isn't actually required for this config.
- **No golden image, no sysprep/generalize.** `shutdown_command` is a plain `shutdown /s`, deliberately not `sysprep /generalize /oobe`. Every build starts from the ISO and produces one disposable, already-specialized disk. This is a hard CLAUDE.md requirement, not a preference.
- **Evaluation media, no `<ProductKey>`.** The ISO reports `[Channel]=eval` in `sources/EI.CFG`, and its `install.wim` images carry `EDITIONID=ServerStandardEval` (not the plain `ServerStandard` a volume-license KMS key targets). Edition selection is handled entirely by `<InstallFrom><MetaData><Key>/IMAGE/NAME</Key>` matching against the WIM's real `<NAME>` values. `local.product_key` (the published KMS client keys) is still defined in `locals.pkr.hcl` and documented for reference / possible future non-eval use, but is **not** currently wired into the template. See [Finding 5](#finding-5-no-images-are-available---the-real-cause-was-productkey-not-the-second-cd-rom).
- **Driver delivery: second CD-ROM, not floppy, not `qemuargs`.** Three approaches were tried in this order; see [Finding 2](#finding-2-qemuargs-silently-replaces-packers-own--drive-arguments), [Finding 5](#finding-5-no-images-are-available---the-real-cause-was-productkey-not-the-second-cd-rom), and [Finding 8](#finding-8-floppy-delivery-is-flaky-for-larger-files). The short version: `qemuargs` breaks VM boot outright; floppy is unreliable for anything much bigger than an INF file; a second CD-ROM (via Packer's native `cd_files`/`cd_content`) works and was never actually the cause of the "No images available" bug that got it wrongly ruled out the first time.
- **Driver injection declared twice** — once under `Microsoft-Windows-PnpCustomizationsWinPE` (`windowsPE` pass, for what Setup itself needs — `vioscsi`, to see the disk at all) and again under `Microsoft-Windows-PnpCustomizationsNonWinPE` (`specialize` pass, to actually get `NetKVM` into the installed OS's driver store for post-boot PnP matching). See [Finding 6](#finding-6-nic-driver-never-makes-it-into-the-installed-os).
- **A `pnputil /add-driver` fallback runs as the first `FirstLogonCommand`,** finding the driver CD by volume label (`unattend`) rather than assuming a drive letter, as belt-and-suspenders alongside the declarative `DriverPaths` above. Whether this fallback is actually load-bearing, or the declarative `DriverPaths` alone would now suffice on CD (as opposed to the floppy it was originally built against), **has not been isolated** — see [Open Issues](#open-issues).
- **`boot_command` spams `<spacebar>` every second for ~25s**, not once — the "Press any key to boot from CD or DVD..." prompt only shows for ~2-3s and exact OVMF POST timing before it appears isn't predictable across hosts. See [Finding 1](#finding-1-uefi-press-any-key-boot-prompt).

---

## Investigation Log

Findings are numbered in roughly the order they were discovered, since later findings sometimes depend on context from earlier ones. Each includes the symptom, how it was actually diagnosed (not just guessed), the root cause, and the fix.

### Finding 1: UEFI "press any key" boot prompt

**Symptom:** VM boots to a UEFI firmware screen: `Press any key to boot from CD or DVD......`, followed by `BdsDxe: failed to start Boot0001 ... Time out`, then falls through CD-ROM(s) → HARDDISK → PXE → HTTP boot, all failing, dead end.

**Diagnosis:** Direct VNC screenshot showed the exact firmware text. This is Windows install media's own bootloader stub (not a QEMU/OVMF feature) — it always shows this prompt, even on real hardware, specifically so leaving install media in the drive doesn't force a reinstall on next boot.

**Root cause:** Nothing was sending a keystroke. `boot_wait` alone doesn't type anything; `boot_command` is required.

**Fix:** Added `boot_command`. First attempt used 3 discrete `<spacebar>` presses spaced by `<wait5>` — still failed, because the exact moment OVMF POST reaches the boot-device-cycling stage isn't predictable and the presses can straddle the ~2-3s window without ever landing inside it. Final fix sends `<spacebar><wait1>` in a loop 25 times (HCL `for` expression: `join("", [for _ in range(25) : "<spacebar><wait1>"])`), covering a ~25s window starting almost immediately after boot, guaranteeing overlap regardless of host POST speed.

### Finding 2: `qemuargs` silently replaces Packer's own `-drive` arguments

**Symptom:** First attempt at attaching `virtio-win.iso` as a second CD-ROM used:
```hcl
qemuargs = [["-drive", "file=${var.virtio_iso_path},media=cdrom"]]
```
VM failed to start: `qemu-system-x86_64: -device scsi-hd,bus=scsi0.0,drive=drive0: Property 'scsi-hd.drive' can't find value 'drive0'`.

**Diagnosis:** `PACKER_LOG=1` dump of the actual `qemu-system-x86_64` invocation showed the `-device scsi-hd,...,drive=drive0` argument was still present, but **no `-drive ...,id=drive0` argument existed anymore** — the main boot disk's own `-drive` had been silently dropped.

**Root cause:** Packer's QEMU builder docs are correct but easy to misread: setting `qemuargs` doesn't *add* to the builder's own generated arguments, it *replaces* the ones in the same category (here, all `-drive` flags — main disk, install ISO, and any `cd_files`-generated ISO all disappeared, leaving only our one custom `-drive`).

**Fix:** Abandoned `qemuargs` entirely for this purpose. Use Packer's native `cd_files`/`cd_content` (or `floppy_files`/`floppy_content`) instead, which are additive and don't touch the builder's own disk arguments.

### Finding 3: `xorriso`-extracted files inherit read-only permissions from the source ISO

**Symptom:** After switching to `cd_files` pointing at a locally-extracted driver tree, `packer build` failed: `Error creating temporary file for CD: error creating new directory .../vioscsi/2k12: mkdir ...: permission denied`. Separately, our own cleanup (`rm -rf` on the extraction temp dir) also failed with `Permission denied`.

**Diagnosis:** `ls -la` on the extracted tree showed `dr-xr-xr-x` directories (no write bit) — `xorriso -osirrox` preserves the ISO's own stored Rock Ridge permission bits, and virtio-win.iso's driver directories are stored read-only.

**Fix:** `chmod -R u+rwX` on the extraction directory immediately after `xorriso` runs, in `build.sh`, before Packer or our own cleanup trap ever touches it.

### Finding 4: two orphaned QEMU processes contending for host resources looked like a VNC bug

**Symptom:** A build attempt failed with `Error running boot command: write tcp 127.0.0.1:xxxxx->127.0.0.1:yyyy: use of closed network connection` — Packer's own VNC connection (the one it uses to type `boot_command`) got force-closed mid-keystroke.

**Diagnosis:** `ps aux | grep qemu-system` revealed a **leftover `qemu-system-x86_64` process from a previous, already-failed build attempt**, still running and burning 200%+ CPU, never cleaned up (the previous attempt had been killed via `TaskStop` without also confirming the QEMU child process died).

**Root cause:** Resource contention between two simultaneous QEMU VMs on the same host, not a genuine VNC protocol bug. (A related, separately-confirmed fact: QEMU's built-in VNC server only supports one connected client — a second connection, e.g. a user's own `vncviewer` connecting while Packer's automated client is mid-`boot_command`, can also legitimately knock the first connection off. This happened at least twice more later in the session and is why the working pattern became: **never connect a VNC client during the `boot_command` typing phase** — wait until the log shows `Waiting for WinRM to become available...` before connecting.)

**Fix:** Always verify `ps aux | grep qemu-system-x86_64` is empty before starting a new build, especially after stopping a previous attempt. `TaskStop` on the wrapping bash task does not guarantee the child QEMU process also exits.

### Finding 5: "No images are available" — the real cause was `ProductKey`, not the second CD-ROM

**Symptom:** Setup boots fine, reaches "Select the operating system you want to install", and the list is empty: `No images are available.`

**First (wrong) diagnosis:** At the time, the config had a second CD-ROM attached (for `autounattend.xml` + drivers) alongside the real install media. It seemed plausible that Setup's image-enumeration logic was confused by two optical drives, so driver delivery was switched to a floppy instead ([Finding 8](#finding-8-floppy-delivery-is-flaky-for-larger-files)).

**Actual root cause, found later:** The autounattend at the time included:
```xml
<ProductKey><Key>VDYBN-27WPP-V4HQT-9VMD4-VMK7H</Key></ProductKey>
```
— the published KMS client setup key for "Windows Server 2022 Standard". This ISO is evaluation media. Verified by extracting `sources/install.wim` directly from the ISO (`xorriso`/`7z`, since this ISO is UDF-formatted and plain `xorriso -find` doesn't see anything — `7z l` handles UDF fine) and reading the WIM's embedded XML metadata (`strings -el install.wim | grep EDITIONID`): every image's `<EDITIONID>` is `ServerStandardEval` / `ServerDatacenterEval`, not the plain `ServerStandard` the KMS key is scoped to. The `<InstallFrom><MetaData><Key>/IMAGE/NAME</Key>` selector's target name (`Windows Server 2022 SERVERSTANDARD`) was and is **correct** — verified to exactly match one of the four `<NAME>` values in the WIM (index 2, confirmed via the same `strings` extraction). The mismatched key made Setup's image list come up empty even though the name filter itself was fine.

**Fix:** Removed `<ProductKey>` entirely. Eval media handles edition selection via `sources/EI.CFG`'s `[Channel]=eval` plus the `/IMAGE/NAME` filter alone. This was confirmed to fix the "No images available" screen (Setup proceeded straight to a real install progress bar) — at the time, still using floppy for driver delivery, so this specifically isolates `ProductKey` as the cause, independent of the CD-vs-floppy question.

**Consequence:** Once this was understood, going back to a second CD-ROM (via `cd_files`/`cd_content`, not `qemuargs`) was safe, and was in fact done later (Finding 8) once floppy turned out to have its own, unrelated problem.

**Reference data worth keeping**, since it took real effort to extract: this ISO's `install.wim` has 4 images —

| Index | `<NAME>` | `<EDITIONID>` |
|---|---|---|
| 1 | `Windows Server 2022 SERVERSTANDARDCORE` | `ServerStandardEval` |
| 2 | `Windows Server 2022 SERVERSTANDARD` | `ServerStandardEval` |
| 3 | `Windows Server 2022 SERVERDATACENTERCORE` | `ServerDatacenterEval` |
| 4 | `Windows Server 2022 SERVERDATACENTER` | `ServerDatacenterEval` |

The KMS client keys in `locals.pkr.hcl` were verified against Microsoft's official published table (`learn.microsoft.com/windows-server/get-started/kms-client-activation-keys`), not from memory — worth re-verifying if it's ever actually wired back in, since these do occasionally change.

### Finding 6: NIC driver never makes it into the installed OS

**Symptom:** Post-install, logged into the desktop: `Get-NetAdapter` returns nothing, `Get-NetConnectionProfile` returns nothing, `Get-PnpDevice -Status Error -PresentOnly` shows an `Ethernet Controller` with no driver (`PCI\VEN_1AF4&DEV_1000&...`). WinRM's listener (created by `FirstLogonCommands`) ends up bound to `127.0.0.1, ::1` only, since that's the only interface with an address at the time it's created.

**Diagnosis:** The `vioscsi` driver (needed by WinPE itself to see the disk) clearly *did* get injected successfully — Setup could partition and install onto the virtio-scsi disk at all. `NetKVM` (needed only after first boot, not by Setup) did not.

**Root cause:** `Microsoft-Windows-PnpCustomizationsWinPE`'s `DriverPaths` (in the `windowsPE` pass) stages drivers WinPE needs *immediately* and, because storage drivers are boot-critical, those specifically get carried into the final OS's boot configuration. It does not reliably carry other, non-boot-critical drivers into the installed OS's driver store for later PnP matching.

**Fix:** Added a second `<DriverPaths>` declaration under `Microsoft-Windows-PnpCustomizationsNonWinPE`, in the `specialize` pass — this is the component actually meant for injecting drivers into the offline/target image. (Whether this alone is sufficient, vs. needing the `pnputil` `FirstLogonCommand` fallback too, was never cleanly isolated — see [Open Issues](#open-issues).)

### Finding 7: driver media isn't necessarily readable the instant Windows wants it

**Symptom:** With driver delivery on a floppy: `Win32_LogicalDisk` shows `A:` present but with **no `VolumeName` and no `Size`** — the drive letter exists but the media reads as empty. `pnputil /add-driver A:\netkvm.inf /install` fails: `The system cannot find the file specified.`

**Diagnosis:** Running `"rescan" | diskpart` and then `dir A:\` immediately afterward showed the files perfectly correctly. The floppy's *content* was never the problem — Windows simply hadn't detected/mounted the media yet, and nothing had prompted it to.

**Fix (partial — see Finding 8 for why this alone wasn't enough):** Added an explicit `"rescan" | diskpart` + `pnputil /add-driver` step as the first `FirstLogonCommand`, since the declarative `DriverPaths` mechanism runs before anything triggers detection and silently finds nothing.

**Note:** when driver delivery was later switched to CD-ROM, this same class of problem did *not* reproduce — `dir E:\` worked on the very first try, no rescan needed. `Get-Volume -FileSystemLabel unattend` did report `FileSystemType = Unknown` even on the working CD, which looked alarming but turned out to be a red herring (probably just how Windows reports metadata for this specific `xorriso`-generated ISO 9660 image) — `dir` and `pnputil` both worked fine against it despite that.

### Finding 8: floppy delivery is flaky for larger files

**Symptom:** Even after the rescan fix (Finding 7), `pnputil /add-driver A:\*.inf /install` reliably installed `vioscsi.inf` and `viostor.inf` (65-80KB `.sys` files) but **consistently failed on `netkvm.inf`** (192KB `.sys` file) with `The system cannot find the file specified.` — reproduced identically on multiple separate attempts, including immediately after a `dir A:\` had just confirmed `NETKVM.INF` was listed.

**Diagnosis:** This is genuinely a floppy emulation reliability issue correlated with file size, not a one-time media-detection problem (Finding 7 already accounted for and fixed the "not detected yet" case). Confirmed via direct, repeated live testing in a running VM.

**Fix:** Abandoned floppy for driver delivery entirely, switched to a second CD-ROM via `cd_files`/`cd_content` (see [Finding 5](#finding-5-no-images-are-available---the-real-cause-was-productkey-not-the-second-cd-rom) for why this was safe to do). Also required restoring nested `DriverPaths` (`vioscsi\<os_dir>\amd64` etc.) since `cd_files` preserves each source directory's own basename at the CD root, unlike `floppy_files`, which was discovered (by directly mounting/inspecting the generated floppy image with `7z l`) to flatten everything into one directory regardless of source structure.

**Important:** switching media did *not* immediately fix the NetKVM install failure — see Finding 9. The floppy-specific flakiness (Finding 7/8) and the actual NetKVM install failure (Finding 9) turned out to be two separate, coincidentally-overlapping problems.

### Finding 9: `netkvm.inf` needs `netkvmp.exe`, not just `netkvm.sys` — and we'd deliberately deleted it

**Symptom:** After switching to CD-ROM delivery, `pnputil /add-driver E:\*.inf /subdirs /install` *still* failed identically: `NetKVM.inf ... Failed to add driver package: The system cannot find the file specified`, while `vioscsi.inf`/`viostor.inf` reported "already exists in the system" (they'd been installed earlier via the boot-critical path, so this wasn't actually proof they'd work fresh either).

**Diagnosis:** Directly read `netkvm.inf`'s `[SourceDisksFiles]` and `[*.CopyFiles]` sections:
```ini
[SourceDisksFiles]
netkvm.sys  = 1,,
netkvmp.exe = 1,,
...
[Install]
CopyFiles = kvmnet6.CopyFiles, netkvmp.CopyFiles
```
`netkvm.inf` requires **both** `netkvm.sys` and `netkvmp.exe` (a "coinstaller" executable) to be present alongside it for `pnputil` to successfully stage the package. `vioscsi.inf`/`viostor.inf` have no such second-file requirement, which is why they were never affected by this.

**Root cause:** `build.sh`'s driver-extraction step filtered files down to `*.inf`/`*.cat`/`*.sys` only — a size-saving measure from when driver delivery was on a 1.44MB floppy. This silently dropped `netkvmp.exe`, and the resulting "file not found" error looked identical to (and was originally misattributed to) the media-reliability problems in Findings 7 and 8.

**Fix:** Changed `build.sh` to only exclude `*.pdb` (debug symbols — genuinely never needed, several hundred KB to multi-MB each). Everything else, including `netkvmp.exe`, now gets delivered. CD-ROM capacity makes the original space concern moot (total driver payload is ~1.6MB even unfiltered).

**This is the finding to check first** if a future driver (for a different Windows version, or a different virtio component) fails to install with "file not found" despite the file visibly being present in the source directory — check that INF's own `[SourceDisksFiles]`/`CopyFiles` sections for companion files before assuming a media/delivery problem.

### Finding 10: `SkipUserOOB`/`SkipMachineOOB` — missing the trailing "E"

**Symptom:** First reboot after install: `Windows could not parse or process unattend answer file [C:\Windows\Panther\unattend.xml] for pass [oobeSystem]. A component or setting specified in the answer file does not exist.`

**Diagnosis:** Direct review of the `oobeSystem` pass XML against the actual unattend schema element names.

**Root cause:** Plain typo — the correct schema elements are `<SkipUserOOBE>` and `<SkipMachineOOBE>`, not `<SkipUserOOB>`/`<SkipMachineOOB>`.

**Fix:** Corrected the element names.

### Finding 11: non-ASCII / embedded-quote characters in `<Description>` broke oobeSystem parsing differently

**Symptom:** A later run hit a *different* generic error at the same pass: `Windows could not parse or process unattend answer file ... for pass [oobeSystem]. The answer file is invalid.`

**Diagnosis:** Extracted the *actual rendered* `autounattend.xml` from the CD image Packer had generated for that exact run (`7z e` on the `/tmp/packerNNNN.iso` file, found via the running `qemu-system-x86_64` process's own `-drive` argument) and diffed it mentally against the previously-working version. The only new content was a `<Description>` element (documentation text, not functional) containing an em-dash (`—`, non-ASCII) and literal embedded double-quote characters, on a newly-added `FirstLogonCommand`. The two other `<Description>` elements, which had already been proven to parse fine in a prior successful run, were plain ASCII with no embedded quotes.

**Root cause:** Not fully isolated to one specific character (the fix removed both the em-dash and the quotes at once, out of caution rather than root-causing precisely) — but Windows' answer-file parser is evidently stricter about `<Description>` content than raw XML well-formedness requires (both a Python `xml.dom.minidom` parse and the eventual rendered file passed standard XML well-formedness checks without complaint).

**Fix:** Keep all `<Description>` text plain ASCII, no embedded quote characters. This cost an entire ~20-minute rebuild cycle to catch — worth being disciplined about up front in any future edits to this file, rather than re-discovering it.

### Finding 12: `winrm set ... '@{Basic=$true}'` silently does nothing

**Symptom:** First fully-networked run (NIC driver working, guest gets a real IP): Packer's WinRM communicator times out connecting. Direct host-side probe (`curl -X POST http://127.0.0.1:<port>/wsman`) with Basic auth returns `401 Unauthorized`, and `curl -v` shows `WWW-Authenticate: Negotiate` only — Basic auth was never actually enabled. `winrm get winrm/config/service/auth` in the guest confirms: `Basic = false`, and separately `AllowUnencrypted = false`.

**Diagnosis:** The `FirstLogonCommand` that configures WinRM contains:
```powershell
winrm set winrm/config/service/auth '@{Basic=$true}'
winrm set winrm/config/service '@{AllowUnencrypted=$true}'
```
Both settings stayed `false` despite this running (confirmed no error was thrown — the command block completed, `Restart-Service WinRM` ran, the listener itself came up fine and was reachable).

**Root cause:** `'@{Basic=$true}'` is a **single-quoted** PowerShell string. Single quotes suppress *all* variable expansion in PowerShell, so the literal 5-character text `$true` (dollar sign included) is what gets passed to `winrm.exe` as the value — not the PowerShell boolean. `winrm.exe`'s own config-value parser doesn't recognize the text `$true` as boolean-true and silently treats the assignment as a no-op (or as some other unintended value) rather than erroring loudly.

**Fix:** Use the literal, quoted string `"true"` (what `winrm.exe`'s parser actually expects) instead of PowerShell's `$true`: `'@{Basic=\"true\"}'` (the backslash-escaped `\"` is required because this whole command is itself wrapped in an outer `-Command "..."` double-quoted argument at the Win32 process-launch level — Windows' own command-line argument parser converts `\"` to a literal `"` *before* `powershell.exe` ever sees its `-Command` argument, so the backslash is consumed at that layer, not by PowerShell). The `TrustedHosts` setting on the same command line already used this exact `\"..\"` pattern correctly and had never been affected — only the two boolean-valued settings were wrong.

**Status:** This fix is committed to `autounattend.xml.pkrtpl`, but **the only run that has actually completed a full successful build so far did not exercise this templated fix** — that run succeeded because a human manually ran the corrected `winrm set` commands live in the guest, and Packer's own background polling happened to catch the change and connect before the manual session could even verify it. The very next attempt, using the templated fix with no manual intervention, timed out after the full 45-minute `winrm_timeout` without ever getting a WinRM response — see [Open Issues](#open-issues). **Do not treat this fix as confirmed working end-to-end yet.**

---

## Open Issues

1. **The templated `$true`→`"true"` fix has not been confirmed to work unattended.** One run succeeded (via manual live intervention, before the template fix existed). The very next run — same code, template fix in place, no manual intervention — ran for the full 45-minute `winrm_timeout` and never got a WinRM response at all (a direct host-side `curl` probe timed out completely, not even a `401` this time, meaning the listener likely never came up reachable in the first place, or the guest never got that far). The qcow2 disk file was still actively growing right up until the failure, suggesting Windows was legitimately still doing *something* (not hung at a dead dialog) — but 45 minutes is roughly 4x longer than the successful run took to reach the same stage, which is a lot to write off as pure variance.

   Two live diagnostic commands (`curl`, `ps`) were run against that failing VM from the host while it was mid-build, close to when it failed — worth ruling out (or in) host resource contention from that as a contributing factor before assuming a code regression. **Next step: run a clean build with zero concurrent host-side polling/diagnostics, let it run completely undisturbed, and see if it reaches WinRM in the ~10-12 minute range the first successful run did.** If it's still slow/failing, the `$true` fix or the driver-injection ordering need a closer look — possibly by capturing a mid-build VNC screenshot at the ~10-15 minute mark to see what's actually on screen without touching the VM otherwise.

2. **Whether the `pnputil` `FirstLogonCommand` fallback (Order 1) is actually necessary, or whether the declarative `DriverPaths` under `PnpCustomizationsNonWinPE` alone is now sufficient on CD-ROM, was never isolated.** Both were added/fixed around the same time as the CD-ROM switch and the `netkvmp.exe` fix. It would be worth (once builds are reliably succeeding) temporarily removing the `pnputil` fallback command and confirming the NIC still comes up via the declarative path alone, to simplify `FirstLogonCommands` if possible — or confirming it's genuinely load-bearing and documenting why.

3. **Windows Server 2025 support is defined but never build-tested.** `locals.pkr.hcl` has a `"2025"` profile (ISO fwlink URL, KMS key verified against Microsoft's published table, `virtio_os_dir = "2k25"`), and `build.sh` has the matching case arm — but no build has actually been run against it. The 2025 ISO is ~8.5GB and its `iso_checksum` is deliberately set to `"none"` (Microsoft doesn't publish one) — first real use should include computing and pinning a real checksum after download.

4. **No `verify.sh` / `destroy.sh` yet.** Out of scope for Phase 2 per `CLAUDE.md`, but worth flagging: right now, tearing down a build means manually checking for orphaned `qemu-system-x86_64` processes and `rm -rf packer/output`. That's fine for active development but isn't Phase 5's lifecycle automation yet.

---

## Practical Operating Notes

Things that aren't bugs, just worth knowing if you're running this yourself:

- **Never connect a VNC client while the log shows `Typing the boot commands over VNC...`.** QEMU's VNC server only supports one client; a second connection during that window can knock Packer's own automated connection off, aborting the build with a `use of closed network connection` error. Wait until the log shows `Waiting for WinRM to become available...` — that means `boot_command` has finished and it's safe to connect and watch.
- **Always check `ps aux | grep qemu-system-x86_64` and `rm -rf packer/output` before starting a new build**, especially after manually stopping a previous attempt (`TaskStop` on a wrapping shell task does not guarantee the child QEMU process exits).
- **A full build takes roughly 20-25 minutes** when things go well: several minutes of Windows Setup (file copy/features/updates), a reboot, OOBE/`FirstLogonCommands`, then several more minutes of `qemu-img convert -c` disk compression at the end (compressing ~9-10GB of actually-used data on the 60GB disk down to a ~5GB qcow2).
- **`Get-Volume -FileSystemLabel unattend`** is the reliable way to find the driver CD from inside the guest — its drive letter is not predictable, but the label (set via `cd_label = "unattend"` in the Packer template) is stable.
- The current default admin password (`ChangeMe-Lab123!`, in `packer/variables.pkr.hcl`) is intentionally a placeholder for a disposable, isolated lab VM — override via `PKR_VAR_admin_password` if desired, but it is not treated as a secret in this project.

---

## Design Direction: Selectable Services (Phase 3, Not Yet Implemented)

See CLAUDE.md for the resulting decision. Recorded here for context: the original CLAUDE.md phrasing implied every build would install AD DS + DNS + IIS + Datadog Agent together. In discussion, this was reconsidered — most real Windows Server deployments are single-purpose (a DC is a DC, an IIS box is an IIS box), and bundling every role by default doesn't reflect realistic customer environments to simulate against. The direction going forward is a YAML-driven service selection list (e.g. `ad-ds`, `iis`, `sql-server`, ...) that determines which provisioning scripts actually run for a given build, rather than all of them unconditionally. This has not been designed in detail or implemented — Phase 3 (Windows role configuration) hadn't started before this pivot — but it should inform how `scripts/` and the Phase 3 Packer provisioner blocks get structured when that work begins.

# Windows Server 2022 Unattended Install — Phase 2 Engineering Log

Status as of this writing: **two confirmed successful end-to-end builds** — one with a manual live intervention (before the WinRM auth fix existed), and one **fully unattended, no manual steps**, after [Finding 14](#finding-14-the-real-cause-was-description-length-not-character-content--confirmed-by-a-byte-level-diff-between-two-failing-builds) tracked down and fixed an `oobeSystem` answer-file parse error (likely caused by an overly long `<Description>` element, not the non-ASCII characters Finding 13 initially — incorrectly — blamed). This also gave the first real confirmation that Finding 12's WinRM Basic-auth fix (`$true` → `"true"`) actually works unattended, since every prior run had crashed before ever reaching it. Phase 2 looks solid as of the latest run, but only one unattended success has been observed so far — see [Open Issues](#open-issues) before treating it as fully reliable. (Phase 3 role scripts — IIS, AD DS, SQL Server — are also implemented and independently verified against this 2022 baseline; see `services.yaml` and `scripts/`.) Windows Server 2025 support is blocked on a known, unresolved upstream UEFI boot issue — see [Finding 15](#finding-15-windows-server-2025-media-reliably-fails-the-uefi-boot-key-mechanism-entirely--a-known-unresolved-upstream-issue).

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

### Finding 13: Finding 11's fix was incomplete — it only covered `<Description>` text, not comments elsewhere in the document

**Symptom:** A clean rebuild (fresh session, cached/current ISOs verified via checksum and ETag, no concurrent host-side diagnostics touching the VM) hit the exact same dialog as Finding 11: `Windows could not parse or process unattend answer file [C:\Windows\Panther\unattend.xml] for pass [oobeSystem]. The answer file is invalid.` Reproduced twice in a row, both times within a couple minutes of reaching oobeSystem — not the intermittent/one-off failure Finding 11's writeup implied. Packer's WinRM communicator, meanwhile, kept retrying and got a *different* symptom than the earlier plain connection-refused: repeated `401 - invalid content type`, i.e. something was listening on 5985 but never accepting auth — consistent with `FirstLogonCommands` (which configure WinRM's Basic auth) never actually running, because oobeSystem never successfully parsed at all.

**Diagnosis:** Inspecting the rendered CD's `autounattend.xml` found nothing wrong — the `<Description>` elements were all plain ASCII (Finding 11's fix was intact). This ruled out a *regression* of Finding 11 but not a related, uncovered case. To get real evidence instead of guessing again, the second failing build's VM was killed with `kill -9` (not a plain `kill`/SIGTERM — see the process note below) specifically to keep Packer from running its own cancel-cleanup, which deletes the output directory including the qcow2 disk. With the disk preserved, it was mounted read-only on the host (`sudo modprobe nbd max_part=8`; `sudo qemu-nbd --read-only --connect=/dev/nbd0 <qcow2>`; `sudo mount -t ntfs-3g -o ro /dev/nbd0p3 <mountpoint>` — partition 3 is the main NTFS volume behind the EFI System Partition and MSR) and `C:\Windows\Panther\{setupact.log,setuperr.log,unattend.xml}` were copied out.

The Panther copy of `unattend.xml` (note: this is *not* a verbatim copy of the CD's file — `setupact.log` shows `Callback_Unattend_Serialize` re-serializing it at the end of the specialize pass, evidenced by the XML declaration switching from double to single quotes) was itself well-formed and, again, had no bad characters in any `<Description>`. But the `specialize`-pass block still carries an XML *comment* (documenting why driver injection is declared under `PnpCustomizationsNonWinPE`) containing two em-dash characters — the same class of character Finding 11 identified as breaking oobeSystem parsing, just located in a comment instead of a `<Description>`. The template's top-of-file header comment had two more. `setupact.log` confirmed the specialize pass itself completed and logged `wasPassProcessed="true"` before reboot — so these comments don't break the pass they live in, but apparently corrupt something in how the *next* pass's answer file gets parsed after reboot.

**This wasn't proven with a smoking-gun parser message** (the Panther logs captured stopped right at the pre-reboot boundary, before oobeSystem's own parse attempt would have logged anything) — it's the strongest available lead, not a certainty. Finding 11's own writeup already flagged that it never isolated the exact offending character, just removed both the em-dash and embedded quotes at once "out of caution."

**Fix (being tested):** Removed all four remaining em-dashes from `autounattend.xml.pkrtpl` (two in the header comment, two in the specialize-pass comment), replacing them with plain hyphens. If this holds, the actual rule Finding 11 should have stated is: **no non-ASCII characters anywhere in the rendered unattend file, not just inside `<Description>` elements** — comments are part of the same document and apparently not immune.

**Process note, worth keeping regardless of whether the em-dash theory holds:** killing a stuck Packer build with a plain `kill` (SIGTERM) lets Packer catch the signal and run its normal cancellation cleanup, which deletes `packer/output/` — including the qcow2 disk you'd want for post-mortem forensics. Use `kill -9` on the `packer build`/plugin/`qemu-system-x86_64` processes if you need the disk to survive for inspection.

**This also retroactively explains Open Issue #1's original mystery** (the templated WinRM `"true"` fix appearing to somehow cause a 45-minute timeout with *no* response at all, worse than the earlier plain-401 failures): if oobeSystem was already failing to parse for this same comment-em-dash reason back then too, `FirstLogonCommands` never ran, WinRM's listener never got configured, and the run was doomed regardless of whether the `$true`→`"true"` fix was correct. That fix was likely never actually the variable — see the updated Open Issues entry below.

**Status: this fix did not work.** See Finding 14 — a third rebuild with the em-dashes removed hit the identical `oobeSystem` parse dialog again. The em-dash hypothesis is now believed to have been a red herring (or at best an incomplete part of the picture); do not re-apply it as *the* fix in isolation if this ever recurs.

### Finding 14: the real cause was `<Description>` length, not character content — confirmed by a byte-level diff between two failing builds

**Symptom:** After Finding 13's em-dash fix, a rebuild hit the exact same `Windows could not parse or process unattend answer file [C:\Windows\Panther\unattend.xml] for pass [oobeSystem]. The answer file is invalid.` dialog a third time. Since the fix touched exactly two characters in one XML comment (the header comment isn't carried into the Panther-serialized file at all — Windows regenerates its own XML prolog and drops it — so only the two em-dashes inside the `specialize`-pass inline comment were ever actually live in the document oobeSystem re-parses), this was a cheap, sharp test: if the theory were right, the failure should disappear; if it recurred identically, the theory was wrong.

**Diagnosis:** The stuck VM was killed with `kill -9` (see Finding 13's process note) and Panther logs pulled again via the same `qemu-nbd`/`ntfs-3g` procedure, into fresh files (the first run's forensics files couldn't be renamed for a backup — they were `root`-owned copies sitting in `/tmp` under the sticky bit, un-renameable by a non-root user — so the first run's `Panther\unattend.xml` content was instead reconstructed from what had already been read into the working session and diffed programmatically with `diff` against the new pull).

The two files differed by **exactly 4 bytes** — precisely what removing two 3-byte UTF-8 em-dash characters and replacing each with a 1-byte ASCII hyphen predicts (2 characters × 2 bytes saved = 4). `diff` confirmed those were the *only* content differences (one further line-1 divergence was investigated and was a false alarm — a `\n` vs `\r\n` artifact from how the first run's comparison copy had been manually retyped into a file, not a real difference between the two actual Windows-generated documents). **Both versions of the file failed identically.** This directly falsified the em-dash-in-comment theory: the fix changed nothing about the actual parse outcome.

With character content ruled out, the next-most-unusual property of the document was measured directly:

```
grep -oP '(?<=<Description>)[^<]*(?=</Description>)' unattend.xml | awk '{print length": "$0}'
196: Force-install the NetKVM, vioscsi, and viostor drivers from the unattend CD, ...
102: Wait for the NIC to have a real IP, then set network category to Private ...
447: Enable WinRM over HTTP for the Packer communicator, explicitly rebinding ...
```

One `<Description>` (the WinRM one, `Order 3`) was 447 characters — more than double the next-longest and roughly 4.5x the shortest. Official Microsoft unattend.xml samples almost always use short, single-clause descriptions; nothing in this template's history had ever tested a `<Description>` anywhere near this long, since Finding 11's fix had *also* shortened the one problem description it touched (coincidentally conflating "shorter" with "fewer special characters" — the same confound Finding 13 initially missed).

**Fix:** All three `<Description>` elements were cut to short, plain phrases (`"Install virtio drivers (fallback)"`, `"Set network category to Private"`, `"Enable WinRM over HTTP"` — all under 40 characters), with the detailed rationale that used to live in those long descriptions relocated to an XML comment directly above `<FirstLogonCommands>` instead (comments had already been shown, in Finding 13's own byte-diff, to survive being carried across the specialize→oobeSystem boundary without themselves breaking anything).

**Confirmed working:** the next rebuild reached the Windows login screen (no crash dialog), and — for the first time in this project's history — Packer's WinRM communicator successfully authenticated: `WinRM connected.` / `Connected to WinRM!`, followed by the normal graceful-shutdown and disk-compression finish. The build completed in full: `Build 'windows-server.qemu.windows_server' finished after 18 minutes 1 second`, final compressed disk `packer/output/win2022-dc/win2022-dc.qcow2` at 5.06GB, no orphaned `qemu-system`/`packer` processes left behind. This is also the first real end-to-end confirmation of Finding 12's `$true`→`"true"` WinRM fix, which had never previously survived long enough to be exercised.

**Residual uncertainty, stated plainly:** this fix changed two things at once (shortened text *and* removed the last two live special characters, since the rationale text itself contained a colon and hyphens that are now gone from the `<Description>` elements). Length is the best-supported explanation given the 447-vs-196/102 disparity and the clean byte-diff falsification of the character-only theory, but an exact length threshold (a hard schema limit vs. some other property of that specific long string) was not isolated. If a future edit reintroduces a long `<Description>`, treat anything over roughly 200 characters as suspect until this is pinned down more precisely — e.g. by binary-searching the exact length at which a single test `<Description>` starts failing, if it's ever worth the build-cycle time to nail down.

### Finding 15: Windows Server 2025 media reliably fails the UEFI boot-key mechanism entirely — a known, unresolved upstream issue

**Symptom:** Windows Server 2025's eval ISO (fwlink `linkid=2345730`, resolves to `SERVER_EVAL` media as expected) never once reached Windows Setup. Every attempt fell through the "press any key to boot from CD or DVD..." prompt exactly like Finding 1's original 2022 failure mode — but unlike 2022, it failed **every single time**, first landing at the PXE-fallback dead end, later (after retries) dropping all the way to the OVMF UEFI Interactive Shell once PXE itself gave up. Four consecutive attempts failed identically:

1. Original config (`boot_wait = "2s"`, 25× spacebar over ~25s — proven reliable on 2022 across many builds this session).
2. Widened window (`boot_wait = "1s"`, 60× spacebar over ~60s — covers a much broader range in both directions).
3. Explicit QEMU boot order hint (`qemuargs = [["-boot", "order=d,menu=off"]]`) — verified present in the actual live `qemu-system-x86_64` command line (`ps aux` confirmed the flag, and confirmed Packer's own `-drive`/`-device` args were untouched, i.e. this really was additive per Finding 2's category-scoped replacement behavior, not a collision).
4. (Same as 3, retried once more before giving up.)

**Diagnosis:** Before assuming a host-specific or config-specific bug, this was checked against the community first (per explicit direction to avoid re-deriving a possibly-already-known issue from scratch): this is a **known, currently open, unresolved issue**, not something specific to this project's setup:
- [hashicorp/packer#13342](https://github.com/hashicorp/packer/issues/13342) and [#13514](https://github.com/hashicorp/packer/issues/13514), both titled "Windows 2025 Server ISO Boot Loop" — open, no maintainer response, no fix.
- [HashiCorp Discuss: "QEMU - Windows unable to boot in UEFI mode"](https://discuss.hashicorp.com/t/qemu-windows-unable-to-boot-in-uefi-mode/76406) — a user hit the **identical** symptom (drops to EFI Shell, ISO content on `FS1:` instead of `FS0:`). Community diagnosis there: "in UEFI, the EFI shell is first in the boot order, and Packer currently lacks the capability to alter this for UEFI boots." A suggested workaround (typing `fs1:\bootmgr.efi` manually from the shell) was tried and **failed** even for that user ("file not found").
- A related but distinct [Proxmox forum thread](https://forum.proxmox.com/threads/windows-server-2025-unattended-iso-issues-known.164463/) describes a *different* Server 2025 problem (installer freezing at partition selection due to stricter `SanPolicy` disk-offline defaults with virtio storage, fixed by explicitly setting boot order in Proxmox's VM options or patching `SanPolicy` into the ISO's `boot.wim`) — not this project's symptom, but corroborates that Server 2025 media is broadly pickier about boot/disk setup across multiple independent QEMU-based hypervisors, not just this one host.

Our own BdsDxe boot log (captured via VNC screenshot) showed a properly-ordered boot variable list — `Boot0001` (first CD-ROM, the real install ISO) failed with **"Time out"** specifically (not "Not Found"), `Boot0002` (second CD-ROM, the driver/unattend CD) "Not Found" (expected — it's not meant to be bootable), `Boot0003` (blank HARDDISK) "Not Found" (expected), then PXE, then the UEFI shell as last resort. A "Time out" on the real install media's own boot entry is consistent with Windows' own El Torito boot stub's documented behavior (its "press any key" prompt has its own internal timeout and falls through by design if nothing is pressed in time, matching Finding 1) — but why our keystrokes reliably fail to land inside that window specifically for 2025 media, across a 60-second widened attempt, was never established. The explicit `-boot order=d` hint (attempt 3) is a real, OVMF-aware mechanism (`OvmfPkg/Library/QemuBootOrderLib` reads this fw_cfg hint even in UEFI mode, not just legacy BIOS) but made no observable difference here — either because OVMF's own BDS logic for El Torito boot images overrides this hint in a way not investigated further, or because the actual bottleneck isn't boot-order at all but something in the boot stub's own timing/detection specific to this ISO build.

**Status: shelved, not fixed.** Both experimental changes (widened `boot_command` window, explicit `-boot` qemuargs) were reverted back to the exact 2022-proven values rather than left in the shared template unverified against 2022 — see `windows-server.pkr.hcl`'s comments at `boot_wait`/`boot_command` for the inline pointer back here. **Do not re-attempt either fix without new evidence** — both were tried and didn't help. If this needs a real resolution later: the most promising unexplored angle is QMP-based direct observation (bypassing Packer entirely, screendumping the VM every ~250-500ms right after boot via a QMP `screendump` loop) to see exactly when — or whether — the "press any key" prompt actually appears for this specific ISO, rather than continuing to guess at timing/boot-order blindly. This was attempted mid-investigation but abandoned in favor of the community-research approach once it became clear this was already a known, unresolved issue elsewhere — worth resuming if a real fix is needed later, since nobody in the community has yet produced hard evidence of *why* this fails, only that it does.

**Update:** the identical symptom (and the identical failure to fix it via keystroke/timing tuning) was independently hit again on Windows 11 Enterprise Evaluation media (build 26200 — also newer/25H2-era, like this Server 2025 build) — see `WINDOWS11_UNATTENDED.md`'s Finding W3. Both blocked OS targets now share this exact same open issue; a fix for one would very likely unblock the other too. Windows 11's investigation did turn up one genuinely new, confirmed-good fix along the way (explicit `index=` on `-drive` entries when using fully-manual `qemuargs`, per that log's Finding W2) that doesn't apply here since this template doesn't use fully-manual qemuargs — but is worth knowing about if this template ever needs to go that route too.

**Re-research update (2026-08-14):** checked all four sources cited above, plus the wider Packer/QEMU community, for anything new. Short version: still open, still unfixed upstream, nothing to act on yet.

- [hashicorp/packer#13342](https://github.com/hashicorp/packer/issues/13342) — closed 2025-03-29, but only by the 30-day stale-bot; no maintainer response or fix was ever posted. Not a resolution.
- [hashicorp/packer#13514](https://github.com/hashicorp/packer/issues/13514) — still open. Fresh "still broken" comments as recently as 2026-05-27 (~2.5 months before this update), including one pointing to `eb4x/packer-qemu-win11` as a possible fix. Checked that repo directly: it's a Windows 11 TPM/secure-boot (`efi_firmware_code`/`vtpm`/`q35`) config example, not a fix for this boot-order/EFI-shell bug, and doesn't address Server 2025 at all.
- [HashiCorp Discuss #76406](https://discuss.hashicorp.com/t/qemu-windows-unable-to-boot-in-uefi-mode/76406) — still accumulating "same problem" reports as recently as 2026-08-06 (8 days before this update). The `fs1:\bootmgr.efi` manual-shell workaround still fails for everyone who's tried it since. No confirmed fix in the thread.
- `packer-plugin-qemu` releases since Finding 15 was written: v1.1.2 through v1.1.6 (latest, 2026-07-16). Checked the v1.1.5 and v1.1.6 changelogs directly — neither touches `-boot`, boot order, or EFI/El Torito handling at all. Nothing shipped that would affect this.

One adjacent technique surfaced that's worth knowing about but is **unverified for this specific bug**: swapping an ISO's `efi/microsoft/boot/{cdboot.efi,efisys.bin}` for their ADK-provided `_noprompt` counterparts removes the "press any key" prompt entirely (no keystroke to race at all), rather than trying to time it. It's mature, known-good technique going back to Server 2019 media (confirmed again recently in a "[SOLVED]" Proxmox thread for Windows 11), but it treats a different symptom than what Finding 15 diagnosed — it eliminates the prompt, but doesn't touch OVMF's EFI-shell-first boot-device ordering, which is the mechanism the community traces this bug to. Nobody in any of the threads above has reported trying it against this specific Server 2025/Win11-26200 QEMU boot-loop. If this investigation is ever resumed, it's a cheap, low-risk thing to try before anything more invasive (e.g. the QMP screendump-loop approach already on file above) — but go in expecting it might not be the real fix, since the deeper OVMF boot-order issue would likely still apply even with the prompt gone.

Also confirmed still separate from Finding 15, but now has a community-confirmed fix as of its own thread's most recent activity: the SanPolicy/disk-offline installer freeze at partition selection ([Proxmox forum thread](https://forum.proxmox.com/threads/windows-server-2025-unattended-iso-issues-known.164463/), previously noted above as "not this project's symptom"). Fixes reported there: explicit boot-order disk selection in the hypervisor's VM settings, switching from virtio-scsi/virtio-blk to SATA/IDE, or patching the `SanPolicy` registry value into `boot.wim`/`install.wim` before building the ISO. Worth remembering if Finding 15 ever unblocks — this project's `windows-server.pkr.hcl` uses virtio-scsi, so this would likely be the next thing hit on Server 2025 specifically.

**Re-research update (2026-09-05):** checked both upstream issues and the plugin release history directly via `gh` for anything new since the 2026-08-14 update. Short version: still open, still unfixed, no movement at all in the intervening three weeks.

- [hashicorp/packer#13514](https://github.com/hashicorp/packer/issues/13514) — still open. Latest comment is still the same one already on file (`faleais`, 2026-05-27: "still having same problem, when does Packer plan to fix this bug?"), unanswered — no newer comments exist as of this check.
- [hashicorp/packer#13342](https://github.com/hashicorp/packer/issues/13342) — unchanged: closed 2025-03-29 by the 30-day stale-bot only, still no maintainer response ever posted.
- `packer-plugin-qemu` releases: still at v1.1.6 (2026-07-16) — no release has shipped since the last check, so nothing new to review there.
- One new (but unverified) workaround mention turned up in #13514's history that predates the 2026-08-14 check but wasn't previously logged here: `vsford` (2025-12-03) reported working around the equivalent boot failure on Windows 11 media by building with legacy BIOS instead of UEFI, then converting to UEFI/GPT via `mbr2gpt` as a final step — sidestepping the native UEFI boot path entirely rather than fixing it. They stated explicitly they had **not** tried it themselves. This is a structural change (BIOS build + post-install conversion step), not a template tweak, and remains unverified by anyone for this exact bug — worth knowing about, not worth acting on without further evidence.

**Recommendation: keep this shelved.** Nothing found changes the "Do not re-attempt without new evidence" guidance above — there is still no confirmed fix from anyone, anywhere, for the actual boot-order/EFI-shell bug. Re-check community state periodically rather than re-deriving from scratch each time.

---

## Open Issues

1. **The `$true`→`"true"` WinRM fix and the `<Description>`-length fix are each confirmed by exactly one successful unattended run so far.** One success is not the same as "reliable" — run it again, ideally a few times, before treating either fix as solid. If a future run fails at `oobeSystem` again, don't reach for the em-dash theory (Finding 13, falsified) — check `<Description>` length first (Finding 14), and consider bisecting the exact length threshold if it recurs, since that was never pinned down precisely.

2. **The exact `<Description>` length threshold is unknown.** Finding 14 only established that 447 characters fails and ~40 characters succeeds; the real cutoff (and whether it's a hard character-count limit vs. some other property of that specific string) was never isolated. Treat anything over ~200 characters in a `<Description>` as suspect.

3. **Whether the `pnputil` `FirstLogonCommand` fallback (Order 1) is actually necessary, or whether the declarative `DriverPaths` under `PnpCustomizationsNonWinPE` alone is now sufficient on CD-ROM, was never isolated.** Both were added/fixed around the same time as the CD-ROM switch and the `netkvmp.exe` fix. It would be worth (once builds are reliably succeeding) temporarily removing the `pnputil` fallback command and confirming the NIC still comes up via the declarative path alone, to simplify `FirstLogonCommands` if possible — or confirming it's genuinely load-bearing and documenting why.

4. **Windows Server 2025 is blocked on Finding 15's UEFI boot-key issue — a known, unresolved upstream Packer/QEMU problem, not something fixable from this project's side alone yet.** `locals.pkr.hcl`'s `"2025"` profile, `build.sh`'s case arm, and the `iso_cache` currency-check machinery all work correctly (verified: the fwlink resolves to genuine `SERVER_EVAL` media, the 8.15GB download completed byte-exact and passed a `7z t` integrity check, `2k25` virtio driver folders exist in the cached `virtio-win.iso`) — the actual Windows install never starts because the VM can't get past its own UEFI firmware's boot-device selection. `iso_checksum` was computed and could be pinned in `locals.pkr.hcl` once this unblocks (currently still `"none"` since there's no further reason to exercise the download path until boot itself works). Do not spend more time on `boot_command`/`boot_wait` tuning without new evidence — see Finding 15.

5. **No `verify.sh` / `destroy.sh` yet.** Out of scope for Phase 2 per `CLAUDE.md`, but worth flagging: right now, tearing down a build means manually checking for orphaned `qemu-system-x86_64` processes and `rm -rf packer/output`. That's fine for active development but isn't Phase 5's lifecycle automation yet.

---

## Practical Operating Notes

Things that aren't bugs, just worth knowing if you're running this yourself:

- **Never connect a VNC client while the log shows `Typing the boot commands over VNC...`.** QEMU's VNC server only supports one client; a second connection during that window can knock Packer's own automated connection off, aborting the build with a `use of closed network connection` error. Wait until the log shows `Waiting for WinRM to become available...` — that means `boot_command` has finished and it's safe to connect and watch.
- **Always check `ps aux | grep qemu-system-x86_64` and `rm -rf packer/output` before starting a new build**, especially after manually stopping a previous attempt (`TaskStop` on a wrapping shell task does not guarantee the child QEMU process exits).
- **If you need the qcow2 disk to survive a manual stop (e.g. for post-mortem forensics), kill with `kill -9`, not a plain `kill`.** Packer catches SIGTERM and runs its own cancellation cleanup, which deletes the whole `packer/output/` directory — disk included. Only SIGKILL prevents that. To read files off a preserved disk afterward: `sudo modprobe nbd max_part=8`, `sudo qemu-nbd --read-only --connect=/dev/nbd0 <qcow2 path>`, `lsblk /dev/nbd0` to find the NTFS partition (the largest one, after the EFI System Partition and MSR), then `sudo mount -t ntfs-3g -o ro /dev/nbd0pN <mountpoint>`. `C:\Windows\Panther\{setupact.log,setuperr.log,unattend.xml}` are the most useful files for diagnosing an install-time failure. Disconnect with `sudo umount` + `sudo qemu-nbd --disconnect /dev/nbd0` when done.
- **A full build takes roughly 20-25 minutes** when things go well: several minutes of Windows Setup (file copy/features/updates), a reboot, OOBE/`FirstLogonCommands`, then several more minutes of `qemu-img convert -c` disk compression at the end (compressing ~9-10GB of actually-used data on the 60GB disk down to a ~5GB qcow2).
- **`Get-Volume -FileSystemLabel unattend`** is the reliable way to find the driver CD from inside the guest — its drive letter is not predictable, but the label (set via `cd_label = "unattend"` in the Packer template) is stable.
- The current default admin password (`ChangeMe-Lab123!`, in `packer/variables.pkr.hcl`) is intentionally a placeholder for a disposable, isolated lab VM — override via `PKR_VAR_admin_password` if desired, but it is not treated as a secret in this project.

---

## Design Direction: Selectable Services (Phase 3, Not Yet Implemented)

See CLAUDE.md for the resulting decision. Recorded here for context: the original CLAUDE.md phrasing implied every build would install AD DS + DNS + IIS + Datadog Agent together. In discussion, this was reconsidered — most real Windows Server deployments are single-purpose (a DC is a DC, an IIS box is an IIS box), and bundling every role by default doesn't reflect realistic customer environments to simulate against. The direction going forward is a YAML-driven service selection list (e.g. `ad-ds`, `iis`, `sql-server`, ...) that determines which provisioning scripts actually run for a given build, rather than all of them unconditionally. This has not been designed in detail or implemented — Phase 3 (Windows role configuration) hadn't started before this pivot — but it should inform how `scripts/` and the Phase 3 Packer provisioner blocks get structured when that work begins.

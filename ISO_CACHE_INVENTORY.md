# `../iso_cache/` Inventory

A point-in-time record of the shared binary-media cache this project depends on — see
`CLAUDE.md`'s repository structure entry for `../iso_cache/` for why it lives one level above this
repo's git tree (shared with the sibling `../windows-auto-build-pipeline/` project) rather than
duplicated inside either one. This file exists because the cache itself is **not** git-tracked
(it's binary install media, multi-GB each) — this is the durable, version-controlled record of
what's cached, when, and from where, in case the directory is ever lost, moved, or needs
reproducing on a fresh host. The sibling project keeps its own, more extensive
`ISO_CACHE_INVENTORY.md` covering the same directory from its side — this file only covers what
*this* project actually consumes, plus a note on what else is physically present and why.

**Snapshot date: 2026-09-05.** Regenerate rather than hand-edit when the cache changes — see "How
to regenerate" at the bottom.

## What this project actually consumes

| File | Size | SHA-256 | Source | ETag / checked | Consumed by |
|---|---|---|---|---|---|
| `2022-SERVER_EVAL_x64FRE_en-us.iso` | 5,044,094,976 B (~4.7 GiB) | `3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325` | `https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US` | ETag `0xC5A0AE6FD398BA773151588CD215E1CFF7FD1C6109783EFA84680CA07C72E2EF`, checked 2026-07-22T14:08:40Z | `build.sh`'s `check_windows_iso_cache`/`download_windows_iso` (`WINDOWS_VERSION=2022`) |
| `2025-26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso` | 8,152,356,864 B (~7.6 GiB) | `7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51` | `https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us` | ETag `0x60A8C190FBB54AF58E40BA049FF290D098101E0EAD343CE912A1DC685219BE85`, checked 2026-07-22T17:19:11Z | `build.sh`'s `check_windows_iso_cache`/`download_windows_iso` (`WINDOWS_VERSION=2025`) — this is the stock ISO; see the next table for the `_noprompt`-patched derivative actually booted |
| `virtio-win-0.1.302.iso` | 877,373,440 B (~837 MiB) | `303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d` | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso` | checked 2026-09-05T17:09:49Z (resolved name: `virtio-win-0.1.302.iso`) | `build.sh`'s `check_virtio_iso_cache`/`download_virtio_iso`, then `xorriso`-extracted (`vioscsi`/`viostor`/`NetKVM`, `2k22`/`2k25` per version) |

**`derived/` subdirectory — windows_version=2025 only:**

| File | Size | SHA-256 | Derived from | Built | Consumed by |
|---|---|---|---|---|---|
| `derived/2025-noprompt.iso` | 8,148,064,256 B (~7.6 GiB) | `b734d2482ee7bfc6f2b284188e7744236daa45f7e11700a9005f861ec77d0d36` | The stock 2025 ISO above (swaps in Microsoft's own `_noprompt` boot files — see `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md` Finding 15's resolution writeup) | 2026-09-05T17:08:27Z | `build.sh`'s `check_noprompt_iso_cache`/`build_noprompt_iso`; this, not the stock 2025 ISO, is what `windows-server.pkr.hcl` actually boots for `windows_version=2025` |

This is the one artifact under `../iso_cache/` that's specific to *this* project rather than
genuinely shared — the sibling project builds its own equivalent noprompt ISO as a disposable,
project-local build artifact (not under the shared cache), so this `derived/` subdirectory won't
appear in the sibling's own inventory doc.

**All four checksums above independently re-verified against their `.sha256` sidecars** at the
time this file was written (`sha256sum` run directly against each cached file, not just read from
the sidecar) — confirmed byte-for-byte matching, not assumed. Same "verify before trusting"
standard `CLAUDE.md`'s Engineering Standards section calls for elsewhere in this project.

## Also present, but not consumed by this project

The cache directory is shared, so `ls ../iso_cache/` also shows files that belong entirely to the
sibling project — don't be surprised by them, and don't expect `build.sh` here to ever touch them
(`packer/variables.pkr.hcl`'s `windows_version` variable only accepts `"2022"`/`"2025"`, enforced
by its own validation block):

| File | Belongs to |
|---|---|
| `win11ent-CLIENTENTERPRISEEVAL_x64FRE_en-us.iso` | Sibling project's Windows 11 track |
| `2019-17763.3650.221105-1748.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso` | Sibling project's Windows Server 2019 track |
| `spice-guest-tools-latest.exe` | Sibling project's SPICE guest tools injection |

See the sibling project's own `ISO_CACHE_INVENTORY.md` for these three's full provenance,
checksums, and re-download links.

## Re-download links, verified live 2026-08-23

Carried over from the sibling project's own inventory doc (same underlying files, checked the same
day) rather than re-verified independently here — see its `ISO_CACHE_INVENTORY.md` if you need a
fresher check. The "resolves to" column is the *actual* final download URL after following
Microsoft's/fedorapeople.org's own redirect, useful for a direct `curl`/`wget` without a browser.

| File | Fetch this URL | Resolves to (checked 2026-08-23) |
|---|---|---|
| `2022-SERVER_EVAL_x64FRE_en-us.iso` | `https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US` | `.../SERVER_EVAL_x64FRE_en-us.iso` (no build number in the filename itself — see caution below) |
| `2025-...SERVER_EVAL_x64FRE_en-us.iso` | `https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us` | `.../26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso` — same build number as what's cached, confirmed matching |
| `virtio-win-0.1.302.iso` | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso` | resolves to whatever the current stable release is — was `virtio-win-0.1.285.iso` as of 2026-08-23; the cache here has since moved on to `0.1.302` (2026-09-05), a concrete example of this being a rolling pointer, not a pinned version |

**Live caution carried over from the sibling doc, still true here:** Microsoft's fwlinks above are
rolling "current eval build" pointers, not pinned releases — they will keep moving over time by
design. Don't treat "re-download via this link" as a drop-in replacement for the currently-cached
file without re-verifying the `/IMAGE/NAME` values `packer/locals.pkr.hcl`'s `windows_edition`
field expects still exist in whatever it actually downloads (see Finding 5,
`WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`) — a newer build could rename or reorder editions.

## How to regenerate

```bash
cd ../iso_cache
ls -la
sha256sum 2022-*.iso 2025-*SERVER_EVAL*.iso virtio-win-*.iso derived/2025-noprompt.iso  # cross-check against each file's own .sha256 sidecar
for f in 2022-*.meta 2025-*SERVER_EVAL*.meta virtio-win-*.meta derived/*.meta; do echo "=== $f ==="; cat "$f"; done
du -sh . derived/
```

Update the tables above from that output, bump the snapshot date, and note anything that changed
(new file, removed file, a checksum that no longer matches its sidecar — that would itself be worth
investigating before assuming it's just a benign re-download or re-derive).

# Windows installer appears to stall ("stuck at 75%")

The NSIS installer (`OmniRoute.Setup.<version>.exe`, ~592 MiB) extracts a 7z payload of
roughly 20k files. Three separate passes write those files to disk, and the progress bar is
driven by two different mechanisms at once, so a bar that stops moving is **usually not a
hang** — it is the slow phase. This page lists what to check, in order, before treating it
as a broken download.

## What the installer is doing

| Phase | What happens                                                    | Progress bar                    |
| ----- | --------------------------------------------------------------- | ------------------------------- |
| 1     | "Is OmniRoute running?" check + old uninstaller (if upgrading)  | crawls, sometimes pauses        |
| 2     | `app-64.7z` copied to `%TEMP%`                                  | reaches ~75–100%                |
| 3     | `Nsis7z::Extract` unpacks into a temp folder                    | **resets to 0 and fills again** |
| 4     | `CopyFiles` copies the unpacked tree into your chosen directory | barely moves                    |

Phase 3/4 is the long one: every extracted `exe`/`dll`/`node` file is scanned again by
Microsoft Defender. On a laptop with an active antivirus scan, a slow SSD, or a
low-memory machine, this can take 10–30+ minutes with no visible progress. Phases 2 and 4
combined also mean the app is written to disk roughly twice.

## Check whether it is actually working

Open Task Manager (Ctrl+Shift+Esc) → **Details**:

- `OmniRoute.Setup.*.exe` present, CPU mostly 0%, and **I/O read/write bytes still rising** →
  it is working, just slow. Leave it.
- `MsMpEng.exe` (Defender) eating CPU → Defender is scanning the extraction; wait it out or
  add the installer and the install directory as exclusions first.
- `7z.exe` or `Nsis7z` present → extraction is in progress.
- Installer progress frozen **and** I/O counters flat for 15+ minutes → see below.

## Fixes, cheapest first

1. **Re-run with antivirus temporarily paused** (or exclude the installer + target folder).
   This is the single most common cause.
2. **Install with fewer files scanned:** install to a plain local path (`C:\OmniRoute`),
   never to a network drive, OneDrive-synced folder, or a USB stick.
3. **Close RAM hogs and free disk space** — the installer needs roughly 1.5× the final
   install size free in both `%TEMP%` and the target drive (i.e. ~2 GB, more if the temp
   folder is small).
4. **Clear stale temp leftovers:** close the stuck installer, delete
   `%TEMP%\*` leftovers such as `ns*.tmp` / `7z-out*`, then re-run.
5. **Re-download the installer** with a download manager or `curl.exe`, and verify the size
   is exactly **620 348 073 bytes** for 3.8.52. A truncated/AV-mangled file fails either
   instantly or mid-extraction. A browser that "resumed" a partial download is a common
   source of a corrupt payload.
6. **Skip the installer entirely** — the portable build needs no NSIS at all:
   download `OmniRoute.exe` (~592 MiB), put it in a folder you can write to, and run it.
   The first start unpacks its payload once, which can also take a few minutes.
7. **Install from an elevated shell** (`Run as administrator`) if the target directory or
   the Start Menu shortcut step is the thing being blocked.

## When it really is a hang

If Task Manager shows the installer using 0% CPU with flat I/O for 15+ minutes while
`%TEMP%` is not growing, kill it (`End task`) and collect:

- the last lines visible in the installer window (if any);
- the tail of `%TEMP%\OmniRoute-Setup-*.log` if that file exists;
- Windows Event Viewer → Windows Logs → Application, entries around the time of the hang;
- whether a previous OmniRoute install exists — an upgrade runs the **old uninstaller**
  first, and a half-broken old install can block the new one. Fix: uninstall OmniRoute from
  _Apps & features_, delete the leftover install folder, then install again.

Report those on the issue tracker together with the installer version, Windows build
(`winver`) and antivirus product.

## For maintainers — why this is inherent to the current packaging

- `electron/package.json` → `nsis` uses `oneClick: false` (needed for the directory picker
  and shortcuts). electron-builder's assisted installer always routes through
  `File` → `Nsis7z::Extract` → `CopyFiles`, so the payload is written to disk twice and the
  bar is redrawn by `Nsis7z` mid-run.
- Known upstream behaviour, not an OmniRoute bug:
  [electron-builder#10469](https://github.com/electron-userland/electron-builder/issues/10469)
  (bar fills and drops during install) and the app-running check in
  `allowOnlyOneInstallerInstance.nsh` spawning PowerShell with no timeout
  (electron-builder#10359 / #10454).
- Options that would actually shorten the wall-clock time, in order of effect:
  1. publish a **ZIP** (or keep the existing `portable` target as the recommended path for
     slow machines) so no NSIS extraction happens at all;
  2. cut the payload size — the bulk is the Electron runtime + standalone Next bundle;
     trimming dev-only files from the `extraResources` filter reduces both passes;
  3. `nsis.compression: "store"` trades a much larger download for a slightly faster
     extract (measured ~5% upstream — rarely worth it);
  4. `nsis.differentialPackage` / update-path tuning only affects updates, not first install.

Any of 1–2 is a packaging change that must be validated by the `electron-release.yml`
workflow on `windows-latest`; it is not a one-line switch, which is why it is recorded here
rather than applied blind.

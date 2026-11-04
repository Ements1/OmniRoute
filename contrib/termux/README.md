# Termux installer — OmniRoute on Android

One script that turns a fresh Termux install into a running OmniRoute server (web
dashboard + OpenAI-compatible API) on the phone. This is the Android/Termux counterpart
of the Windows/macOS desktop installers: the server is identical, there is no Electron
shell and no tray icon.

## Install

1. Install **Termux from F-Droid or GitHub Releases** — not Google Play. The Play build
   is outdated and its package repository no longer resolves.
2. Download `install-omniroute-termux.sh` onto the phone (browser, `curl`, or keep the
   clone you already have).
3. In Termux, run it with `bash` explicitly (Termux has no `/usr/bin/env`, so `./script`
   fails unless you run `termux-fix-shebang` first):

```bash
bash install-omniroute-termux.sh --start
```

With a source checkout:

```bash
cd /path/to/OmniRoute/contrib/termux
bash install-omniroute-termux.sh --start
```

Options:

| Flag           | Effect                                                             |
| -------------- | ------------------------------------------------------------------ |
| `--start`      | Start the server right after installing                            |
| `--port <n>`   | Dashboard/API port (default `20128`, or `$OMNIROUTE_PORT`)         |
| `--method npx` | Never install globally — always run through `npx omniroute@latest` |
| `--no-service` | Skip the Termux:Boot autostart hook                                |
| `--dry-run`    | Print every step without touching the system                       |
| `-h, --help`   | Usage                                                              |

## What it does

1. Refuses to run outside Termux (a desktop shell gets a pointer to the Electron
   installer instead).
2. `pkg install nodejs python build-essential git` — the toolchain `better-sqlite3` and
   the other native dependencies compile against on Android.
3. Checks Node.js against the supported range
   (`>=22.22.2 <23 || >=24.0.0 <27`, see `bin/nodeRuntimeSupport.mjs`). Termux's
   `nodejs-lts` is Node 20 and is rejected with the fix command.
4. `npm install -g omniroute@latest` (or nothing, with `--method npx`).
5. Writes a control script at `$HOME/omniroute/omniroute.sh` and, unless
   `--no-service`, a [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) hook at
   `$HOME/.termux/boot/omniroute.sh`.
6. Optionally starts the server and waits until `/api/health/ping` answers.

Everything stays inside Termux's own tree: no root, no writes outside `$HOME` and
`$PREFIX`. Data lives in `$HOME/.omniroute` (the platform default from
`bin/cli/data-dir.mjs`).

## Everyday use

```bash
$HOME/omniroute/omniroute.sh start    # background start, waits for readiness
$HOME/omniroute/omniroute.sh status   # is it up?
$HOME/omniroute/omniroute.sh url      # dashboard + /v1 base URL, incl. the LAN IP
$HOME/omniroute/omniroute.sh logs     # tail $HOME/.omniroute/omniroute.log
$HOME/omniroute/omniroute.sh stop     # stop the server
```

The dashboard is `http://localhost:20128` on the phone, and
`http://<phone-ip>:20128` from any other device on the same WiFi.

## Notes

- **Battery optimisation must be off for Termux** (Android Settings → Apps → Termux →
  Battery → Unrestricted), otherwise Android suspends the server when the screen locks.
- The CLI already skips the browser popup on Termux; the script also passes `--no-open`.
- The server binds `0.0.0.0` with no API-key requirement by default
  (`bin/cli/utils/serverHost.mjs`). On shared/untrusted WiFi set `REQUIRE_API_KEY=true`
  or `OMNIROUTE_SERVER_HOST=127.0.0.1`.
- Add the dashboard to the home screen as a PWA from Chrome (⋮ → "Add to Home screen") —
  see `docs/guides/PWA_GUIDE.md`.
- Browser-driving providers (web-cookie/Gemini-web style) need Playwright's Chromium,
  which is not part of this install: `npx playwright install chromium`.
- Missing `better-sqlite3` is not fatal (OmniRoute falls back to `node:sqlite`), but the
  toolchain step above is what makes the native build succeed in the first place.
- Full background and troubleshooting: `docs/guides/TERMUX_GUIDE.md`.

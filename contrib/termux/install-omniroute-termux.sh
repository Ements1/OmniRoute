#!/usr/bin/env bash
# install-omniroute-termux.sh — one-shot OmniRoute installer for Termux (Android).
#
# What it does, in order:
#   1. sanity-checks that it is really running inside Termux (not a desktop shell);
#   2. installs the Termux build toolchain the native dependencies need
#      (nodejs, python, build-essential, git) via `pkg`;
#   3. verifies the Node.js line against SUPPORTED_NODE_RANGE
#      (bin/nodeRuntimeSupport.mjs: ">=22.22.2 <23 || >=24.0.0 <27");
#   4. installs the published package (`npm i -g omniroute`, or npx-only mode);
#   5. drops a small control script in $HOME/omniroute (start|stop|status|logs|url)
#      and, unless --no-service, a Termux:Boot hook in $HOME/.termux/boot/;
#   6. optionally starts the server and waits for /api/health/ping to answer.
#
# Termux has no /usr/bin/env, so run it explicitly:
#     bash install-omniroute-termux.sh
# (`termux-fix-shebang install-omniroute-termux.sh` also works if you prefer ./).
#
# Everything the script writes lives under $HOME: the npm prefix ($PREFIX), the
# data directory ($HOME/.omniroute, see bin/cli/data-dir.mjs) and the helper
# scripts. Nothing needs root and nothing is written outside Termux's own tree.
#
# This is the Termux equivalent of the Windows/macOS installers: the server is
# identical, there is just no Electron shell (see docs/guides/TERMUX_GUIDE.md).
set -euo pipefail

SCRIPT_NAME="install-termux"
DEFAULT_PORT="20128"
OMNIROUTE_PACKAGE="omniroute@latest"
CONTROL_DIR="${HOME}/omniroute"
BOOT_HOOK="${HOME}/.termux/boot/omniroute.sh"

PORT="${OMNIROUTE_PORT:-$DEFAULT_PORT}"
METHOD="global"
START_AFTER_INSTALL=0
CREATE_SERVICE=1
DRY_RUN=0

log() { printf '\033[36m[%s]\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; }
ok() { printf '\033[32m[%s] ✔\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; }
warn() { printf '\033[33m[%s] WARN:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() {
  printf '\033[31m[%s] ERROR:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash install-omniroute-termux.sh [options]

Installs OmniRoute inside Termux on Android (headless server + web dashboard).

Options:
  --port <port>      Dashboard/API port (default: 20128, or $OMNIROUTE_PORT)
  --method <mode>    global = npm install -g omniroute (default)
                     npx    = never install globally, always run via npx
  --no-service       Do not create the Termux:Boot autostart hook
  --start            Start the server right after installing
  --dry-run          Print every step without running it
  -h, --help         Show this help and exit

After installing:
  $HOME/omniroute/omniroute.sh start    # start in the background
  $HOME/omniroute/omniroute.sh status   # is it up, and on which URLs
  $HOME/omniroute/omniroute.sh url      # dashboard + OpenAI-compatible base URL
  $HOME/omniroute/omniroute.sh logs     # tail the server log
  $HOME/omniroute/omniroute.sh stop     # stop it
EOF
}

# ── argument parsing ───────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      [ -n "${2:-}" ] || die "--port needs a value"
      PORT="$2"
      shift 2
      ;;
    --method)
      [ -n "${2:-}" ] || die "--method needs a value (global|npx)"
      METHOD="$2"
      shift 2
      ;;
    --no-service)
      CREATE_SERVICE=0
      shift
      ;;
    --start)
      START_AFTER_INSTALL=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$METHOD" in
  global | npx) ;;
  *) die "--method must be 'global' or 'npx' (got: $METHOD)" ;;
esac

case "$PORT" in
  "" | *[!0-9]*) die "--port must be a number (got: $PORT)" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port must be between 1 and 65535"

# ── helpers ────────────────────────────────────────────────────────────────

# Run a command, or only print it under --dry-run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "would run: $*"
    return 0
  fi
  "$@"
}

is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] && return 0
  case "${PREFIX:-}" in */com.termux/*) return 0 ;; esac
  [ -d /data/data/com.termux ]
}

# Mirrors SUPPORTED_NODE_RANGE in bin/nodeRuntimeSupport.mjs:
#   ">=22.22.2 <23 || >=24.0.0 <27"
node_version_ok() {
  local raw major minor patch
  raw="$(node -p 'process.versions.node' 2>/dev/null)" || return 1
  major="${raw%%.*}"
  minor="$(printf '%s' "$raw" | cut -d. -f2)"
  patch="$(printf '%s' "$raw" | cut -d. -f3)"
  [ -n "$patch" ] || patch=0
  case "$major$minor$patch" in *[!0-9]*) return 1 ;; esac
  if [ "$major" -eq 22 ] && [ "$minor" -ge 22 ]; then return 0; fi
  if [ "$major" -ge 24 ] && [ "$major" -lt 27 ]; then return 0; fi
  return 1
}

# ── step 1: environment ────────────────────────────────────────────────────
step_environment() {
  if is_termux; then
    ok "Termux detected (${TERMUX_VERSION:-PREFIX=$PREFIX})"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "not running inside Termux — continuing because --dry-run was requested"
    return 0
  fi
  die "this installer targets Termux on Android.
       Install Termux from F-Droid or GitHub Releases, open it, and re-run this
       script *inside Termux*. For a desktop install see README.md (the Electron
       installer) or docs/guides/DOCKER_GUIDE.md."
}

# ── step 2: build toolchain ────────────────────────────────────────────────
step_packages() {
  log "installing Termux build toolchain (nodejs, python, build-essential, git)"
  # `pkg update` occasionally fails on a stale mirror; that is recoverable —
  # the install below still works against the cached package index.
  run pkg update -y || warn "pkg update failed — continuing with the cached index"
  run pkg install -y nodejs python build-essential git
}

# ── step 3: Node.js check ──────────────────────────────────────────────────
step_node_check() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "would verify the Node.js version against >=22.22.2 <23 || >=24.0.0 <27"
    return 0
  fi
  command -v node >/dev/null 2>&1 || die "node is still missing after pkg install — re-run: pkg install nodejs"
  local raw
  raw="$(node -p 'process.versions.node')"
  if node_version_ok; then
    ok "Node.js v${raw} is supported"
    return 0
  fi
  die "Node.js v${raw} is NOT supported. OmniRoute needs >=22.22.2 <23 or >=24.0.0 <27.
       Termux's 'nodejs-lts' package is Node 20 — replace it with the current line:
         pkg uninstall nodejs-lts; pkg install nodejs
       then re-run this installer."
}

# ── step 4: install OmniRoute ──────────────────────────────────────────────
step_install() {
  # Next.js needs a writable cache root on Android; the CLI also creates it
  # (bin/cli/utils/ensureAndroidCacheDir.mjs), but doing it up front keeps the
  # very first `omniroute` run from failing on a read-only/no-$HOME shell.
  run mkdir -p "${HOME}/.cache" "${HOME}/.omniroute"
  if [ "$METHOD" = "npx" ]; then
    log "npx mode: the package is fetched on every start, nothing is installed globally"
    run npm --version >/dev/null
    return 0
  fi
  log "installing ${OMNIROUTE_PACKAGE} globally (this compiles native deps, expect several minutes)"
  run npm install -g "$OMNIROUTE_PACKAGE"
  if [ "$DRY_RUN" -eq 0 ]; then
    local installed
    installed="$(omniroute --version 2>/dev/null || true)"
    [ -n "$installed" ] && ok "omniroute ${installed} installed at $(command -v omniroute)"
  fi
}

# ── step 5: control + boot scripts ─────────────────────────────────────────
write_control_script() {
  local run_cmd
  if [ "$METHOD" = "npx" ]; then
    run_cmd="npx -y ${OMNIROUTE_PACKAGE} serve --port \"\$PORT\" --no-open"
  else
    run_cmd="omniroute serve --port \"\$PORT\" --no-open"
  fi

  mkdir -p "$CONTROL_DIR"
  cat >"${CONTROL_DIR}/omniroute.sh" <<CONTROL_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Generated by contrib/termux/install-omniroute-termux.sh — safe to edit.
set -uo pipefail

PORT="\${OMNIROUTE_PORT:-${PORT}}"
DATA_DIR="\${DATA_DIR:-\$HOME/.omniroute}"
LOG="\$DATA_DIR/omniroute.log"
PIDFILE="\$DATA_DIR/omniroute.pid"

# Bind all interfaces so other devices on the WiFi can reach the dashboard.
# Set OMNIROUTE_SERVER_HOST=127.0.0.1 to keep it loopback-only.
export OMNIROUTE_SERVER_HOST="\${OMNIROUTE_SERVER_HOST:-0.0.0.0}"
export DATA_DIR
mkdir -p "\$DATA_DIR" "\$HOME/.cache"

health() {
  node -e '
    const port = process.argv[1];
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 3000);
    fetch("http://127.0.0.1:" + port + "/api/health/ping", { signal: ac.signal })
      .then((r) => process.exit(r.ok ? 0 : 1))
      .catch(() => process.exit(1))
      .finally(() => clearTimeout(timer));
  ' "\$PORT"
}

wait_ready() {
  local i=0
  while [ \$i -lt 90 ]; do
    if health; then return 0; fi
    sleep 2
    i=\$((i + 1))
  done
  return 1
}

case "\${1:-status}" in
  start)
    if health; then echo "OmniRoute is already running on port \$PORT"; exit 0; fi
    nohup ${run_cmd} >>"\$LOG" 2>&1 &
    echo \$! >"\$PIDFILE"
    echo "Starting OmniRoute in the background (PID \$(cat "\$PIDFILE"))..."
    if wait_ready; then
      echo "✔ OmniRoute is up:"
      echo "  Dashboard:  http://localhost:\$PORT"
      echo "  API base:   http://localhost:\$PORT/v1"
    else
      echo "✖ Server did not answer on /api/health/ping within 3 minutes."
      echo "  Check the log: $CONTROL_DIR/omniroute.sh logs"
      exit 1
    fi
    ;;
  stop)
    if [ -f "\$PIDFILE" ] && kill "\$(cat "\$PIDFILE")" 2>/dev/null; then
      rm -f "\$PIDFILE"
      pkill -f "omniroute serve" 2>/dev/null || true
      echo "Stopped."
    else
      pkill -f "omniroute serve" 2>/dev/null && echo "Stopped." || echo "Not running."
      rm -f "\$PIDFILE"
    fi
    ;;
  status)
    if health; then
      echo "✔ running on port \$PORT (dashboard http://localhost:\$PORT)"
    else
      echo "✖ not answering on port \$PORT"
      exit 1
    fi
    ;;
  url)
    node -e '
      const os = require("node:os");
      const port = process.argv[1];
      const lan = Object.values(os.networkInterfaces()).flat()
        .filter((i) => i && i.family === "IPv4" && !i.internal)
        .map((i) => i.address);
      console.log("Dashboard (this phone): http://localhost:" + port);
      for (const ip of lan) console.log("From the LAN:           http://" + ip + ":" + port);
      console.log("API base:               http://localhost:" + port + "/v1");
    ' "\$PORT"
    ;;
  logs)
    tail -n "\${2:-100}" -f "\$LOG"
    ;;
  *)
    echo "Usage: \$0 {start|stop|status|url|logs}" >&2
    exit 2
    ;;
esac
CONTROL_EOF
  chmod +x "${CONTROL_DIR}/omniroute.sh"
}

write_boot_hook() {
  mkdir -p "$(dirname "$BOOT_HOOK")"
  cat >"$BOOT_HOOK" <<BOOT_EOF
#!/data/data/com.termux/files/usr/bin/sh
# Generated by contrib/termux/install-omniroute-termux.sh
# Runs on device boot via the Termux:Boot add-on (F-Droid).
termux-wake-lock 2>/dev/null || true
exec "\$HOME/omniroute/omniroute.sh" start >>"\$HOME/.omniroute/boot.log" 2>&1
BOOT_EOF
  chmod +x "$BOOT_HOOK"
}

step_scripts() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "would write ${CONTROL_DIR}/omniroute.sh (start|stop|status|url|logs)"
    [ "$CREATE_SERVICE" -eq 1 ] && log "would write boot hook ${BOOT_HOOK}"
    return 0
  fi
  write_control_script
  ok "control script: ${CONTROL_DIR}/omniroute.sh"
  if [ "$CREATE_SERVICE" -eq 1 ]; then
    write_boot_hook
    ok "boot hook: ${BOOT_HOOK} (requires the Termux:Boot add-on)"
  else
    log "skipping the Termux:Boot hook (--no-service)"
  fi
}

# ── step 6: optional start ─────────────────────────────────────────────────
step_start() {
  if [ "$START_AFTER_INSTALL" -ne 1 ]; then
    log "not starting automatically — run: ${CONTROL_DIR}/omniroute.sh start"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "would run: ${CONTROL_DIR}/omniroute.sh start"
    return 0
  fi
  "${CONTROL_DIR}/omniroute.sh" start
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "DRY RUN — nothing will be installed"
  fi
  step_environment
  step_packages
  step_node_check
  step_install
  step_scripts
  step_start

  cat >&2 <<FINAL

$(ok "OmniRoute (Termux) installation finished")

  Dashboard:      http://localhost:${PORT}
  API base:       http://localhost:${PORT}/v1
  Data directory: \$HOME/.omniroute
  Control script: ${CONTROL_DIR}/omniroute.sh {start|stop|status|url|logs}

  First-run checklist:
    1. Disable battery optimisation for Termux (Android Settings → Apps → Termux),
       otherwise Android suspends the server while the screen is off.
    2. Open the dashboard and connect at least one provider.
    3. Point CLI tools at http://localhost:${PORT}/v1 on the phone, or at
       http://<phone-ip>:${PORT}/v1 from another device on the same WiFi.
    4. The server binds 0.0.0.0 with no API-key requirement by default — set
       REQUIRE_API_KEY=true (or OMNIROUTE_SERVER_HOST=127.0.0.1) on untrusted
       networks.

  Optional: install the dashboard as an app icon — open the URL in Chrome,
  menu ⋮ → "Add to Home screen" (see docs/guides/PWA_GUIDE.md).
FINAL
}

main

/**
 * tests/unit/termux-installer-script.test.ts
 *
 * Contract tests for contrib/termux/install-omniroute-termux.sh — the one-shot
 * Android/Termux installer. It installs packages and writes autostart hooks, so
 * the suite pins the safety contract instead of running a real install:
 *
 *   - it is an executable bash script with strict mode;
 *   - `bash -n` accepts it and `--help` documents every flag it parses;
 *   - it refuses to run outside Termux (no `pkg` calls on a desktop shell);
 *   - unknown flags, a bad --method and a non-numeric --port are rejected;
 *   - --dry-run on this (non-Termux) machine still succeeds and touches nothing;
 *   - the Node.js gate matches SUPPORTED_NODE_RANGE from bin/nodeRuntimeSupport.mjs.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

import { SUPPORTED_NODE_RANGE } from "../../bin/nodeRuntimeSupport.mjs";

const ROOT = path.resolve(import.meta.dirname, "..", "..");
const SCRIPT = path.join(ROOT, "contrib", "termux", "install-omniroute-termux.sh");
const README = path.join(ROOT, "contrib", "termux", "README.md");

/** Run the installer with a scrubbed env so a Termux-like shell cannot leak in. */
function runInstaller(args: string[], env: Record<string, string> = {}) {
  const baseEnv = { ...process.env };
  delete baseEnv.TERMUX_VERSION;
  delete baseEnv.PREFIX;
  return spawnSync("bash", [SCRIPT, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...baseEnv, ...env },
    // Never let a real `pkg`/`npm` on the host be invoked by accident.
    timeout: 30_000,
  });
}

describe("Termux installer script (contrib/termux)", () => {
  it("exists, is executable, uses bash and strict mode", () => {
    assert.ok(fs.existsSync(SCRIPT), "installer is missing");
    assert.ok(fs.statSync(SCRIPT).mode & 0o111, "installer is not executable (chmod +x)");
    const body = fs.readFileSync(SCRIPT, "utf8");
    assert.ok(body.startsWith("#!/usr/bin/env bash"), "installer needs a bash shebang");
    assert.ok(body.includes("set -euo pipefail"), "installer needs 'set -euo pipefail'");
  });

  it("passes `bash -n`", () => {
    const r = spawnSync("bash", ["-n", SCRIPT], { encoding: "utf8" });
    assert.equal(r.status, 0, `syntax error: ${r.stderr}`);
  });

  it("--help exits 0 and documents every flag", () => {
    const r = runInstaller(["--help"]);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /Usage:/);
    for (const flag of ["--port", "--method", "--no-service", "--start", "--dry-run"]) {
      assert.ok(r.stdout.includes(flag), `--help does not document ${flag}`);
    }
  });

  it("refuses to run outside Termux (no package install on a desktop shell)", () => {
    const r = runInstaller([]);
    assert.notEqual(r.status, 0, "installer must fail outside Termux");
    assert.match(r.stderr, /Termux/);
    assert.doesNotMatch(r.stdout + r.stderr, /pkg install/, "must not reach the pkg step");
  });

  it("--dry-run on a non-Termux shell plans the install without executing it", () => {
    const r = runInstaller(["--dry-run"]);
    assert.equal(r.status, 0, `dry run failed: ${r.stderr}`);
    assert.match(r.stderr, /DRY RUN/);
    assert.match(r.stderr, /would run: pkg install -y nodejs python build-essential git/);
    assert.match(r.stderr, /would run: npm install -g omniroute@latest/);
    // A dry run must never actually invoke a package manager or npm.
    assert.doesNotMatch(r.stderr, /command not found: pkg/);
    assert.doesNotMatch(r.stdout + r.stderr, /^added \d+ packages/m);
  });

  it("rejects unknown flags and invalid option values", () => {
    const unknown = runInstaller(["--nope"]);
    assert.notEqual(unknown.status, 0);
    assert.match(unknown.stderr, /unknown argument/);

    const badMethod = runInstaller(["--method", "docker"]);
    assert.notEqual(badMethod.status, 0);
    assert.match(badMethod.stderr, /--method must be/);

    for (const badPort of ["abc", "0", "70000"]) {
      const r = runInstaller(["--port", badPort]);
      assert.notEqual(r.status, 0, `--port ${badPort} should be rejected`);
    }

    const missingValue = runInstaller(["--port"]);
    assert.notEqual(missingValue.status, 0);
    assert.match(missingValue.stderr, /needs a value/);
  });

  it("Node.js gate matches SUPPORTED_NODE_RANGE from bin/nodeRuntimeSupport.mjs", () => {
    const body = fs.readFileSync(SCRIPT, "utf8");
    // Keep the script and the runtime support module from drifting apart: both
    // spell the same range (22.22.2 floor, <27 ceiling, no 23.x).
    assert.equal(SUPPORTED_NODE_RANGE, ">=22.22.2 <23 || >=24.0.0 <27");
    assert.ok(body.includes(SUPPORTED_NODE_RANGE), "installer does not quote the range");
    assert.ok(
      body.includes('"$major" -eq 22 ] && [ "$minor" -ge 22'),
      "installer lost the 22.22 floor check"
    );
    assert.ok(
      body.includes('"$major" -ge 24 ] && [ "$major" -lt 27'),
      "installer lost the 24..26 window check"
    );
  });

  it("README documents the bash invocation Termux needs", () => {
    const body = fs.readFileSync(README, "utf8");
    assert.match(body, /bash install-omniroute-termux\.sh/, "README must show `bash <script>`");
    assert.match(body, /Termux:Boot/, "README must mention the Termux:Boot add-on");
    assert.match(body, /docs\/guides\/TERMUX_GUIDE\.md/, "README must link the Termux guide");
    assert.ok(fs.existsSync(path.join(ROOT, "docs", "guides", "TERMUX_GUIDE.md")));
  });
});

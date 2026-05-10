#!/usr/bin/env node
/**
 * zponder npm postinstall — select the correct binary for the current platform.
 *
 * The package ships with pre-built binaries in bin/<platform>/.
 * This script symlinks (or copies) the correct one to bin/zponder.
 */

const fs = require("fs");
const path = require("path");
const os = require("os");

const BIN_DIR = path.join(__dirname, "bin");
const TARGET = path.join(BIN_DIR, "zponder");

function platformDir() {
  const plat = os.platform();   // "darwin" | "linux" | "win32"
  const arch = os.arch();       // "arm64" | "x64"
  return `${plat}-${arch}`;
}

function run() {
  const dir = platformDir();
  const source = path.join(BIN_DIR, dir, "zponder");

  if (!fs.existsSync(source)) {
    console.error(
      `zponder: no pre-built binary for ${dir}. ` +
      `Available: ${fs.readdirSync(BIN_DIR).filter(f => f !== "zponder" && !f.endsWith(".js")).join(", ")}. ` +
      `Build from source: https://github.com/chy3xyz/zponder`
    );
    process.exit(1);
  }

  // Remove existing link/copy
  try { fs.unlinkSync(TARGET); } catch (_) { /* ok */ }

  // Prefer hard link, fall back to copy
  try {
    fs.linkSync(source, TARGET);
    console.log(`zponder: linked bin/${dir}/zponder → bin/zponder`);
  } catch (_) {
    fs.copyFileSync(source, TARGET);
    fs.chmodSync(TARGET, 0o755);
    console.log(`zponder: copied bin/${dir}/zponder → bin/zponder`);
  }
}

run();

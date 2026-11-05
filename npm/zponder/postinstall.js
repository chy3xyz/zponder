#!/usr/bin/env node
/**
 * zponder postinstall — verify runtime dependencies are available.
 * The bin/zponder wrapper script auto-detects the platform at runtime.
 */
const { execSync, execFileSync } = require("child_process");
const os = require("os");
const fs = require("fs");

const BOLD = "\x1b[1m";
const RESET = "\x1b[0m";

function run() {
  const plat = os.platform() + "-" + os.arch();
  const binDir = `${__dirname}/bin`;

  // Check if pre-built binary exists for this platform
  const binaryPath = `${binDir}/${plat}/zponder`;
  if (fs.existsSync(binaryPath)) {
    console.log(`zponder: pre-built binary found for ${plat}`);
    try {
      const versionOutput = execFileSync(binaryPath, ["version"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
      console.log("zponder: zponder version smoke check output:");
      process.stdout.write(versionOutput.endsWith("\n") ? versionOutput : `${versionOutput}\n`);
    } catch (error) {
      console.error(`${BOLD}zponder: installed binary failed the 'zponder version' smoke check.${RESET}`);
      console.error(`zponder: reinstall the package or build from source if this persists (${binaryPath}).`);
      const detail = error.stderr || error.stdout || error.message;
      if (detail) console.error(String(detail).trim());
      process.exitCode = 1;
      return;
    }
  } else if (plat !== "darwin-arm64") {
    // Pre-built currently only for darwin-arm64
    console.log(`zponder: no pre-built binary for ${plat} (available: darwin-arm64)`);
  }

  // Check sqlite3
  if (os.platform() === "darwin") {
    try {
      execSync("pkg-config --exists sqlite3 2>/dev/null || echo sqlite3 | cc -lsqlite3 -x c - -o /dev/null 2>/dev/null", { stdio: "ignore" });
    } catch (_) {
      console.log("");
      console.log(`${BOLD}  zponder requires SQLite3. Install it:${RESET}`);
      console.log(`    brew install sqlite3`);
      console.log("");
    }
  }
  if (os.platform() === "linux") {
    try {
      execSync("ldconfig -p 2>/dev/null | grep -q libsqlite3 || dpkg -l libsqlite3-dev 2>/dev/null", { stdio: "ignore" });
    } catch (_) {
      console.log("");
      console.log(`${BOLD}  zponder requires SQLite3. Install it:${RESET}`);
      console.log(`    apt install libsqlite3-dev`);
      console.log("");
    }
  }
}

run();

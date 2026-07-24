#!/usr/bin/env node
/**
 * Claude Max API Proxy — standalone server
 *
 * Usage:
 *   npm start
 *   node dist/server/standalone.js [port]
 */

import { startServer, stopServer } from "./index.js";
import { verifyClaude, verifyAuth } from "../subprocess/manager.js";
import { resolveClaudeBin } from "../subprocess/claude-bin.js";
import { getAdvertisedModelIds } from "../models/catalog.js";
import { PROXY_NAME, PROXY_VERSION } from "../version.js";

const DEFAULT_PORT = 3456;

function banner(port: number, cliVersion: string, bin: string, warning?: string): void {
  const models = getAdvertisedModelIds().filter(
    (id) => id.startsWith("claude-") && !id.endsWith("-max")
  );
  const highlight = ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-haiku-4-5"];

  console.log("");
  console.log(`  ${PROXY_NAME}  v${PROXY_VERSION}`);
  console.log("  ==============================================");
  console.log(`  API:       http://127.0.0.1:${port}/v1`);
  console.log(`  Health:    http://127.0.0.1:${port}/health`);
  console.log(`  Claude:    ${cliVersion}`);
  console.log(`  Binary:    ${bin}`);
  console.log("  Models:");
  for (const id of highlight.filter((h) => models.includes(h))) {
    console.log(`    - ${id}`);
  }
  console.log(`    (+ ${models.length} total via GET /v1/models)`);
  if (warning) {
    console.log("");
    console.log(`  ! ${warning}`);
  }
  console.log("  ==============================================");
  console.log("");
}

async function main(): Promise<void> {
  const port = parseInt(process.argv[2] || String(DEFAULT_PORT), 10);
  if (isNaN(port) || port < 1 || port > 65535) {
    console.error(`Invalid port: ${process.argv[2]}`);
    process.exit(1);
  }

  // Ensure CLAUDE_BIN is set before any spawn (fixes Windows EINVAL)
  const bin = resolveClaudeBin();
  process.env.CLAUDE_BIN = bin;

  console.log(`Checking Claude CLI (${bin})...`);
  const cliCheck = await verifyClaude();
  if (!cliCheck.ok) {
    console.error(`Error: ${cliCheck.error}`);
    process.exit(1);
  }
  console.log(`  OK: ${cliCheck.version}`);
  if (cliCheck.warning) {
    console.warn(`  Warning: ${cliCheck.warning}`);
  }

  console.log("Checking authentication...");
  const authCheck = await verifyAuth();
  if (!authCheck.ok) {
    console.error(`Error: ${authCheck.error}`);
    console.error("Please run: claude auth login");
    process.exit(1);
  }
  console.log("  Authentication: OK");

  try {
    await startServer({ port });
    banner(port, cliCheck.version || "unknown", bin, cliCheck.warning);
    console.log("Ready. Example:");
    console.log(`  curl -X POST http://127.0.0.1:${port}/v1/chat/completions \\`);
    console.log(`    -H "Content-Type: application/json" \\`);
    console.log(
      `    -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"Hello!"}]}'`
    );
    console.log("\nPress Ctrl+C to stop.\n");
  } catch (err) {
    console.error("Failed to start server:", err);
    process.exit(1);
  }

  const shutdown = async () => {
    console.log("\nShutting down...");
    await stopServer();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error("Unexpected error:", err);
  process.exit(1);
});

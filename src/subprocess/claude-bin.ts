/**
 * Resolve Claude Code CLI binary path.
 * On Windows, must use claude.exe — spawning .cmd/.ps1 via spawn() causes EINVAL.
 */

import { existsSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";

const EXE_NAME = process.platform === "win32" ? "claude.exe" : "claude";

function isUsableBin(p: string | undefined | null): boolean {
  if (!p) return false;
  if (!existsSync(p)) return false;
  // Never spawn Windows cmd/ps wrappers
  if (/\.(cmd|bat|ps1)$/i.test(p)) return false;
  return true;
}

function npmGlobalRoot(): string | null {
  try {
    const out = execSync("npm root -g", { encoding: "utf8", windowsHide: true }).trim();
    return out || null;
  } catch {
    return null;
  }
}

/**
 * Absolute path to Claude CLI binary, or "claude" if on PATH (non-Windows).
 */
export function resolveClaudeBin(): string {
  const fromEnv = process.env.CLAUDE_BIN?.trim();
  if (fromEnv) {
    if (isUsableBin(fromEnv)) return fromEnv;
    // If env points at a .cmd, try sibling .exe
    if (/\.(cmd|bat)$/i.test(fromEnv)) {
      const exe = fromEnv.replace(/\.(cmd|bat)$/i, ".exe");
      if (isUsableBin(exe)) return exe;
    }
  }

  const candidates: string[] = [];
  const root = npmGlobalRoot();
  if (root) {
    candidates.push(join(root, "@anthropic-ai", "claude-code", "bin", EXE_NAME));
  }

  if (process.platform === "win32") {
    const appData = process.env.APPDATA;
    const localAppData = process.env.LOCALAPPDATA;
    const programFiles = process.env.ProgramFiles;
    if (appData) {
      candidates.push(join(appData, "npm", "node_modules", "@anthropic-ai", "claude-code", "bin", EXE_NAME));
    }
    if (localAppData) {
      // Hermes-bundled node
      candidates.push(
        join(localAppData, "hermes", "node", "node_modules", "@anthropic-ai", "claude-code", "bin", EXE_NAME)
      );
    }
    if (programFiles) {
      candidates.push(
        join(programFiles, "nodejs", "node_modules", "@anthropic-ai", "claude-code", "bin", EXE_NAME)
      );
    }
  }

  for (const p of candidates) {
    if (isUsableBin(p)) return p;
  }

  return process.platform === "win32" ? EXE_NAME : "claude";
}

/** Parse "2.1.219 (Claude Code)" → [2,1,219] */
export function parseClaudeVersion(raw: string): number[] | null {
  const m = raw.match(/(\d+)\.(\d+)\.(\d+)/);
  if (!m) return null;
  return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)];
}

export function versionAtLeast(raw: string, min: [number, number, number]): boolean {
  const v = parseClaudeVersion(raw);
  if (!v) return false;
  for (let i = 0; i < 3; i++) {
    if (v[i] > min[i]) return true;
    if (v[i] < min[i]) return false;
  }
  return true;
}

/** Opus 5 / Sonnet 5 need this Claude Code floor */
export const MIN_CLAUDE_CODE_VERSION: [number, number, number] = [2, 1, 219];

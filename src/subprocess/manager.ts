/**
 * Claude Code CLI Subprocess Manager
 *
 * Handles spawning, managing, and parsing output from Claude CLI subprocesses.
 * Uses spawn() instead of exec() to prevent shell injection vulnerabilities.
 */

import { spawn, ChildProcess } from "child_process";
import { EventEmitter } from "events";
import fs from "fs/promises";
import path from "path";
import type {
  ClaudeCliMessage,
  ClaudeCliAssistant,
  ClaudeCliResult,
  ClaudeCliStreamEvent,
} from "../types/claude-cli.js";
import {
  isAssistantMessage,
  isResultMessage,
  isContentDelta,
  isTextBlockStart,
  isToolUseBlockStart,
  isInputJsonDelta,
  isContentBlockStop,
} from "../types/claude-cli.js";
import {
  resolveClaudeBin,
  versionAtLeast,
  MIN_CLAUDE_CODE_VERSION,
} from "./claude-bin.js";
export interface SubprocessOptions {
  model: string;
  sessionId?: string;
  cwd?: string;
  timeout?: number;
}

export interface SubprocessEvents {
  message: (msg: ClaudeCliMessage) => void;
  assistant: (msg: ClaudeCliAssistant) => void;
  result: (result: ClaudeCliResult) => void;
  error: (error: Error) => void;
  close: (code: number | null) => void;
  raw: (line: string) => void;
}

const DEFAULT_TIMEOUT = 900000; // 15 minutes

/**
 * System prompt appended to Claude CLI to map OpenClaw tool names to Claude Code equivalents.
 * OpenClaw's system prompt references tools like `exec`, `read`, `web_search` etc. that
 * don't exist in Claude Code. This mapping tells the model what to use instead.
 */
const OPENCLAW_TOOL_MAPPING_PROMPT = [
  "## Tool Name Mapping",
  "You are running inside Claude Code CLI, not OpenClaw. The system prompt may reference OpenClaw tool names — map them to your actual tools:",
  "",
  "### Direct tool replacements",
  "- `exec` or `process` → use `Bash` (run shell commands)",
  "- `read` → use `Read` (read file contents)",
  "- `write` → use `Write` (write files)",
  "- `edit` → use `Edit` (edit files)",
  "- `grep` → use `Grep` (search file contents)",
  "- `find` or `ls` → use `Glob` or `Bash(ls ...)`",
  "- `web_search` → use `WebSearch`",
  "- `web_fetch` → use `WebFetch`",
  "- `image` → use `Read` (Claude Code can read images)",
  "",
  "### OpenClaw CLI tools (use via Bash)",
  "These OpenClaw tools are available through the `openclaw` CLI. Use `Bash` to run them:",
  '- `memory_search` → `Bash(openclaw memory search "<query>")` — semantic search across memory files',
  "- `memory_get` → `Read` on the memory file directly, OR `Bash(openclaw memory search \"<query>\")` for discovery",
  '- `message` → `Bash(openclaw message send --to <target> "<text>")` — send messages to channels (Telegram, Discord, etc.)',
  "  - Also: `openclaw message read`, `openclaw message broadcast`, `openclaw message react`, `openclaw message poll`",
  "- `cron` → `Bash(openclaw cron list)`, `Bash(openclaw cron add ...)`, `Bash(openclaw cron status)` — manage scheduled jobs",
  "  - Also: `openclaw cron rm`, `openclaw cron enable`, `openclaw cron disable`, `openclaw cron runs`, `openclaw cron run`, `openclaw cron edit`",
  '- `sessions_list` → `Bash(openclaw agent --local --message "list sessions")` or check session files directly',
  '- `sessions_history` → `Bash(openclaw agent --local --message "show history for session <key>")` or check session files',
  "- `nodes` → `Bash(openclaw nodes status)`, `Bash(openclaw nodes describe <node>)`, `Bash(openclaw nodes invoke --node <id> --command <cmd>)`",
  '  - Also: `openclaw nodes run --node <id> "<shell command>"` for running commands on paired nodes',
  "",
  "### Not available via CLI",
  "- `browser` — requires OpenClaw's dedicated browser server (no CLI equivalent)",
  "- `canvas` — requires paired node with canvas capability; use `openclaw nodes invoke` if a node is available",
  "",
  "### Skills",
  "When a skill says to run a bash/python command, use the `Bash` tool directly.",
  "Skills are located in the `skills/` directory relative to your working directory.",
  "To use a skill: `Read` its SKILL.md file first, then follow the instructions using `Bash`.",
  "Run `openclaw skills list --eligible --json` to see all available skills.",
].join("\n");

export class ClaudeSubprocess extends EventEmitter {
  private process: ChildProcess | null = null;
  private buffer: string = "";
  private timeoutId: NodeJS.Timeout | null = null;
  private isKilled: boolean = false;

  /**
   * Start the Claude CLI subprocess with the given prompt
   */
  async start(prompt: string, options: SubprocessOptions): Promise<void> {
    const args = this.buildArgs(options);
    const timeout = options.timeout || DEFAULT_TIMEOUT;

    return new Promise((resolve, reject) => {
      try {
        const claudeBin = resolveClaudeBin();
        if (process.env.DEBUG_SUBPROCESS) {
          console.error(`[Subprocess] CLAUDE_BIN=${claudeBin}`);
          console.error(`[Subprocess] model=${options.model}`);
        }

        // Use spawn() for security - no shell interpretation
        // Windows: must be claude.exe (not .cmd) or spawn throws EINVAL
        this.process = spawn(claudeBin, args, {
          cwd: options.cwd || process.cwd(),
          env: Object.fromEntries(
            Object.entries(process.env).filter(([k]) => k !== "CLAUDECODE")
          ),
          stdio: ["pipe", "pipe", "pipe"],
          windowsHide: true,
          shell: false,
        });

        // Set timeout
        this.timeoutId = setTimeout(() => {
          if (!this.isKilled) {
            this.isKilled = true;
            this.process?.kill("SIGTERM");
            this.emit("error", new Error(`Request timed out after ${timeout}ms`));
          }
        }, timeout);

        // Handle spawn errors (e.g., claude not found / EINVAL on .cmd)
        this.process.on("error", (err) => {
          this.clearTimeout();
          const msg = err.message || String(err);
          if (msg.includes("ENOENT")) {
            reject(
              new Error(
                "Claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
              )
            );
          } else if (msg.includes("EINVAL") || /spawn .* EINVAL/i.test(msg)) {
            reject(
              new Error(
                `Failed to spawn Claude CLI (EINVAL). On Windows set CLAUDE_BIN to claude.exe, not .cmd. Tried: ${claudeBin}`
              )
            );
          } else {
            reject(err);
          }
        });

        // Pass prompt via stdin to avoid E2BIG on large inputs
        this.process.stdin?.write(prompt);
        this.process.stdin?.end();

        if (process.env.DEBUG_SUBPROCESS) {
          console.error(`[Subprocess] Process spawned with PID: ${this.process.pid}`);
        }

        // Parse JSON stream from stdout
        this.process.stdout?.on("data", (chunk: Buffer) => {
          const data = chunk.toString();
          if (process.env.DEBUG_SUBPROCESS) {
            console.error(`[Subprocess] Received ${data.length} bytes of stdout`);
          }
          this.buffer += data;
          this.processBuffer();
        });

        // Capture stderr for debugging
        this.process.stderr?.on("data", (chunk: Buffer) => {
          const errorText = chunk.toString().trim();
          if (errorText) {
            // Don't emit as error unless it's actually an error
            // Claude CLI may write debug info to stderr
            if (process.env.DEBUG_SUBPROCESS) {
              console.error("[Subprocess stderr]:", errorText.slice(0, 200));
            }
          }
        });

        // Handle process close
        this.process.on("close", (code) => {
          if (process.env.DEBUG_SUBPROCESS) {
            console.error(`[Subprocess] Process closed with code: ${code}`);
          }
          this.clearTimeout();
          // Process any remaining buffer
          if (this.buffer.trim()) {
            this.processBuffer();
          }
          this.emit("close", code);
        });

        // Resolve immediately since we're streaming
        resolve();
      } catch (err) {
        this.clearTimeout();
        reject(err);
      }
    });
  }

  /**
   * Build CLI arguments array
   */
  private buildArgs(options: SubprocessOptions): string[] {
    const args = [
      "--print", // Non-interactive mode
      "--dangerously-skip-permissions", // Skip permission prompts
      "--output-format",
      "stream-json", // JSON streaming output
      "--verbose", // Required for stream-json
      "--include-partial-messages", // Enable streaming chunks
      "--model",
      options.model, // Model alias (opus/sonnet/haiku)
      "--no-session-persistence", // Don't save sessions
      "--append-system-prompt",
      OPENCLAW_TOOL_MAPPING_PROMPT,
      // Prompt is passed via stdin (avoids E2BIG on large inputs)
    ];

    if (options.sessionId) {
      args.push("--session-id", options.sessionId);
    }

    return args;
  }

  /**
   * Process the buffer and emit parsed messages
   */
  private processBuffer(): void {
    const lines = this.buffer.split("\n");
    this.buffer = lines.pop() || ""; // Keep incomplete line

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      try {
        const message: ClaudeCliMessage = JSON.parse(trimmed);
        this.emit("message", message);

        if (isTextBlockStart(message)) {
          // Emit when a new text content block starts (for inserting separators)
          this.emit("text_block_start", message as ClaudeCliStreamEvent);
        }

        if (isToolUseBlockStart(message)) {
          this.emit("tool_use_start", message as ClaudeCliStreamEvent);
        }

        if (isInputJsonDelta(message)) {
          this.emit("input_json_delta", message as ClaudeCliStreamEvent);
        }

        if (isContentBlockStop(message)) {
          this.emit("content_block_stop", message as ClaudeCliStreamEvent);
        }

        if (isContentDelta(message)) {
          // Emit content delta for streaming (text_delta only)
          this.emit("content_delta", message as ClaudeCliStreamEvent);
        } else if (isAssistantMessage(message)) {
          this.emit("assistant", message);
        } else if (isResultMessage(message)) {
          this.emit("result", message);
        }
      } catch {
        // Non-JSON output, emit as raw
        this.emit("raw", trimmed);
      }
    }
  }

  /**
   * Clear the timeout timer
   */
  private clearTimeout(): void {
    if (this.timeoutId) {
      clearTimeout(this.timeoutId);
      this.timeoutId = null;
    }
  }

  /**
   * Kill the subprocess
   */
  kill(signal: NodeJS.Signals = "SIGTERM"): void {
    if (!this.isKilled && this.process) {
      this.isKilled = true;
      this.clearTimeout();
      this.process.kill(signal);
    }
  }

  /**
   * Check if the process is still running
   */
  isRunning(): boolean {
    return this.process !== null && !this.isKilled && this.process.exitCode === null;
  }
}

/**
 * Verify that Claude CLI is installed and accessible
 */
export async function verifyClaude(): Promise<{
  ok: boolean;
  error?: string;
  version?: string;
  bin?: string;
  warning?: string;
}> {
  return new Promise((resolve) => {
    const bin = resolveClaudeBin();
    const proc = spawn(bin, ["--version"], {
      stdio: "pipe",
      windowsHide: true,
      shell: false,
    });
    let output = "";
    let stderr = "";

    proc.stdout?.on("data", (chunk: Buffer) => {
      output += chunk.toString();
    });
    proc.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });

    proc.on("error", (err) => {
      const msg = err.message || String(err);
      if (msg.includes("EINVAL")) {
        resolve({
          ok: false,
          bin,
          error: `Cannot spawn Claude CLI (EINVAL). Set CLAUDE_BIN to the full path of claude.exe. Tried: ${bin}`,
        });
      } else {
        resolve({
          ok: false,
          bin,
          error:
            "Claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code",
        });
      }
    });

    proc.on("close", (code) => {
      const version = (output || stderr).trim();
      if (code === 0 || version.match(/\d+\.\d+\.\d+/)) {
        const warning = versionAtLeast(version, MIN_CLAUDE_CODE_VERSION)
          ? undefined
          : `Claude Code ${version} is too old for Opus 5 / Sonnet 5. Need ${MIN_CLAUDE_CODE_VERSION.join(".")}+. Run: npm install -g @anthropic-ai/claude-code@latest`;
        resolve({ ok: true, version, bin, warning });
      } else {
        resolve({
          ok: false,
          bin,
          error: `Claude CLI returned exit ${code}. ${stderr || output}`.trim(),
        });
      }
    });
  });
}

/**
 * Check if Claude CLI is authenticated (real check — do not stub true).
 */
export async function verifyAuth(): Promise<{ ok: boolean; error?: string }> {
  return new Promise((resolve) => {
    const bin = resolveClaudeBin();
    const proc = spawn(bin, ["auth", "status"], {
      stdio: "pipe",
      windowsHide: true,
      shell: false,
    });
    let output = "";
    let stderr = "";

    proc.stdout?.on("data", (chunk: Buffer) => {
      output += chunk.toString();
    });
    proc.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });

    proc.on("error", (err) => {
      resolve({
        ok: false,
        error: `Cannot run Claude auth status (${err.message}). Is CLAUDE_BIN set to claude.exe?`,
      });
    });

    proc.on("close", () => {
      const raw = (output || stderr).trim();
      if (/"loggedIn"\s*:\s*true/.test(raw)) {
        resolve({ ok: true });
        return;
      }
      if (/"loggedIn"\s*:\s*false/.test(raw)) {
        resolve({
          ok: false,
          error:
            "Claude CLI is not logged in (OAuth expired or missing). Run: claude auth login",
        });
        return;
      }
      // Older CLIs may not print JSON — treat unknown as not ok so users re-login
      resolve({
        ok: false,
        error:
          "Could not verify Claude login. Run: claude auth login\n" +
          (raw ? raw.slice(0, 300) : "(no auth status output)"),
      });
    });
  });
}

/**
 * Pi adapter — tool_call → bridge.sh → core/dispatch (canonical schema).
 * Same policy core as Claude Code and Grok Build. Security is never prompt-based.
 *
 * Install:
 *   ln -sfn /path/to/belay/adapters/pi ~/.pi/agent/extensions/belay
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
// Deliberately no import from the Pi agent package. This adapter is a thin
// shell-out to bridge.sh and has no runtime dependencies, so there is no
// node_modules to install — but an unresolvable import (even a type-only one)
// can make the whole extension fail to load silently. Structural typing covers
// the two hooks we use.
type ExtensionAPI = {
  on: (
    event: string,
    handler: (event: any, ctx: any) => any | Promise<any>,
  ) => void;
};

const GUARDED_TOOLS = new Set([
  "bash",
  "read",
  "write",
  "edit",
  "grep",
  "find",
  "ls",
  "glob",
]);

function resolveBridge(): string | null {
  const envRoot = process.env.BELAY_ROOT;
  if (envRoot) {
    const p = join(envRoot, "adapters", "pi", "bridge.sh");
    if (existsSync(p)) return p;
  }

  // This file lives at adapters/pi/index.ts (or a symlink into ~/.pi/agent/extensions/)
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    const local = join(here, "bridge.sh");
    if (existsSync(local)) return local;
  } catch {
    // ignore
  }

  // Common checkout location
  const home = process.env.HOME || "";
  const candidates = [
    join(home, "Github", "belay", "adapters", "pi", "bridge.sh"),
    join(home, "github", "belay", "adapters", "pi", "bridge.sh"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return null;
}

type BridgeResult =
  | { block: true; reason: string }
  | { block: false; updatedInput?: Record<string, unknown> }
  | null;

function callBridge(
  bridgePath: string,
  toolName: string,
  input: Record<string, unknown>
): BridgeResult {
  const payload = JSON.stringify({ toolName, input });
  const result = spawnSync("bash", [bridgePath], {
    input: payload,
    encoding: "utf8",
    env: {
      ...process.env,
      // Prefer repo root next to adapters/pi
      BELAY_ROOT:
        process.env.BELAY_ROOT ||
        join(dirname(bridgePath), "..", ".."),
    },
    timeout: 15_000,
    maxBuffer: 2 * 1024 * 1024,
  });

  if (result.error) {
    // Fail closed on bridge infrastructure errors
    return {
      block: true,
      reason: `Belay bridge error: ${result.error.message}`,
    };
  }

  const stdout = (result.stdout || "").trim();
  if (!stdout) return null; // allow

  try {
    const parsed = JSON.parse(stdout) as {
      block?: boolean;
      reason?: string;
      updatedInput?: Record<string, unknown>;
    };
    if (parsed.block === true) {
      return { block: true, reason: parsed.reason || "Blocked by Belay" };
    }
    if (parsed.updatedInput) {
      return { block: false, updatedInput: parsed.updatedInput };
    }
    return null;
  } catch {
    // Non-JSON noise: allow rather than brick the session
    return null;
  }
}

export default function (pi: ExtensionAPI) {
  const bridgePath = resolveBridge();

  pi.on("session_start", async (_event, ctx) => {
    if (!bridgePath) {
      ctx.ui.notify(
        "Belay: bridge.sh not found. Set BELAY_ROOT.",
        "error"
      );
      return;
    }
    ctx.ui.setStatus("belay", "guard on");
  });

  pi.on("tool_call", async (event, _ctx) => {
    if (!bridgePath) {
      return {
        block: true,
        reason: "Guard bridge not found. Set BELAY_ROOT.",
      };
    }

    const name = (event.toolName || "").toLowerCase();
    if (!GUARDED_TOOLS.has(name)) return undefined;

    const input = (event.input || {}) as Record<string, unknown>;
    const result = callBridge(bridgePath, name, input);

    if (!result) return undefined;

    if (result.block) {
      return { block: true, reason: result.reason || "Blocked by Belay" };
    }

    // Mutate tool args in place (Pi guarantee: mutations affect execution)
    if (result.updatedInput) {
      for (const [k, v] of Object.entries(result.updatedInput)) {
        (event.input as Record<string, unknown>)[k] = v;
      }
    }
    return undefined;
  });
}

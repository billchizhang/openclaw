import { isMcpConfigRecord, toMcpEnvRecord, toMcpStringArray } from "./mcp-config-shared.js";

export type StdioMcpServerLaunchConfig = {
  command: string;
  args?: string[];
  env?: Record<string, string>;
  cwd?: string;
};

type StdioMcpServerLaunchResult =
  | { ok: true; config: StdioMcpServerLaunchConfig }
  | { ok: false; reason: string };

export function resolveStdioMcpServerLaunchConfig(
  raw: unknown,
  options?: { onDroppedEnv?: (key: string, value: unknown) => void },
): StdioMcpServerLaunchResult {
  if (!isMcpConfigRecord(raw)) {
    return { ok: false, reason: "server config must be an object" };
  }
  if (typeof raw.command !== "string" || raw.command.trim().length === 0) {
    if (typeof raw.url === "string" && raw.url.trim().length > 0) {
      return {
        ok: false,
        reason: "not a stdio server (has url)",
      };
    }
    return { ok: false, reason: "its command is missing" };
  }
  const cwd =
    typeof raw.cwd === "string" && raw.cwd.trim().length > 0
      ? raw.cwd
      : typeof raw.workingDirectory === "string" && raw.workingDirectory.trim().length > 0
        ? raw.workingDirectory
        : undefined;
  return {
    ok: true,
    config: {
      command: raw.command,
      args: toMcpStringArray(raw.args),
      env: toMcpEnvRecord(raw.env, { onDroppedEntry: options?.onDroppedEnv }),
      cwd,
    },
  };
}

export function describeStdioMcpServerLaunchConfig(config: StdioMcpServerLaunchConfig): string {
  const args =
    Array.isArray(config.args) && config.args.length > 0 ? ` ${config.args.join(" ")}` : "";
  const cwd = config.cwd ? ` (cwd=${config.cwd})` : "";
  return `${config.command}${args}${cwd}`;
}

export type { StdioMcpServerLaunchConfig, StdioMcpServerLaunchResult };

export type HttpMcpServerConfig = {
  url: string;
};

type HttpMcpServerResult =
  | { ok: true; config: HttpMcpServerConfig }
  | { ok: false; reason: string };

export function resolveHttpMcpServerConfig(raw: unknown): HttpMcpServerResult {
  if (!isRecord(raw)) {
    return { ok: false, reason: "server config must be an object" };
  }
  // If a command is present, defer to the stdio resolver.
  if (typeof raw.command === "string" && raw.command.trim().length > 0) {
    return { ok: false, reason: "command-based server defers to stdio" };
  }
  const url = typeof raw.url === "string" ? raw.url.trim() : "";
  if (!url) {
    return { ok: false, reason: "neither command nor url is set" };
  }
  const transport = typeof raw.transport === "string" ? raw.transport.trim().toLowerCase() : "";
  if (transport && transport !== "streamable-http" && transport !== "http") {
    return { ok: false, reason: `unsupported HTTP transport type "${transport}"` };
  }
  return { ok: true, config: { url } };
}


import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import os from "node:os";
import path from "node:path";
import type {
  AcpSessionLaunchOptions,
  ConfigValue,
  JsonRpcNotification,
  JsonRpcRequest,
  JsonRpcResponse,
} from "./types.js";

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

export interface AcpClientCallbacks {
  onNotification?: (msg: JsonRpcNotification) => void;
  onExit?: (code: number | null, signal: NodeJS.Signals | null) => void;
}

export function pickAutoApproveOption(
  options: Array<{ optionId?: string; kind?: string; name?: string }>
): string | null {
  const byKindAlways = options.find((o) => o.kind === "allow_always" && o.optionId);
  if (byKindAlways?.optionId) return byKindAlways.optionId;

  const byKindOnce = options.find((o) => o.kind === "allow_once" && o.optionId);
  if (byKindOnce?.optionId) return byKindOnce.optionId;

  const byId = options.find((o) => o.optionId?.toLowerCase().includes("allow"));
  if (byId?.optionId) return byId.optionId;

  return options[0]?.optionId ?? null;
}

export class AcpClient {
  private proc: ChildProcessWithoutNullStreams | null = null;
  private nextId = 1;
  private pending = new Map<string, PendingRequest>();
  private stdoutBuffer = "";
  private closed = false;
  private stderrTail = "";

  constructor(
    private readonly command: string,
    private readonly args: string[],
    private readonly extraEnv?: Record<string, string>,
    private readonly callbacks: AcpClientCallbacks = {}
  ) {}

  get isAlive(): boolean {
    return this.proc !== null && !this.closed && this.proc.exitCode === null;
  }

  start(cwd?: string): void {
    if (this.proc) return;
    const localBin = path.join(os.homedir(), ".local", "bin");
    const currentPath = process.env.PATH || "";
    const mergedPath = currentPath.includes(localBin)
      ? currentPath
      : `${localBin}${path.delimiter}${currentPath}`;

    this.proc = spawn(this.command, this.args, {
      cwd: cwd || os.homedir(),
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        PATH: mergedPath,
        ...this.extraEnv,
      },
    });

    this.proc.stdout.setEncoding("utf8");
    this.proc.stderr.setEncoding("utf8");

    this.proc.stdout.on("data", (chunk: string) => {
      this.stdoutBuffer += chunk;
      let idx = this.stdoutBuffer.indexOf("\n");
      while (idx !== -1) {
        const line = this.stdoutBuffer.slice(0, idx).trim();
        this.stdoutBuffer = this.stdoutBuffer.slice(idx + 1);
        if (line) {
          this.handleLine(line);
        }
        idx = this.stdoutBuffer.indexOf("\n");
      }
    });

    this.proc.stderr.on("data", (chunk: string) => {
      this.stderrTail = (this.stderrTail + chunk).slice(-4000);
    });

    this.proc.on("error", (err) => {
      this.rejectAllPending(new Error(`ACP process error: ${err.message}`));
    });

    this.proc.on("exit", (code, signal) => {
      this.closed = true;
      const tail = this.stderrTail.trim();
      const suffix = tail ? ` (${tail.slice(-300)})` : "";
      this.rejectAllPending(
        new Error(`ACP process exited with code=${code} signal=${signal}${suffix}`)
      );
      this.callbacks.onExit?.(code, signal);
    });
  }

  private rejectAllPending(err: Error): void {
    for (const [, entry] of this.pending) {
      clearTimeout(entry.timer);
      entry.reject(err);
    }
    this.pending.clear();
  }

  private writeJson(payload: unknown): void {
    if (!this.proc || !this.proc.stdin.writable || this.closed) {
      throw new Error("ACP stdin is not writable");
    }
    this.proc.stdin.write(`${JSON.stringify(payload)}\n`);
  }

  private handleLine(line: string): void {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }

    const hasId = Object.prototype.hasOwnProperty.call(msg, "id") && msg.id !== undefined;
    const hasMethod = typeof msg.method === "string";

    if (hasId && !hasMethod) {
      const resp = msg as unknown as JsonRpcResponse;
      const key = `${typeof resp.id}:${String(resp.id)}`;
      const entry = this.pending.get(key);
      if (!entry) return;
      this.pending.delete(key);
      clearTimeout(entry.timer);
      if (resp.error) {
        entry.reject(new Error(`ACP RPC ${resp.error.code}: ${resp.error.message}`));
      } else {
        entry.resolve(resp.result);
      }
      return;
    }

    if (hasId && hasMethod) {
      this.handleServerRequest(msg as unknown as JsonRpcRequest);
      return;
    }

    if (hasMethod) {
      this.callbacks.onNotification?.(msg as unknown as JsonRpcNotification);
    }
  }

  private handleServerRequest(req: JsonRpcRequest): void {
    // Preserve exact JSON-RPC id type (string for agy, integer for codebuddy)
    if (req.method === "session/request_permission") {
      const params = req.params || {};
      const options = Array.isArray(params.options)
        ? (params.options as Array<{ optionId?: string; kind?: string; name?: string }>)
        : [];
      const chosen = pickAutoApproveOption(options);
      if (chosen) {
        this.writeJson({
          jsonrpc: "2.0",
          id: req.id,
          result: {
            outcome: {
              outcome: "selected",
              optionId: chosen,
            },
          },
        });
      } else {
        this.writeJson({
          jsonrpc: "2.0",
          id: req.id,
          result: {
            outcome: {
              outcome: "cancelled",
            },
          },
        });
      }
      return;
    }

    this.writeJson({
      jsonrpc: "2.0",
      id: req.id,
      error: {
        code: -32601,
        message: `Relay client does not implement method: ${req.method}`,
      },
    });
  }

  request<T = unknown>(
    method: string,
    params: Record<string, unknown>,
    timeoutMs = 60_000
  ): Promise<T> {
    if (!this.isAlive) {
      return Promise.reject(new Error("ACP worker is not running"));
    }
    const id = this.nextId++;
    const key = `number:${id}`;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(key);
        reject(new Error(`ACP request timeout after ${timeoutMs}ms: ${method}`));
      }, timeoutMs);

      this.pending.set(key, {
        resolve: resolve as (v: unknown) => void,
        reject,
        timer,
      });

      try {
        this.writeJson({
          jsonrpc: "2.0",
          id,
          method,
          params,
        });
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(key);
        reject(err instanceof Error ? err : new Error(String(err)));
      }
    });
  }

  notify(method: string, params: Record<string, unknown>): void {
    if (!this.isAlive) return;
    this.writeJson({
      jsonrpc: "2.0",
      method,
      params,
    });
  }

  async initialize(): Promise<unknown> {
    return this.request(
      "initialize",
      {
        protocolVersion: 1,
        clientCapabilities: {},
        clientInfo: { name: "Relay", version: "1.0.0" },
      },
      20_000
    );
  }

  async newSession(
    cwd: string,
    options?: AcpSessionLaunchOptions
  ): Promise<Record<string, unknown>> {
    const params: Record<string, unknown> = {
      cwd,
      mcpServers: options?.mcpServers ?? [],
    };
    if (options?.meta && Object.keys(options.meta).length > 0) {
      params._meta = options.meta;
    }
    return this.request<Record<string, unknown>>("session/new", params, 30_000);
  }

  async loadSession(
    sessionId: string,
    cwd: string,
    options?: AcpSessionLaunchOptions
  ): Promise<Record<string, unknown>> {
    const params: Record<string, unknown> = {
      sessionId,
      cwd,
      mcpServers: options?.mcpServers ?? [],
    };
    if (options?.meta && Object.keys(options.meta).length > 0) {
      params._meta = options.meta;
    }
    return this.request<Record<string, unknown>>("session/load", params, 30_000);
  }

  async prompt(
    sessionId: string,
    promptBlocks: Array<Record<string, unknown>>
  ): Promise<Record<string, unknown>> {
    // Allow up to 30 minutes for complex agent turns
    return this.request<Record<string, unknown>>(
      "session/prompt",
      { sessionId, prompt: promptBlocks },
      30 * 60_000
    );
  }

  async setModel(sessionId: string, modelId: string): Promise<Record<string, unknown>> {
    return this.request<Record<string, unknown>>(
      "session/set_model",
      { sessionId, modelId },
      15_000
    );
  }

  async setMode(sessionId: string, modeId: string): Promise<Record<string, unknown>> {
    return this.request<Record<string, unknown>>(
      "session/set_mode",
      { sessionId, modeId },
      15_000
    );
  }

  async setConfigOption(
    sessionId: string,
    configId: string,
    value: ConfigValue
  ): Promise<Record<string, unknown>> {
    return this.request<Record<string, unknown>>(
      "session/set_config_option",
      { sessionId, configId, value },
      15_000
    );
  }

  cancel(sessionId: string): void {
    this.notify("session/cancel", { sessionId });
  }

  dispose(): Promise<void> {
    if (!this.proc || this.closed) {
      return Promise.resolve();
    }
    this.closed = true;
    const proc = this.proc;
    this.rejectAllPending(new Error("ACP worker disposed"));
    return new Promise<void>((resolve) => {
      if (proc.exitCode !== null) {
        resolve();
        return;
      }
      const done = () => {
        clearTimeout(forceTimer);
        resolve();
      };
      proc.once("exit", done);
      try {
        proc.stdin.end();
        proc.kill("SIGTERM");
      } catch {
        // ignore
      }
      const forceTimer = setTimeout(() => {
        try {
          if (proc.exitCode === null) proc.kill("SIGKILL");
        } catch {
          // ignore
        }
        resolve();
      }, 2000);
      forceTimer.unref();
    });
  }
}

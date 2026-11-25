import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, it } from "node:test";
import { SessionManager, type WsEventEnvelope } from "../src/acp/manager.js";
import type { AgentProfile, AppConfig } from "../src/config.js";
import { RelayDatabase } from "../src/db.js";

const mockSessionAgentScript = `
const fs = require("node:fs");
const readline = require("node:readline");

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const scenario = process.env.MOCK_SCENARIO || "replay";
const traceFile = process.env.MOCK_TRACE_FILE || "";

function trace(entry) {
  if (!traceFile) return;
  fs.appendFileSync(traceFile, JSON.stringify(entry) + "\\n");
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\\n");
}

rl.on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  trace({ method: msg.method, id: msg.id ?? null });

  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
    return;
  }

  if (msg.method === "session/new") {
    send({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        sessionId: "mock-sess-reload",
        models: { currentModelId: "m1", availableModels: [{ modelId: "m1", name: "Model 1" }] },
        modes: { currentModeId: "default", availableModes: [{ id: "default", name: "Default" }] },
        configOptions: [],
      },
    });
    return;
  }

  if (msg.method === "session/load") {
    const sid = msg.params?.sessionId || "mock-sess-reload";
    if (scenario === "cancel_during_load") {
      setTimeout(() => {
        send({
          jsonrpc: "2.0",
          method: "session/update",
          params: {
            sessionId: sid,
            update: {
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: "replayed before cancel" },
            },
          },
        });
        send({
          jsonrpc: "2.0",
          id: msg.id,
          result: {
            sessionId: sid,
            models: { currentModelId: "m1", availableModels: [{ modelId: "m1", name: "Model 1" }] },
            modes: { currentModeId: "default", availableModes: [{ id: "default", name: "Default" }] },
            configOptions: [],
          },
        });
      }, 120);
      return;
    }

    // Replay history during session/load before resolving session/load
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: sid,
        update: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "old thought" } },
      },
    });
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: sid,
        update: {
          sessionUpdate: "tool_call",
          toolCallId: "old-tool-1",
          name: "Bash",
          title: "old_tool",
          kind: "execute",
          status: "completed",
        },
      },
    });
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: sid,
        update: {
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "历史消息\`\`\`\\nTotal duration (API): 0s\\n\`\`\`" },
        },
      },
    });
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: sid,
        update: {
          sessionUpdate: "usage_update",
          used: 100,
          size: 1000,
          _meta: {
            "codebuddy.ai/requestId": "req-old-1",
            usage: { credit: 9.0, total_tokens: 500 },
          },
        },
      },
    });
    send({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        sessionId: sid,
        models: { currentModelId: "m1", availableModels: [{ modelId: "m1", name: "Model 1" }] },
        modes: { currentModeId: "default", availableModes: [{ id: "default", name: "Default" }] },
        configOptions: [],
      },
    });
    return;
  }

  if (msg.method === "session/prompt") {
    const sid = msg.params?.sessionId || "mock-sess-reload";
    if (scenario === "tool_spacing") {
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: sid,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "先查一下。" } },
        },
      });
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: sid,
          update: {
            sessionUpdate: "tool_call",
            toolCallId: "tool-web-1",
            name: "WebSearch",
            title: "WebSearch",
            kind: "fetch",
            status: "completed",
          },
        },
      });
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: sid,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "查到了。" } },
        },
      });
      send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
      return;
    }

    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: sid,
        update: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "new thought" } },
      },
    });
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: sid,
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "这是新回复" } },
      },
    });
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: sid,
        update: {
          sessionUpdate: "usage_update",
          used: 150,
          size: 1000,
          _meta: {
            "codebuddy.ai/requestId": "req-new-1",
            usage: { credit: 1.5, total_tokens: 120 },
          },
        },
      },
    });
    send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
    return;
  }
});
`;

function makeTestConfig(tmpDir: string): AppConfig {
  const dataDir = path.join(tmpDir, "data");
  const uploadsDir = path.join(dataDir, "uploads");
  const defaultCwd = path.join(tmpDir, "workspace");
  fs.mkdirSync(uploadsDir, { recursive: true });
  fs.mkdirSync(defaultCwd, { recursive: true });
  return {
    host: "127.0.0.1",
    port: 0,
    relayToken: "test-token",
    dataDir,
    uploadsDir,
    dbPath: path.join(dataDir, "relay.db"),
    agentsConfigPath: path.join(tmpDir, "agents.json"),
    defaultCwd,
    homeDir: tmpDir,
    stUrl: "http://127.0.0.1:8000",
    stPublicUrl: "https://st.example.com",
    tavernProfileDir: path.join(dataDir, "tavern-profile"),
    tavernAuthPath: path.join(dataDir, "tavern-auth.json"),
    tavernEnabled: false,
    stDataDir: null,
  };
}

function waitForEvent(
  manager: SessionManager,
  sessionId: string,
  predicate: (ev: WsEventEnvelope) => boolean,
  timeoutMs = 5000
): Promise<WsEventEnvelope> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      unsub();
      reject(new Error(`Timed out waiting for WS event on ${sessionId}`));
    }, timeoutMs);
    const unsub = manager.subscribe((ev) => {
      if (ev.sessionId === sessionId && predicate(ev)) {
        clearTimeout(timer);
        unsub();
        resolve(ev);
      }
    });
  });
}

describe("SessionManager ACP turn isolation & spacing", () => {
  let tmpDir: string | null = null;
  let manager: SessionManager | null = null;
  let db: RelayDatabase | null = null;

  afterEach(async () => {
    await manager?.disposeAll();
    manager = null;
    db?.close();
    db = null;
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true, maxRetries: 6, retryDelay: 80 });
      tmpDir = null;
    }
  });

  it("ignores session/load replay updates so old history never pollutes the new assistant turn", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-sm-replay-"));
    const scriptPath = path.join(tmpDir, "mock-agent.cjs");
    fs.writeFileSync(scriptPath, mockSessionAgentScript, "utf8");

    const config = makeTestConfig(tmpDir);
    db = new RelayDatabase(config.dbPath);
    const agent: AgentProfile = {
      id: "codebuddy",
      name: "CodeBuddy",
      subtitle: "Mock",
      icon: "terminal",
      accent: "#6C8CFF",
      command: process.execPath,
      args: [scriptPath],
      env: { MOCK_SCENARIO: "replay" },
    };
    manager = new SessionManager(config, db, [agent]);

    const session = await manager.createSession({ agentId: "codebuddy", cwd: config.defaultCwd });
    assert.equal(session.acpSessionId, "mock-sess-reload");

    await manager.disposeSessionWorker(session.id);

    const streamedDeltas: string[] = [];
    const unsub = manager.subscribe((ev) => {
      if (ev.sessionId === session.id && ev.type === "text_delta") {
        const delta = (ev.payload as { delta?: string })?.delta ?? "";
        streamedDeltas.push(delta);
      }
    });

    const completedPromise = waitForEvent(manager, session.id, (ev) => ev.type === "turn_completed");
    const { assistantMessage } = await manager.startPrompt(session.id, { text: "新问题" });
    await completedPromise;
    unsub();

    const stored = db.listMessages(session.id).find((m) => m.id === assistantMessage.id);
    assert.ok(stored, "stored assistant message should exist");
    assert.equal(stored.status, "completed");
    assert.equal(stored.content, "这是新回复");
    assert.equal(stored.thinking, "new thought");
    assert.equal(stored.toolCalls.length, 0);
    assert.equal(stored.usage?.credits, 1.5);
    assert.equal(streamedDeltas.join(""), "这是新回复");
  });

  it("inserts paragraph separator between text chunks separated by a tool call", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-sm-spacing-"));
    const scriptPath = path.join(tmpDir, "mock-agent.cjs");
    fs.writeFileSync(scriptPath, mockSessionAgentScript, "utf8");

    const config = makeTestConfig(tmpDir);
    db = new RelayDatabase(config.dbPath);
    const agent: AgentProfile = {
      id: "codebuddy",
      name: "CodeBuddy",
      subtitle: "Mock",
      icon: "terminal",
      accent: "#6C8CFF",
      command: process.execPath,
      args: [scriptPath],
      env: { MOCK_SCENARIO: "tool_spacing" },
    };
    manager = new SessionManager(config, db, [agent]);

    const session = await manager.createSession({ agentId: "codebuddy", cwd: config.defaultCwd });

    const streamedDeltas: string[] = [];
    const unsub = manager.subscribe((ev) => {
      if (ev.sessionId === session.id && ev.type === "text_delta") {
        const delta = (ev.payload as { delta?: string })?.delta ?? "";
        streamedDeltas.push(delta);
      }
    });

    const completedPromise = waitForEvent(manager, session.id, (ev) => ev.type === "turn_completed");
    const { assistantMessage } = await manager.startPrompt(session.id, { text: "查天气" });
    await completedPromise;
    unsub();

    const stored = db.listMessages(session.id).find((m) => m.id === assistantMessage.id);
    assert.ok(stored);
    assert.equal(stored.content, "先查一下。\n\n查到了。");
    assert.equal(streamedDeltas.join(""), "先查一下。\n\n查到了。");
  });

  it("cancels cleanly during ensureWorker/session/load without sending session/prompt", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-sm-cancel-"));
    const scriptPath = path.join(tmpDir, "mock-agent.cjs");
    const traceFile = path.join(tmpDir, "trace.jsonl");
    fs.writeFileSync(scriptPath, mockSessionAgentScript, "utf8");

    const config = makeTestConfig(tmpDir);
    db = new RelayDatabase(config.dbPath);
    const agent: AgentProfile = {
      id: "codebuddy",
      name: "CodeBuddy",
      subtitle: "Mock",
      icon: "terminal",
      accent: "#6C8CFF",
      command: process.execPath,
      args: [scriptPath],
      env: { MOCK_SCENARIO: "cancel_during_load", MOCK_TRACE_FILE: traceFile },
    };
    manager = new SessionManager(config, db, [agent]);

    const session = await manager.createSession({ agentId: "codebuddy", cwd: config.defaultCwd });
    await manager.disposeSessionWorker(session.id);

    const completedPromise = waitForEvent(manager, session.id, (ev) => ev.type === "turn_completed");
    const { assistantMessage } = await manager.startPrompt(session.id, { text: "取消我" });
    assert.equal(manager.cancelTurn(session.id), true);

    const doneEv = await completedPromise;
    assert.equal((doneEv.payload as { status?: string })?.status, "cancelled");

    const stored = db.listMessages(session.id).find((m) => m.id === assistantMessage.id);
    assert.ok(stored);
    assert.equal(stored.status, "cancelled");
    assert.equal(stored.content, "");

    const methods = fs
      .readFileSync(traceFile, "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => (JSON.parse(line) as { method?: string }).method);
    assert.ok(methods.includes("session/load"), "session/load should have been called");
    assert.equal(methods.includes("session/prompt"), false, "session/prompt should NOT be sent");
  });
});

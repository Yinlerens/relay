import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, it } from "node:test";
import { createRelayServer, type RelayServerInstance } from "../src/app.js";
import { SessionManager, type WsEventEnvelope } from "../src/acp/manager.js";
import type { AgentProfile, AppConfig } from "../src/config.js";
import { RelayDatabase } from "../src/db.js";
import { cleanupOrphanUploads } from "../src/utils/uploads-cleanup.js";

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
  trace({ method: msg.method, id: msg.id ?? null, modelId: msg.params?.modelId ?? null });

  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
    return;
  }

  if (msg.method === "session/set_model") {
    send({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        configOptions:
          scenario === "codebuddy_model_quirk"
            ? [
                {
                  id: "model",
                  name: "Model",
                  type: "select",
                  currentValue: msg.params?.modelId || "hy4std",
                  options: [
                    { value: "hy4std", name: "Hy4" },
                    { value: "hy4flash-free", name: "Hy4 flash" },
                  ],
                },
              ]
            : [],
      },
    });
    return;
  }

  if (msg.method === "session/new") {
    if (scenario === "codebuddy_model_quirk") {
      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          sessionId: "cb-acp-sess",
          models: {
            currentModelId: "hy4std",
            availableModels: [
              { modelId: "hy4std", name: "Hy4", description: "x0.29 credits" },
              { modelId: "hy4flash-free", name: "Hy4 flash", description: "x0.00 credits" },
            ],
          },
          modes: { currentModeId: "bypassPermissions", availableModes: [{ id: "bypassPermissions", name: "Bypass" }] },
          configOptions: [
            {
              id: "model",
              name: "Model",
              type: "select",
              currentValue: "hy4std",
              options: [
                { value: "hy4std", name: "Hy4" },
                { value: "hy4flash-free", name: "Hy4 flash" },
              ],
            },
          ],
        },
      });
      return;
    }
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
    if (scenario === "codebuddy_model_quirk") {
      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          sessionId: sid,
          models: {
            currentModelId: "hy4std",
            availableModels: [
              { modelId: "hy4std", name: "Hy4", description: "x0.29 credits" },
              { modelId: "hy4flash-free", name: "Hy4 flash", description: "x0.00 credits" },
            ],
          },
          modes: { currentModeId: "bypassPermissions", availableModes: [{ id: "bypassPermissions", name: "Bypass" }] },
          configOptions: [
            {
              id: "model",
              name: "Model",
              type: "select",
              currentValue: "hy4std",
              options: [
                { value: "hy4std", name: "Hy4" },
                { value: "hy4flash-free", name: "Hy4 flash" },
              ],
            },
          ],
        },
      });
      return;
    }
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

    if (scenario === "tool_details") {
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: sid,
          update: {
            sessionUpdate: "tool_call",
            toolCallId: "tool-bash-1",
            name: "Bash",
            title: "Run tests",
            kind: "execute",
            status: "in_progress",
            rawInput: { command: "npm test", cwd: "/opt/relay" },
            locations: [{ path: "/opt/relay/package.json", line: 11 }],
          },
        },
      });
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: sid,
          update: {
            sessionUpdate: "tool_call_update",
            toolCallId: "tool-bash-1",
            status: "completed",
            rawOutput: "\\u001b[32m18 passing\\u001b[0m",
          },
        },
      });
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: sid,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done." } },
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

  it("captures and merges tool_call inputPreview, outputPreview and locations across updates", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-sm-tooldetails-"));
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
      env: { MOCK_SCENARIO: "tool_details" },
    };
    manager = new SessionManager(config, db, [agent]);

    const session = await manager.createSession({ agentId: "codebuddy", cwd: config.defaultCwd });
    const toolEvents: WsEventEnvelope[] = [];
    const unsub = manager.subscribe((ev) => {
      if (ev.sessionId === session.id && ev.type === "tool_activity") {
        toolEvents.push(ev);
      }
    });

    const completedPromise = waitForEvent(manager, session.id, (ev) => ev.type === "turn_completed");
    const { assistantMessage } = await manager.startPrompt(session.id, { text: "run tests" });
    await completedPromise;
    unsub();

    assert.equal(toolEvents.length, 2);
    const stored = db.listMessages(session.id).find((m) => m.id === assistantMessage.id);
    assert.ok(stored);
    assert.equal(stored.toolCalls.length, 1);
    const tool = stored.toolCalls[0];
    assert.equal(tool.status, "completed");
    assert.match(tool.inputPreview ?? "", /npm test/);
    assert.equal(tool.outputPreview, "18 passing");
    assert.deepEqual(tool.locations, ["/opt/relay/package.json:11"]);
  });
});

describe("Session pinning & upload cleanup", () => {
  let tmpDir: string | null = null;
  let server: RelayServerInstance | null = null;
  let db: RelayDatabase | null = null;

  afterEach(async () => {
    await server?.close();
    server = null;
    db?.close();
    db = null;
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true, maxRetries: 6, retryDelay: 80 });
      tmpDir = null;
    }
  });

  it("pins/unpins sessions via PATCH without altering updatedAt and orders pinned first", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-pin-"));
    const config = makeTestConfig(tmpDir);
    server = await createRelayServer(config, []);

    server.db.createSession({
      id: "sess-older",
      agentId: "agy",
      acpSessionId: null,
      title: "Older",
      cwd: config.defaultCwd,
      currentModelId: null,
      currentModeId: null,
      availableModels: [],
      availableModes: [],
      configOptions: [],
      availableCommands: [],
      now: 1000,
    });
    server.db.createSession({
      id: "sess-newer",
      agentId: "agy",
      acpSessionId: null,
      title: "Newer",
      cwd: config.defaultCwd,
      currentModelId: null,
      currentModeId: null,
      availableModels: [],
      availableModes: [],
      configOptions: [],
      availableCommands: [],
      now: 2000,
    });

    const patchRes = await server.app.inject({
      method: "PATCH",
      url: "/api/sessions/sess-older",
      headers: { Authorization: `Bearer ${config.relayToken}` },
      payload: { pinned: true },
    });
    assert.equal(patchRes.statusCode, 200);
    const patched = patchRes.json() as { session: { pinned: boolean; updatedAt: number } };
    assert.equal(patched.session.pinned, true);
    assert.equal(patched.session.updatedAt, 1000);

    const ordered = server.db.listSessions().map((s) => s.id);
    assert.deepEqual(ordered, ["sess-older", "sess-newer"]);

    const unpinRes = await server.app.inject({
      method: "PATCH",
      url: "/api/sessions/sess-older",
      headers: { Authorization: `Bearer ${config.relayToken}` },
      payload: { pinned: false },
    });
    assert.equal(unpinRes.statusCode, 200);
    assert.deepEqual(
      server.db.listSessions().map((s) => s.id),
      ["sess-newer", "sess-older"]
    );
  });

  it("removes unreferenced session uploads on delete and purges aged orphans", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-uploads-"));
    const config = makeTestConfig(tmpDir);
    db = new RelayDatabase(config.dbPath);
    const manager = new SessionManager(config, db, []);

    for (const id of ["sess-a", "sess-b"]) {
      db.createSession({
        id,
        agentId: "agy",
        acpSessionId: null,
        title: id,
        cwd: config.defaultCwd,
        currentModelId: null,
        currentModeId: null,
        availableModels: [],
        availableModes: [],
        configOptions: [],
        availableCommands: [],
        now: 1000,
      });
    }

    const fileOnlyA = path.join(config.uploadsDir, "only-a.txt");
    const fileShared = path.join(config.uploadsDir, "shared.txt");
    const fileAgedOrphan = path.join(config.uploadsDir, "aged-orphan.txt");
    const fileFreshOrphan = path.join(config.uploadsDir, "fresh-orphan.txt");
    const fileStrayAged = path.join(config.uploadsDir, "stray-aged.bin");
    for (const f of [fileOnlyA, fileShared, fileAgedOrphan, fileFreshOrphan, fileStrayAged]) {
      fs.writeFileSync(f, "data");
    }
    const oldMs = Date.now() - 48 * 60 * 60 * 1000;
    const oldSec = oldMs / 1000;
    fs.utimesSync(fileStrayAged, oldSec, oldSec);

    db.createUpload({ id: "u-only-a", filename: "only-a.txt", mimeType: "text/plain", sizeBytes: 4, diskPath: fileOnlyA, createdAt: Date.now() });
    db.createUpload({ id: "u-shared", filename: "shared.txt", mimeType: "text/plain", sizeBytes: 4, diskPath: fileShared, createdAt: Date.now() });
    db.createUpload({ id: "u-aged-orphan", filename: "aged-orphan.txt", mimeType: "text/plain", sizeBytes: 4, diskPath: fileAgedOrphan, createdAt: oldMs });
    db.createUpload({ id: "u-fresh-orphan", filename: "fresh-orphan.txt", mimeType: "text/plain", sizeBytes: 4, diskPath: fileFreshOrphan, createdAt: Date.now() });

    db.createMessage({
      id: "m-a",
      sessionId: "sess-a",
      role: "user",
      content: "hi",
      thinking: "",
      attachments: [
        { id: "u-only-a", filename: "only-a.txt", mimeType: "text/plain", sizeBytes: 4, isImage: false },
        { id: "u-shared", filename: "shared.txt", mimeType: "text/plain", sizeBytes: 4, isImage: false },
      ],
      toolCalls: [],
      usage: null,
      status: "completed",
      createdAt: 1001,
    });
    db.createMessage({
      id: "m-b",
      sessionId: "sess-b",
      role: "user",
      content: "hi",
      thinking: "",
      attachments: [
        { id: "u-shared", filename: "shared.txt", mimeType: "text/plain", sizeBytes: 4, isImage: false },
      ],
      toolCalls: [],
      usage: null,
      status: "completed",
      createdAt: 1002,
    });

    assert.equal(manager.deleteSession("sess-a"), true);
    assert.equal(db.getUpload("u-only-a"), null);
    assert.equal(fs.existsSync(fileOnlyA), false);
    assert.ok(db.getUpload("u-shared"));
    assert.equal(fs.existsSync(fileShared), true);

    const stats = cleanupOrphanUploads(db, config.uploadsDir, 24 * 60 * 60 * 1000);
    assert.equal(stats.removedRecords, 1);
    assert.equal(stats.removedStrayFiles, 1);
    assert.equal(db.getUpload("u-aged-orphan"), null);
    assert.equal(fs.existsSync(fileAgedOrphan), false);
    assert.equal(fs.existsSync(fileStrayAged), false);
    assert.ok(db.getUpload("u-fresh-orphan"));
    assert.equal(fs.existsSync(fileFreshOrphan), true);
  });

  it("defaults codebuddy sessions to hy4flash-free and explicitly re-applies selected model after session/load", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-codebuddy-model-"));
    const config = makeTestConfig(tmpDir);
    const traceFile = path.join(tmpDir, "trace.jsonl");
    const scriptPath = path.join(tmpDir, "mock-cb.cjs");
    fs.writeFileSync(scriptPath, mockSessionAgentScript, "utf8");

    db = new RelayDatabase(config.dbPath);
    const agent: AgentProfile = {
      id: "codebuddy",
      name: "CodeBuddy",
      subtitle: "Mock",
      icon: "cpu",
      accent: "emerald",
      command: process.execPath,
      args: [scriptPath],
      env: {
        MOCK_SCENARIO: "codebuddy_model_quirk",
        MOCK_TRACE_FILE: traceFile,
      },
    };
    const manager = new SessionManager(config, db, [agent]);

    try {
      // 1) createSession defaults CodeBuddy to hy4flash-free despite ACP reporting hy4std
      const created = await manager.createSession({ agentId: "codebuddy", title: "Free default" });
      assert.equal(created.currentModelId, "hy4flash-free");
      assert.equal(created.configOptions.find((c) => c.id === "model")?.currentValue, "hy4flash-free");

      const firstTrace = fs
        .readFileSync(traceFile, "utf8")
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l) as { method: string; modelId: string | null });
      assert.ok(
        firstTrace.some((e) => e.method === "session/set_model" && e.modelId === "hy4flash-free"),
        "expected session/set_model(hy4flash-free) during createSession"
      );

      // 2) Switch to hy4std, dispose worker, then prompt -> session/load MUST force set_model(hy4std)
      const switched = await manager.updateSessionConfig(created.id, {
        kind: "model",
        value: "hy4std",
      });
      assert.equal(switched.currentModelId, "hy4std");
      assert.equal(switched.configOptions.find((c) => c.id === "model")?.currentValue, "hy4std");

      await manager.disposeSessionWorker(created.id);
      fs.writeFileSync(traceFile, "", "utf8");

      const donePromise = waitForEvent(
        manager,
        created.id,
        (ev) => ev.type === "turn_completed"
      );
      await manager.startPrompt(created.id, { text: "continue on hy4std" });
      await donePromise;

      const afterSession = db.getSession(created.id)!;
      assert.equal(afterSession.currentModelId, "hy4std");
      assert.equal(afterSession.configOptions.find((c) => c.id === "model")?.currentValue, "hy4std");

      const reloadTrace = fs
        .readFileSync(traceFile, "utf8")
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l) as { method: string; modelId: string | null });
      const loadIdx = reloadTrace.findIndex((e) => e.method === "session/load");
      const setIdx = reloadTrace.findIndex(
        (e) => e.method === "session/set_model" && e.modelId === "hy4std"
      );
      const promptIdx = reloadTrace.findIndex((e) => e.method === "session/prompt");
      assert.ok(loadIdx >= 0 && setIdx > loadIdx && promptIdx > setIdx, `unexpected trace: ${JSON.stringify(reloadTrace)}`);

      // 3) probeAgentModels returns hy4flash-free as defaultModelId even when a DB session switched to hy4std
      const probed = await manager.probeAgentModels("codebuddy");
      assert.equal(probed.defaultModelId, "hy4flash-free");
    } finally {
      await manager.disposeAll();
    }
  });
});

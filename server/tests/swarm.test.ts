import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, it } from "node:test";
import { createRelayServer, type RelayServerInstance } from "../src/app.js";
import type { AgentProfile, AppConfig } from "../src/config.js";
import { RelayDatabase } from "../src/db.js";
import { parseMentions } from "../src/swarm/manager.js";

/**
 * Mock ACP agent that records session/new params (mcpServers & _meta) to a trace file,
 * supports session/set_model, emits CodeBuddy-style usage_update credits, and can call
 * the Relay internal MCP endpoint directly during prompts.
 */
const mockSwarmAgentScript = `
const fs = require("node:fs");
const readline = require("node:readline");

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const traceFile = process.env.MOCK_TRACE_FILE || "";
const agentRoleHint = process.env.MOCK_AGENT_ID || "mock";

let sessionMcp = null;
let currentModel = agentRoleHint === "agy" ? "gemini-4-neon" : "deepseek-v4.1-flash";

function logTrace(entry) {
  if (!traceFile) return;
  fs.appendFileSync(traceFile, JSON.stringify({ agent: agentRoleHint, cwd: process.cwd(), ...entry }) + "\\n");
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\\n");
}

async function callMcp(method, params, isNotification = false) {
  if (!sessionMcp) throw new Error("No MCP server attached");
  const headers = { "Content-Type": "application/json" };
  for (const h of sessionMcp.headers || []) {
    headers[h.name] = h.value;
  }
  const payload = isNotification
    ? { jsonrpc: "2.0", method, ...(params ? { params } : {}) }
    : { jsonrpc: "2.0", id: Date.now() + Math.floor(Math.random() * 10000), method, ...(params ? { params } : {}) };
  const res = await fetch(sessionMcp.url, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : null };
}

rl.on("line", async (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);

  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
    return;
  }

  if (msg.method === "session/new") {
    const servers = Array.isArray(msg.params?.mcpServers) ? msg.params.mcpServers : [];
    sessionMcp = servers[0] || null;
    let handshake = null;
    if (sessionMcp) {
      const discover = await callMcp("server/discover");
      const init = await callMcp("initialize", { protocolVersion: "2025-03-26" });
      const notif = await callMcp("notifications/initialized", undefined, true);
      const list = await callMcp("tools/list");
      handshake = {
        discoverStatus: discover.status,
        discoverError: discover.json?.error || null,
        initStatus: init.status,
        initProtocol: init.json?.result?.protocolVersion || null,
        notifStatus: notif.status,
        toolsStatus: list.status,
        toolsError: list.json?.error || null,
        toolNames: (list.json?.result?.tools || []).map((t) => t.name).sort(),
      };
    }
    logTrace({
      event: "session/new",
      cwdParam: msg.params?.cwd,
      mcpServers: servers,
      meta: msg.params?._meta || null,
      handshake,
    });
    send({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        sessionId: "acp-" + Math.random().toString(36).slice(2, 8),
        models: {
          currentModelId: currentModel,
          availableModels:
            agentRoleHint === "agy"
              ? [
                  { modelId: "gemini-4-neon", name: "Gemini 4 Neon" },
                  { modelId: "claude-opus", name: "Claude Opus" },
                ]
              : [
                  { modelId: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", description: "x0.15 credits" },
                  { modelId: "hy4flash-free", name: "HY4 Flash Free", description: "x0.00 credits" },
                ],
        },
        modes: { currentModeId: "default", availableModes: [{ id: "default", name: "Default" }] },
        configOptions: [],
      },
    });
    return;
  }

  if (msg.method === "session/set_model") {
    currentModel = msg.params?.modelId || currentModel;
    logTrace({ event: "session/set_model", modelId: currentModel });
    send({ jsonrpc: "2.0", id: msg.id, result: {} });
    return;
  }

  if (msg.method === "session/prompt") {
    const promptText = (msg.params?.prompt || []).map((b) => b.text || "").join("\\n");
    logTrace({ event: "session/prompt", text: promptText, model: currentModel });

    // Emit credits usage update
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: msg.params.sessionId,
        update: {
          sessionUpdate: "usage_update",
          used: 1200,
          size: 128000,
          _meta: {
            "codebuddy.ai/messageId": "m-" + msg.id,
            usage: {
              prompt_tokens: 800,
              completion_tokens: 400,
              total_tokens: 1200,
              credit: agentRoleHint === "codebuddy" ? 0.25 : 0.1,
              original_credit: 0.5,
            },
          },
        },
      },
    });

    if (promptText.includes("ACTION:POST_DONE")) {
      // Simulate worker doing brief work and calling swarm_post via MCP
      await new Promise((r) => setTimeout(r, 120));
      const postRes = await callMcp("tools/call", {
        name: "swarm_post",
        arguments: { text: "@coordinator [done] finished worktree task cleanly" },
      });
      logTrace({ event: "mcp_swarm_post", result: postRes });
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: msg.params.sessionId,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Worker posted done via MCP." } },
        },
      });
      send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
      return;
    }

    if (promptText.includes("ACTION:FORGET_POST")) {
      // Simulate worker finishing WITHOUT calling swarm_post -> triggers backend fallback auto-bridge
      await new Promise((r) => setTimeout(r, 80));
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: msg.params.sessionId,
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "Fallback worker computed 42 without calling swarm_post" },
          },
        },
      });
      send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
      return;
    }

    if (promptText.includes("ACTION:SLEEP_THEN_IDLE")) {
      await new Promise((r) => setTimeout(r, 150));
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: msg.params.sessionId,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Quietly done." } },
        },
      });
      send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
      return;
    }

    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: msg.params.sessionId,
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Ack: " + promptText.slice(0, 60) } },
      },
    });
    send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
  }
});
`;

async function waitFor(fn: () => boolean | Promise<boolean>, timeoutMs = 8000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await fn()) return;
    await new Promise((r) => setTimeout(r, 40));
  }
  throw new Error(`waitFor timed out after ${timeoutMs}ms`);
}

describe("Relay Swarm Backend", () => {
  let tmpDir: string | null = null;
  let server: RelayServerInstance | null = null;

  afterEach(async () => {
    if (server) {
      await server.close();
      server = null;
    }
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true, maxRetries: 6, retryDelay: 80 });
      tmpDir = null;
    }
  });

  it("migrates legacy DB idempotently, recovers working members, and aggregates cross-member credits", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-swarm-db-"));
    const dbPath = path.join(tmpDir, "relay.db");

    // Seed legacy pre-swarm sessions table (without swarm_* columns)
    const rawDb = new DatabaseSync(dbPath);
    rawDb.exec(`
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        acp_session_id TEXT,
        title TEXT NOT NULL,
        cwd TEXT NOT NULL,
        current_model_id TEXT,
        current_mode_id TEXT,
        available_models_json TEXT NOT NULL DEFAULT '[]',
        available_modes_json TEXT NOT NULL DEFAULT '[]',
        config_options_json TEXT NOT NULL DEFAULT '[]',
        available_commands_json TEXT NOT NULL DEFAULT '[]',
        context_used INTEGER NOT NULL DEFAULT 0,
        context_size INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      INSERT INTO sessions (id, agent_id, title, cwd, current_model_id, available_models_json, created_at, updated_at)
      VALUES ('legacy-1', 'codebuddy', 'Old chat', '/tmp', 'deepseek-v4.1-flash', '[{"modelId":"deepseek-v4.1-flash","name":"DeepSeek"}]', 1000, 2000);
    `);
    rawDb.close();

    const db = new RelayDatabase(dbPath);
    try {
      const legacy = db.getSession("legacy-1");
      assert.ok(legacy);
      assert.equal(legacy.swarmId, null);
      assert.equal(legacy.swarmRole, null);
      assert.equal(legacy.swarmMemberName, null);
      assert.equal(legacy.worktreeBranch, null);

      const latestModels = db.getLatestAgentModels("codebuddy");
      assert.ok(latestModels);
      assert.equal(latestModels.defaultModelId, "deepseek-v4.1-flash");
      assert.equal(latestModels.models.length, 1);

      const now = Date.now();
      db.createSession({
        id: "coord-s",
        agentId: "agy",
        acpSessionId: "acp-c",
        title: "Swarm A",
        cwd: tmpDir,
        currentModelId: "gemini-4-neon",
        currentModeId: null,
        availableModels: [],
        availableModes: [],
        configOptions: [],
        availableCommands: [],
        swarmId: "swarm-1",
        swarmRole: "coordinator",
        swarmMemberName: "coordinator",
        now,
      });
      db.createSession({
        id: "worker-s1",
        agentId: "codebuddy",
        acpSessionId: "acp-w1",
        title: "@backend",
        cwd: tmpDir,
        currentModelId: "deepseek-v4.1-flash",
        currentModeId: null,
        availableModels: [],
        availableModes: [],
        configOptions: [],
        availableCommands: [],
        swarmId: "swarm-1",
        swarmRole: "worker",
        swarmMemberName: "backend",
        worktreeBranch: "relay-swarm/swarm1/backend",
        now,
      });

      db.createSwarm({
        id: "swarm-1",
        title: "Swarm A",
        cwd: tmpDir,
        coordinatorSessionId: "coord-s",
        coordinatorAgentId: "agy",
        defaultWorkerAgentId: "codebuddy",
        defaultWorkerModelId: "deepseek-v4.1-flash",
        now,
      });
      db.addSwarmMember({
        swarmId: "swarm-1",
        name: "coordinator",
        role: "coordinator",
        sessionId: "coord-s",
        agentId: "agy",
        modelId: "gemini-4-neon",
        state: "working",
        now,
      });
      db.addSwarmMember({
        swarmId: "swarm-1",
        name: "backend",
        role: "worker",
        sessionId: "worker-s1",
        agentId: "codebuddy",
        modelId: "deepseek-v4.1-flash",
        state: "working",
        workspaceMode: "worktree",
        worktreeBranch: "relay-swarm/swarm1/backend",
        now,
      });

      db.createMessage({
        id: "m1",
        sessionId: "coord-s",
        role: "assistant",
        content: "ok",
        thinking: "",
        attachments: [],
        toolCalls: [],
        usage: { credits: 0.125 },
        status: "completed",
        createdAt: now + 1,
      });
      db.createMessage({
        id: "m2",
        sessionId: "worker-s1",
        role: "assistant",
        content: "done",
        thinking: "",
        attachments: [],
        toolCalls: [],
        usage: { credits: 0.3755 },
        status: "completed",
        createdAt: now + 2,
      });

      db.appendSwarmMessage({
        swarmId: "swarm-1",
        sender: "coordinator",
        mentions: ["backend"],
        text: "@backend build api",
        kind: "brief",
      });

      const summary = db.getSwarmSummary("swarm-1", new Set(["worker-s1"]));
      assert.ok(summary);
      assert.equal(summary.totalCredits, 0.5005);
      assert.equal(summary.headSeq, 1);
      assert.equal(summary.activeWorkerCount, 1);
      assert.equal(summary.members.length, 2);
      assert.equal(summary.members[0].role, "coordinator");
      assert.equal(summary.members[1].isRunning, true);
      assert.equal(summary.members[1].totalCredits, 0.3755);
    } finally {
      db.close();
    }

    // Re-open DB to verify startup recovery resets working -> waiting
    const db2 = new RelayDatabase(dbPath);
    try {
      const recovered = db2.getSwarmSummary("swarm-1");
      assert.ok(recovered);
      assert.equal(recovered.members[0].state, "waiting");
      assert.equal(recovered.members[1].state, "waiting");
      assert.equal(recovered.activeWorkerCount, 0);
    } finally {
      db2.close();
    }

    // Also verify mention parser
    assert.deepEqual(
      parseMentions("@backend @all check email foo@bar.com and @coordinator @backend"),
      ["backend", "all", "coordinator"]
    );
  });

  it("enforces /internal/mcp/* isolation, MCP protocol, worktree lifecycle, swarm_wait, fallback bridge, and cascade delete", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-swarm-e2e-"));
    const dataDir = path.join(tmpDir, "data");
    const uploadsDir = path.join(dataDir, "uploads");
    const gitRepoDir = path.join(tmpDir, "repo");
    const nonGitDir = path.join(tmpDir, "plain-dir");
    const traceFile = path.join(tmpDir, "acp-trace.jsonl");
    const mockScriptPath = path.join(tmpDir, "mock-swarm-acp.cjs");

    fs.mkdirSync(uploadsDir, { recursive: true });
    fs.mkdirSync(gitRepoDir, { recursive: true });
    fs.mkdirSync(nonGitDir, { recursive: true });
    fs.writeFileSync(mockScriptPath, mockSwarmAgentScript, "utf8");

    // Initialize a real git repo for worktree testing
    execFileSync("git", ["init"], { cwd: gitRepoDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@relay.local"], { cwd: gitRepoDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Relay Test"], { cwd: gitRepoDir, stdio: "ignore" });
    fs.writeFileSync(path.join(gitRepoDir, "README.md"), "# test repo\n", "utf8");
    execFileSync("git", ["add", "README.md"], { cwd: gitRepoDir, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "init"], { cwd: gitRepoDir, stdio: "ignore" });

    const token = "test-bearer-token-123456";
    const config: AppConfig = {
      host: "127.0.0.1",
      port: 0,
      relayToken: token,
      dataDir,
      uploadsDir,
      dbPath: path.join(dataDir, "relay.db"),
      agentsConfigPath: path.join(tmpDir, "agents.json"),
      defaultCwd: gitRepoDir,
      homeDir: tmpDir,
      stUrl: "http://127.0.0.1:8000",
      stPublicUrl: "https://st.apps.makima.sbs",
      tavernProfileDir: path.join(dataDir, "tavern-profile"),
      tavernAuthPath: path.join(dataDir, "tavern-auth.enc.json"),
      tavernEnabled: false,
    };

    const agents: AgentProfile[] = [
      {
        id: "agy",
        name: "Antigravity",
        subtitle: "Mock Coord",
        icon: "sparkles",
        accent: "indigo",
        command: process.execPath,
        args: [mockScriptPath],
        env: { MOCK_TRACE_FILE: traceFile, MOCK_AGENT_ID: "agy" },
      },
      {
        id: "codebuddy",
        name: "CodeBuddy",
        subtitle: "Mock Worker",
        icon: "cpu",
        accent: "emerald",
        command: process.execPath,
        args: [mockScriptPath],
        env: { MOCK_TRACE_FILE: traceFile, MOCK_AGENT_ID: "codebuddy" },
      },
    ];

    server = await createRelayServer(config, agents);
    const { baseUrl } = await server.listen();

    const wsEvents: Array<{ type: string; sessionId: string; payload: unknown }> = [];
    server.manager.subscribe((ev) => wsEvents.push(ev));

    const api = async (p: string, init: RequestInit = {}) => {
      const headers = new Headers(init.headers);
      if (!headers.has("Authorization")) {
        headers.set("Authorization", `Bearer ${token}`);
      }
      const res = await fetch(`${baseUrl}${p}`, { ...init, headers });
      const text = await res.text();
      let json: unknown = null;
      try {
        json = JSON.parse(text);
      } catch {}
      return { status: res.status, json: json as Record<string, any>, text };
    };

    // 1. Agent models probing & 404 for unknown agent
    const modelsRes = await api("/api/agents/codebuddy/models");
    assert.equal(modelsRes.status, 200);
    assert.equal(modelsRes.json.agentId, "codebuddy");
    assert.equal(modelsRes.json.defaultModelId, "hy4flash-free");
    assert.equal(modelsRes.json.models.length, 2);

    const unknownAgentRes = await api("/api/agents/does-not-exist/models");
    assert.equal(unknownAgentRes.status, 404);

    // 2. Create swarm (defaults: agy coordinator, codebuddy worker)
    const createRes = await api("/api/swarms", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: "E2E Swarm",
        cwd: gitRepoDir,
        defaultWorkerModelId: "hy4flash-free",
      }),
    });
    assert.equal(createRes.status, 201, createRes.text);
    const swarm = createRes.json.swarm;
    const coordSession = createRes.json.session;
    assert.equal(coordSession.swarmId, swarm.id);
    assert.equal(coordSession.swarmRole, "coordinator");
    assert.equal(coordSession.swarmMemberName, "coordinator");
    assert.equal(swarm.defaultWorkerAgentId, "codebuddy");
    assert.equal(swarm.defaultWorkerModelId, "hy4flash-free");
    assert.ok(wsEvents.some((e) => e.type === "swarm_created" && e.sessionId === coordSession.id));

    // Confirm agy received _meta.antigravity.systemPrompt.append, mcpServers, AND completed live MCP handshake inside session/new
    const tracesAfterCreate = fs
      .readFileSync(traceFile, "utf8")
      .trim()
      .split(/\r?\n/)
      .map((l) => JSON.parse(l));
    const coordNewTrace = tracesAfterCreate.find(
      (t) => t.agent === "agy" && t.event === "session/new"
    );
    assert.ok(coordNewTrace, "Coordinator session/new trace missing");
    assert.equal(coordNewTrace.mcpServers.length, 1);
    assert.ok(
      String(coordNewTrace.meta?.antigravity?.systemPrompt?.append || "").includes("Relay 蜂群总控规约")
    );
    assert.equal(coordNewTrace.handshake.discoverStatus, 200);
    assert.equal(coordNewTrace.handshake.discoverError, null);
    assert.equal(coordNewTrace.handshake.initProtocol, "2025-03-26");
    assert.equal(coordNewTrace.handshake.notifStatus, 202);
    assert.equal(coordNewTrace.handshake.toolsError, null);
    assert.deepEqual(coordNewTrace.handshake.toolNames, [
      "swarm_add",
      "swarm_kill",
      "swarm_models",
      "swarm_post",
      "swarm_read_board",
      "swarm_status",
      "swarm_wait",
    ]);

    // Verify GET /api/bootstrap includes swarms
    const bootRes = await api("/api/bootstrap");
    assert.equal(bootRes.status, 200);
    assert.ok(Array.isArray(bootRes.json.swarms));
    assert.equal(bootRes.json.swarms.length, 1);

    // 3. /internal/mcp/* security isolation checks
    const mcpUrl = `${baseUrl}/internal/mcp/swarms/${swarm.id}/members/coordinator`;
    const noTokenRes = await fetch(mcpUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
    });
    assert.equal(noTokenRes.status, 403);

    const xffRes = await fetch(mcpUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-relay-internal-token": server.internalMcpToken,
        "x-forwarded-for": "203.0.113.5",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
    });
    assert.equal(xffRes.status, 403);

    const xRealIpRes = await fetch(mcpUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-relay-internal-token": server.internalMcpToken,
        "x-real-ip": "203.0.113.5",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
    });
    assert.equal(xRealIpRes.status, 403);

    // Valid internal token: GET -> 405, DELETE -> 204, notification -> 202
    const mcpGetRes = await fetch(mcpUrl, {
      method: "GET",
      headers: { "x-relay-internal-token": server.internalMcpToken },
    });
    assert.equal(mcpGetRes.status, 405);

    const mcpDelRes = await fetch(mcpUrl, {
      method: "DELETE",
      headers: { "x-relay-internal-token": server.internalMcpToken },
    });
    assert.equal(mcpDelRes.status, 204);

    const mcpCall = async (memberName: string, body: Record<string, unknown>) => {
      const res = await fetch(
        `${baseUrl}/internal/mcp/swarms/${swarm.id}/members/${memberName}`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-relay-internal-token": server!.internalMcpToken,
          },
          body: JSON.stringify(body),
        }
      );
      const text = await res.text();
      return { status: res.status, json: text ? JSON.parse(text) : null };
    };

    const notifRes = await mcpCall("coordinator", {
      jsonrpc: "2.0",
      method: "notifications/initialized",
    });
    assert.equal(notifRes.status, 202);

    const discoverRes = await mcpCall("coordinator", {
      jsonrpc: "2.0",
      id: "d1",
      method: "server/discover",
    });
    assert.deepEqual(discoverRes.json, { jsonrpc: "2.0", id: "d1", result: {} });

    const initMcpRes = await mcpCall("coordinator", {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-03-26" },
    });
    assert.equal(initMcpRes.json.result.protocolVersion, "2025-03-26");
    assert.ok(initMcpRes.json.result.capabilities.tools);

    const coordToolsRes = await mcpCall("coordinator", {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/list",
    });
    const coordToolNames = coordToolsRes.json.result.tools.map((t: any) => t.name).sort();
    assert.deepEqual(coordToolNames, [
      "swarm_add",
      "swarm_kill",
      "swarm_models",
      "swarm_post",
      "swarm_read_board",
      "swarm_status",
      "swarm_wait",
    ]);

    // 4. Coordinator adds worker-a in real Git worktree via MCP tools/call, then blocks on swarm_wait
    const addWorktreeRes = await mcpCall("coordinator", {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: {
        name: "swarm_add",
        arguments: {
          name: "worker-a",
          brief: "ACTION:POST_DONE implement feature in isolated branch",
          workspace: "worktree",
        },
      },
    });
    assert.equal(addWorktreeRes.json.result.isError, false);
    const addedPayload = JSON.parse(addWorktreeRes.json.result.content[0].text);
    assert.equal(addedPayload.member.workspaceMode, "worktree");
    assert.ok(addedPayload.member.worktreePath);
    assert.ok(fs.existsSync(addedPayload.member.worktreePath));
    assert.match(addedPayload.member.worktreeBranch, /^relay-swarm\/[a-z0-9]{8}\/worker-a$/);
    assert.equal(addedPayload.member.modelId, "hy4flash-free");
    assert.equal(addedPayload.member.lastReadSeq, addedPayload.boardSeq);

    // Verify worker-a ALSO completed live MCP handshake (3 tools, zero -32004) inside session/new BEFORE DB insert
    const tracesAfterAdd = fs
      .readFileSync(traceFile, "utf8")
      .trim()
      .split(/\r?\n/)
      .map((l) => JSON.parse(l));
    const workerNewTrace = tracesAfterAdd.find(
      (t) => t.agent === "codebuddy" && t.event === "session/new" && t.handshake
    );
    assert.ok(workerNewTrace, "Worker session/new live handshake trace missing");
    assert.equal(workerNewTrace.handshake.discoverStatus, 200);
    assert.equal(workerNewTrace.handshake.notifStatus, 202);
    assert.equal(workerNewTrace.handshake.toolsError, null);
    assert.deepEqual(workerNewTrace.handshake.toolNames, [
      "swarm_post",
      "swarm_read_board",
      "swarm_status",
    ]);

    // Verify worker tools/list has exactly 3 tools and denies swarm_add
    const workerToolsRes = await mcpCall("worker-a", {
      jsonrpc: "2.0",
      id: 4,
      method: "tools/list",
    });
    assert.deepEqual(
      workerToolsRes.json.result.tools.map((t: any) => t.name).sort(),
      ["swarm_post", "swarm_read_board", "swarm_status"]
    );
    const forbiddenToolRes = await mcpCall("worker-a", {
      jsonrpc: "2.0",
      id: 5,
      method: "tools/call",
      params: { name: "swarm_add", arguments: { name: "evil", brief: "nope" } },
    });
    assert.equal(forbiddenToolRes.json.result.isError, true);

    // Block coordinator on swarm_wait right after boardSeq -> wakes immediately when worker-a posts [done]
    const waitRes = await mcpCall("coordinator", {
      jsonrpc: "2.0",
      id: 6,
      method: "tools/call",
      params: {
        name: "swarm_wait",
        arguments: { since: addedPayload.boardSeq, mentionsOnly: true, timeoutSeconds: 10 },
      },
    });
    assert.equal(waitRes.json.result.isError, false);
    const waitPayload = JSON.parse(waitRes.json.result.content[0].text);
    assert.equal(waitPayload.reason, "message");
    assert.ok(
      waitPayload.messages.some(
        (m: any) => m.sender === "worker-a" && m.kind === "done" && m.text.includes("finished worktree task")
      )
    );

    // Wait for worker-a turn to finish persisting credits
    await waitFor(async () => {
      const d = await api(`/api/swarms/${swarm.id}`);
      const w = d.json.swarm.members.find((m: any) => m.name === "worker-a");
      return w && w.state === "done" && w.totalCredits > 0;
    });

    // 5. Fallback auto-bridge when worker finishes WITHOUT calling swarm_post
    const addFallbackRes = await api(`/api/swarms/${swarm.id}/workers`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "worker-b",
        brief: "ACTION:FORGET_POST calculate answer",
        workspace: "inherit",
      }),
    });
    assert.equal(addFallbackRes.status, 201);

    await waitFor(async () => {
      const d = await api(`/api/swarms/${swarm.id}`);
      return d.json.messages.some(
        (m: any) =>
          m.sender === "worker-b" &&
          m.kind === "done" &&
          m.text.includes("Fallback worker computed 42")
      );
    });

    // Coordinator should also have been auto-woken by worker-b's fallback bridge
    await waitFor(() => server!.db.listMessages(coordSession.id).length >= 2);

    // 6. User posting to board triggers @mention wakeup
    const userPostRes = await api(`/api/swarms/${swarm.id}/board`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: "@worker-a please confirm status" }),
    });
    assert.equal(userPostRes.status, 201);
    assert.equal(userPostRes.json.message.sender, "user");
    assert.ok(userPostRes.json.woke.includes("worker-a"));

    // Wait briefly for worker-a's woken turn to complete
    await waitFor(() => !server!.manager.isSessionRunning(addedPayload.member.sessionId));

    // 7. PATCH session title on coordinator syncs swarms.title + emits swarm_updated & session_updated
    const wsLenBeforeRename = wsEvents.length;
    const renameSessRes = await api(`/api/sessions/${coordSession.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Synced Swarm Title" }),
    });
    assert.equal(renameSessRes.status, 200);
    assert.equal(renameSessRes.json.session.title, "Synced Swarm Title");
    const swarmAfterSessRename = await api(`/api/swarms/${swarm.id}`);
    assert.equal(swarmAfterSessRename.json.swarm.title, "Synced Swarm Title");
    const renameEvents = wsEvents.slice(wsLenBeforeRename);
    assert.ok(renameEvents.some((e) => e.type === "swarm_updated"));
    assert.ok(renameEvents.some((e) => e.type === "session_updated"));

    // PATCH swarm + kill worker-a (verifying worktree directory is removed & killed tools/list returns -32004!)
    const patchRes = await api(`/api/swarms/${swarm.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Renamed Swarm", status: "completed" }),
    });
    assert.equal(patchRes.status, 200);
    assert.equal(patchRes.json.swarm.title, "Renamed Swarm");
    assert.equal(patchRes.json.swarm.status, "completed");

    const killRes = await api(`/api/swarms/${swarm.id}/workers/worker-a/kill`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ removeWorktree: true }),
    });
    assert.equal(killRes.status, 200);
    assert.equal(killRes.json.ok, true);
    assert.equal(
      killRes.json.swarm.members.find((m: any) => m.name === "worker-a").state,
      "killed"
    );
    assert.equal(fs.existsSync(addedPayload.member.worktreePath), false);

    const killedToolsRes = await mcpCall("worker-a", {
      jsonrpc: "2.0",
      id: 99,
      method: "tools/list",
    });
    assert.equal(killedToolsRes.json.error?.code, -32004);

    // 8. Non-git workspace gracefully downgrades worktree -> inherit with workspaceNote
    const plainSwarmRes = await api("/api/swarms", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Non-Git Swarm", cwd: nonGitDir }),
    });
    assert.equal(plainSwarmRes.status, 201);
    const plainSwarmId = plainSwarmRes.json.swarm.id;
    const plainWorkerRes = await api(`/api/swarms/${plainSwarmId}/workers`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "reader",
        brief: "ACTION:SLEEP_THEN_IDLE inspect folder",
        workspace: "worktree",
      }),
    });
    assert.equal(plainWorkerRes.status, 201);
    assert.equal(plainWorkerRes.json.member.workspaceMode, "inherit");
    assert.ok(plainWorkerRes.json.workspaceNote);

    const delPlainRes = await api(`/api/swarms/${plainSwarmId}`, { method: "DELETE" });
    assert.equal(delPlainRes.status, 200);
    assert.equal(delPlainRes.json.ok, true);
    assert.ok(wsEvents.some((e) => e.type === "swarm_deleted"));

    // 9. Deleting coordinator session cascades deletion of swarm + workers
    const delCoordRes = await api(`/api/sessions/${coordSession.id}`, { method: "DELETE" });
    assert.equal(delCoordRes.status, 200);
    await waitFor(async () => {
      const check = await api(`/api/swarms/${swarm.id}`);
      return check.status === 404;
    });
    assert.equal(server.db.getSession(addedPayload.member.sessionId), null);
  });
});

import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, it } from "node:test";
import { createRelayServer, type RelayServerInstance } from "../src/app.js";
import type { AppConfig } from "../src/config.js";
import { TavernAuthStore } from "../src/tavern/auth-store.js";
import {
  buildFallbackMarkdownMessage,
  buildTavernAvatarUrl,
  finalizeExtractedMessages,
  rewriteHtmlAssetUrls,
  sanitizeStAssetPath,
} from "../src/tavern/dom-extractor.js";
import type {
  TavernBridgeLike,
  TavernCharacter,
  TavernChatFile,
  TavernChatState,
  TavernMessage,
  TavernStatus,
  TavernSwipeDirection,
} from "../src/tavern/types.js";

function createMockTavernBridge(): TavernBridgeLike & {
  calls: string[];
  state: TavernChatState;
} {
  const calls: string[] = [];
  const character: TavernCharacter = {
    id: 0,
    name: "Seraphina",
    avatar: "Seraphina.png",
    avatarUrl: buildTavernAvatarUrl("Seraphina.png"),
    chat: "Seraphina - 2026-11-25.jsonl",
    lastChatAt: 1795576000000,
    tags: ["Fantasy", "RP"],
    tagline: "A quiet archivist of starlight.",
  };

  const status: TavernStatus = {
    enabled: true,
    ready: true,
    needsLogin: false,
    handle: "demo-user",
    publicUrl: "https://st.apps.makima.sbs",
    currentCharacterId: 0,
    currentCharacterName: character.name,
    currentChatFile: character.chat,
    isGenerating: false,
    lastError: null,
  };

  const makeMessage = (mesId: number, text: string, isUser: boolean, swipeId = 0, swipeCount = 1): TavernMessage =>
    buildFallbackMarkdownMessage({
      mesId,
      name: isUser ? "You" : character.name,
      avatarUrl: isUser ? null : character.avatarUrl,
      isUser,
      isSystem: false,
      sendDate: "2026-11-25 14:30",
      rawText: text,
      swipeId,
      swipeCount,
    });

  const state: TavernChatState = {
    status,
    character,
    chatFile: character.chat,
    userName: "You",
    messages: [
      makeMessage(0, "Welcome back to the observatory.", false, 0, 2),
      makeMessage(1, "Good evening, Seraphina.", true, 0, 1),
      makeMessage(2, "<think>Checking star chart</think>The constellations shifted tonight.", false, 0, 2),
    ],
    variables: { stat_data: { mood: "calm", hp: 100 } },
  };

  const chats: TavernChatFile[] = [
    {
      fileName: "Seraphina - 2026-11-25.jsonl",
      displayName: "Seraphina - 2026-11-25",
      lastMessage: "The constellations shifted tonight.",
      messageCount: 3,
      updatedAt: 1795576000000,
      isCurrent: true,
    },
  ];

  return {
    calls,
    state,
    async getStatus() {
      calls.push("getStatus");
      return { status: state.status };
    },
    async login(handle: string, _password: string) {
      calls.push(`login:${handle}`);
      state.status.handle = handle;
      state.status.needsLogin = false;
      state.status.ready = true;
      return { status: state.status };
    },
    async reload() {
      calls.push("reload");
      return { status: state.status, characters: [character] };
    },
    async listCharacters() {
      calls.push("listCharacters");
      return { status: state.status, characters: [character] };
    },
    async listCharacterChats(characterId: number) {
      calls.push(`listCharacterChats:${characterId}`);
      return { characterId, chats };
    },
    async selectCharacter(input) {
      calls.push(`select:${input.characterId}:${input.chatFile || ""}:${Boolean(input.createNew)}`);
      state.status.currentCharacterId = input.characterId;
      state.chatFile = input.createNew ? "new-chat.jsonl" : input.chatFile || character.chat;
      state.status.currentChatFile = state.chatFile;
      return { state };
    },
    async getCurrentState() {
      calls.push("getCurrentState");
      return { state };
    },
    async sendMessage(text: string) {
      calls.push(`send:${text}`);
      const nextId = state.messages.length;
      state.messages.push(makeMessage(nextId, text, true));
      return { ok: true, state };
    },
    async stopGeneration() {
      calls.push("stop");
      state.status.isGenerating = false;
      return { stopped: true };
    },
    async regenerate() {
      calls.push("regenerate");
      return { ok: true };
    },
    async continueGeneration() {
      calls.push("continue");
      return { ok: true };
    },
    async swipe(mesId: number, direction: TavernSwipeDirection) {
      calls.push(`swipe:${mesId}:${direction}`);
      const idx = state.messages.findIndex((m) => m.mesId === mesId);
      if (idx === -1) return { message: null, state };
      const cur = state.messages[idx];
      const nextSwipeId =
        direction === "left"
          ? Math.max(0, cur.swipeId - 1)
          : direction === "new"
            ? cur.swipeCount
            : cur.swipeId + 1;
      const nextCount = Math.max(cur.swipeCount, nextSwipeId + 1);
      const updated = makeMessage(mesId, `Swiped (${direction}) variant #${nextSwipeId}`, cur.isUser, nextSwipeId, nextCount);
      state.messages[idx] = updated;
      return { message: updated, state };
    },
    async editMessage(mesId: number, text: string) {
      calls.push(`edit:${mesId}`);
      const idx = state.messages.findIndex((m) => m.mesId === mesId);
      if (idx === -1) return { message: null, state };
      const cur = state.messages[idx];
      const updated = makeMessage(mesId, text, cur.isUser, cur.swipeId, cur.swipeCount);
      state.messages[idx] = updated;
      return { message: updated, state };
    },
    async deleteMessage(mesId: number) {
      calls.push(`delete:${mesId}`);
      state.messages = state.messages
        .filter((m) => m.mesId !== mesId)
        .map((m, i) => ({ ...m, mesId: i }));
      return { ok: true, state };
    },
    async runSlash(command: string) {
      calls.push(`slash:${command}`);
      return { ok: true, result: `executed:${command}`, state };
    },
    async getAssetCookieHeader() {
      return "session-cookie=st_demo_cookie_value";
    },
    async dispose() {
      calls.push("dispose");
    },
  };
}

describe("Tavern Bridge Utilities & Routes", () => {
  let tmpDir: string | null = null;
  let server: RelayServerInstance | null = null;
  let fakeStServer: http.Server | null = null;

  afterEach(async () => {
    if (server) {
      await server.close();
      server = null;
    }
    if (fakeStServer) {
      await new Promise<void>((resolve) => fakeStServer!.close(() => resolve()));
      fakeStServer = null;
    }
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
      tmpDir = null;
    }
  });

  it("sanitizes SillyTavern asset paths strictly and rewrites HTML/CSS relative URLs", () => {
    // Allowed paths
    assert.equal(
      sanitizeStAssetPath("/thumbnail?type=avatar&file=Seraphina.png"),
      "/thumbnail?type=avatar&file=Seraphina.png"
    );
    assert.equal(sanitizeStAssetPath("/characters/Seraphina.png"), "/characters/Seraphina.png");
    assert.equal(sanitizeStAssetPath("/user/images/card.webp"), "/user/images/card.webp");
    assert.equal(sanitizeStAssetPath("/backgrounds/night.jpg"), "/backgrounds/night.jpg");
    assert.equal(sanitizeStAssetPath("/assets/ui/frame.svg"), "/assets/ui/frame.svg");
    assert.equal(sanitizeStAssetPath("/img/icon.png"), "/img/icon.png");
    assert.equal(sanitizeStAssetPath("/User Avatars/me.png"), "/User Avatars/me.png");
    assert.equal(sanitizeStAssetPath("/User%20Avatars/me.png"), "/User%20Avatars/me.png");
    assert.equal(
      sanitizeStAssetPath("/default-expressions/smile.png"),
      "/default-expressions/smile.png"
    );
    assert.equal(sanitizeStAssetPath("/uploads/photo.png"), "/uploads/photo.png");
    assert.equal(sanitizeStAssetPath("/api/images/123.png"), "/api/images/123.png");
    assert.equal(sanitizeStAssetPath("/scripts/ext.js"), "/scripts/ext.js");
    assert.equal(sanitizeStAssetPath("/css/theme.css"), "/css/theme.css");

    // Disallowed / dangerous paths
    assert.equal(sanitizeStAssetPath("/api/secrets"), null);
    assert.equal(sanitizeStAssetPath("/api/secrets/read"), null);
    assert.equal(sanitizeStAssetPath("/api/settings/get"), null);
    assert.equal(sanitizeStAssetPath("/api/users/list"), null);
    assert.equal(sanitizeStAssetPath("/characters/../api/secrets"), null);
    assert.equal(sanitizeStAssetPath("/characters/%2e%2e/api/secrets"), null);
    assert.equal(sanitizeStAssetPath("/thumbnail?type=avatar&file=../../secrets.json"), null);
    assert.equal(sanitizeStAssetPath("//evil.example/a.png"), null);
    assert.equal(sanitizeStAssetPath("https://evil.example/a.png"), null);
    assert.equal(sanitizeStAssetPath("characters/no-slash.png"), null);
    assert.equal(sanitizeStAssetPath("/img/a\\b.png"), null);
    assert.equal(sanitizeStAssetPath(""), null);

    // HTML & CSS URL rewriting
    const inputHtml = `
      <div style="background-image: url('/backgrounds/sky.webp'); border: 1px solid #333;">
        <img src="/characters/alice.png" alt="Alice" />
        <img src='img/badge.png' />
        <video poster="./uploads/cover.jpg"></video>
        <link rel="stylesheet" href="/css/status.css" />
        <img src="https://cdn.example.com/ext.png" />
        <img src="data:image/png;base64,AAAA" />
        <a href="#top">Top</a>
        <a href="mailto:hi@example.com">Mail</a>
        <a href="/api/secrets">Blocked</a>
      </div>
    `;
    const rewritten = rewriteHtmlAssetUrls(inputHtml);
    assert.ok(rewritten.includes(`url('relay-st://asset?path=%2Fbackgrounds%2Fsky.webp')`));
    assert.ok(rewritten.includes(`src="relay-st://asset?path=%2Fcharacters%2Falice.png"`));
    assert.ok(rewritten.includes(`src='relay-st://asset?path=%2Fimg%2Fbadge.png'`));
    assert.ok(rewritten.includes(`poster="relay-st://asset?path=%2Fuploads%2Fcover.jpg"`));
    assert.ok(rewritten.includes(`href="relay-st://asset?path=%2Fcss%2Fstatus.css"`));
    assert.ok(rewritten.includes(`src="https://cdn.example.com/ext.png"`));
    assert.ok(rewritten.includes(`src="data:image/png;base64,AAAA"`));
    assert.ok(rewritten.includes(`href="#top"`));
    assert.ok(rewritten.includes(`href="mailto:hi@example.com"`));
    // Disallowed internal paths must NOT be rewritten to relay-st://
    assert.ok(rewritten.includes(`href="/api/secrets"`));

    // Block finalization + fallback reasoning split
    const finalized = finalizeExtractedMessages([
      {
        mesId: 0,
        name: "Seraphina",
        avatarPath: "/thumbnail?type=avatar&file=Seraphina.png",
        isUser: false,
        isSystem: false,
        sendDate: "now",
        rawText: "fallback",
        reasoning: "",
        swipeId: 0,
        swipeCount: 2,
        hasDom: true,
        isStreaming: false,
        rawBlocks: [
          { kind: "markdown", markdown: "Hello **world**" },
          { kind: "details", summary: "Status", markdown: "HP: 100" },
          { kind: "image", imageUrl: "/user/images/scene.png", imageAlt: "Scene" },
          { kind: "html", html: `<div style="padding:8px"><img src="/img/star.png"></div>`, estimatedHeight: 120.4 },
          { kind: "iframe", html: `<html><body><img src="/assets/bar.png"></body></html>`, estimatedHeight: 240 },
        ],
      },
      {
        mesId: 1,
        name: "Seraphina",
        avatarPath: null,
        isUser: false,
        isSystem: false,
        sendDate: "now",
        rawText: "<think>Inner thought</think>\nVisible reply",
        reasoning: "",
        swipeId: 0,
        swipeCount: 1,
        hasDom: false,
        isStreaming: false,
        rawBlocks: [],
      },
    ]);

    assert.equal(finalized[0].blocks.length, 5);
    assert.equal(finalized[0].blocks[2].imageUrl, "relay-st://asset?path=%2Fuser%2Fimages%2Fscene.png");
    assert.ok(finalized[0].blocks[3].html?.includes("relay-st://asset?path=%2Fimg%2Fstar.png"));
    assert.equal(finalized[0].blocks[3].estimatedHeight, 120);
    assert.ok(finalized[0].blocks[4].html?.includes("relay-st://asset?path=%2Fassets%2Fbar.png"));
    assert.equal(finalized[0].renderedHash.length, 12);

    assert.equal(finalized[1].reasoning, "Inner thought");
    assert.equal(finalized[1].blocks[0].markdown, "Visible reply");
  });

  it("encrypts and decrypts Tavern credentials via AES-256-GCM without storing plaintext", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-tavern-auth-"));
    const authPath = path.join(tmpDir, "tavern-auth.enc.json");
    const store = new TavernAuthStore(authPath, "super-secret-relay-token", tmpDir);

    assert.equal(store.loadCredentials(), null);
    store.saveCredentials({ handle: "alice", password: "my-top-secret-password!" });

    const onDisk = fs.readFileSync(authPath, "utf8");
    assert.equal(onDisk.includes("my-top-secret-password!"), false);
    assert.equal(onDisk.includes("alice"), false);

    const loaded = store.loadCredentials();
    assert.deepEqual(loaded, { handle: "alice", password: "my-top-secret-password!" });

    // Wrong key fails authentication tag check cleanly
    const wrongKeyStore = new TavernAuthStore(authPath, "different-token", tmpDir);
    assert.equal(wrongKeyStore.loadCredentials(), null);

    // Tampered ciphertext returns null
    const parsed = JSON.parse(onDisk) as { data: string };
    const corrupted = { ...parsed, data: Buffer.from("corrupted").toString("base64") };
    fs.writeFileSync(authPath, JSON.stringify(corrupted), "utf8");
    assert.equal(store.loadCredentials(), null);

    // Empty secretSeed falls back cleanly to persisted tavern-salt
    store.clearCredentials();
    assert.equal(fs.existsSync(authPath), false);
    const saltStore = new TavernAuthStore(authPath, "", tmpDir);
    saltStore.saveCredentials({ handle: "bob", password: "pw2" });
    assert.ok(fs.existsSync(path.join(tmpDir, "tavern-salt")));
    assert.deepEqual(saltStore.loadCredentials(), { handle: "bob", password: "pw2" });
  });

  it("protects /api/tavern/* with Bearer auth, proxies safe assets with Cookie, blocks /api/secrets, and handles all routes", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-tavern-routes-"));
    const dataDir = path.join(tmpDir, "data");
    const uploadsDir = path.join(dataDir, "uploads");
    fs.mkdirSync(uploadsDir, { recursive: true });

    const pngBytes = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
      "base64"
    );
    let capturedCookie = "";
    let capturedUrl = "";

    fakeStServer = http.createServer((req, res) => {
      capturedCookie = String(req.headers.cookie || "");
      capturedUrl = String(req.url || "");
      if (req.url?.startsWith("/thumbnail")) {
        res.writeHead(200, { "Content-Type": "image/png" });
        res.end(pngBytes);
        return;
      }
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not found" }));
    });

    await new Promise<void>((resolve) => fakeStServer!.listen(0, "127.0.0.1", () => resolve()));
    const stAddr = fakeStServer.address();
    assert.ok(stAddr && typeof stAddr === "object");

    const token = "tavern-test-bearer-token";
    const config: AppConfig = {
      host: "127.0.0.1",
      port: 0,
      relayToken: token,
      dataDir,
      uploadsDir,
      dbPath: path.join(dataDir, "relay.db"),
      agentsConfigPath: path.join(tmpDir, "agents.json"),
      defaultCwd: tmpDir,
      homeDir: tmpDir,
      stUrl: `http://127.0.0.1:${stAddr.port}`,
      stPublicUrl: "https://st.apps.makima.sbs",
      tavernProfileDir: path.join(dataDir, "tavern-profile"),
      tavernAuthPath: path.join(dataDir, "tavern-auth.enc.json"),
      tavernEnabled: true,
    };

    const mockBridge = createMockTavernBridge();
    server = await createRelayServer(config, [], { tavernBridge: mockBridge });
    const { baseUrl } = await server.listen();

    // 1. Unauthenticated requests rejected with 401
    const unauthStatus = await fetch(`${baseUrl}/api/tavern/status`);
    assert.equal(unauthStatus.status, 401);
    const unauthAsset = await fetch(
      `${baseUrl}/api/tavern/asset?path=${encodeURIComponent("/thumbnail?type=avatar&file=Seraphina.png")}`
    );
    assert.equal(unauthAsset.status, 401);

    const api = async (p: string, init: RequestInit = {}) => {
      const headers = new Headers(init.headers);
      headers.set("Authorization", `Bearer ${token}`);
      const res = await fetch(`${baseUrl}${p}`, { ...init, headers });
      const text = await res.text();
      let json: any = null;
      try {
        json = JSON.parse(text);
      } catch {}
      return { status: res.status, json, text, headers: res.headers };
    };

    // 2. Asset proxy security & cookie forwarding
    const missingPath = await api("/api/tavern/asset");
    assert.equal(missingPath.status, 400);

    const blockedSecrets = await api(
      `/api/tavern/asset?path=${encodeURIComponent("/api/secrets")}`
    );
    assert.equal(blockedSecrets.status, 403);

    const blockedTraversal = await api(
      `/api/tavern/asset?path=${encodeURIComponent("/characters/../api/secrets")}`
    );
    assert.equal(blockedTraversal.status, 403);

    const assetRes = await fetch(
      `${baseUrl}/api/tavern/asset?path=${encodeURIComponent("/thumbnail?type=avatar&file=Seraphina.png")}`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    assert.equal(assetRes.status, 200);
    assert.equal(assetRes.headers.get("content-type"), "image/png");
    assert.equal(assetRes.headers.get("cache-control"), "private, max-age=300");
    assert.equal(capturedCookie, "session-cookie=st_demo_cookie_value");
    assert.equal(capturedUrl, "/thumbnail?type=avatar&file=Seraphina.png");
    const assetBuf = Buffer.from(await assetRes.arrayBuffer());
    assert.deepEqual(assetBuf, pngBytes);

    // 3. Full Tavern REST surface
    const stRes = await api("/api/tavern/status");
    assert.equal(stRes.status, 200);
    assert.equal(stRes.json.status.ready, true);

    const loginRes = await api("/api/tavern/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ handle: "alice", password: "secret" }),
    });
    assert.equal(loginRes.status, 200);
    assert.equal(loginRes.json.status.handle, "alice");

    const charsRes = await api("/api/tavern/characters");
    assert.equal(charsRes.status, 200);
    assert.equal(charsRes.json.characters.length, 1);
    assert.equal(charsRes.json.characters[0].name, "Seraphina");

    const chatsRes = await api("/api/tavern/characters/0/chats");
    assert.equal(chatsRes.status, 200);
    assert.equal(chatsRes.json.characterId, 0);
    assert.equal(chatsRes.json.chats.length, 1);

    const selectRes = await api("/api/tavern/select", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ characterId: 0, chatFile: "Seraphina - 2026-11-25.jsonl" }),
    });
    assert.equal(selectRes.status, 200);
    assert.equal(selectRes.json.state.messages.length, 3);
    assert.equal(selectRes.json.state.messages[2].reasoning, "Checking star chart");

    const curRes = await api("/api/tavern/current");
    assert.equal(curRes.status, 200);
    assert.equal(curRes.json.state.userName, "You");

    const sendRes = await api("/api/tavern/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: "Tell me about Orion." }),
    });
    assert.equal(sendRes.status, 202);
    assert.equal(sendRes.json.ok, true);
    assert.equal(sendRes.json.state.messages.length, 4);

    const stopRes = await api("/api/tavern/stop", { method: "POST" });
    assert.equal(stopRes.status, 200);
    assert.equal(stopRes.json.stopped, true);

    const regenRes = await api("/api/tavern/regenerate", { method: "POST" });
    assert.equal(regenRes.status, 202);
    assert.equal(regenRes.json.ok, true);

    const contRes = await api("/api/tavern/continue", { method: "POST" });
    assert.equal(contRes.status, 202);
    assert.equal(contRes.json.ok, true);

    const swipeRes = await api("/api/tavern/swipe", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mesId: 2, direction: "right" }),
    });
    assert.equal(swipeRes.status, 200);
    assert.equal(swipeRes.json.message.swipeId, 1);

    const editRes = await api("/api/tavern/messages/2", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: "Edited starlight reply." }),
    });
    assert.equal(editRes.status, 200);
    assert.equal(editRes.json.message.rawText, "Edited starlight reply.");

    const slashRes = await api("/api/tavern/slash", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ command: "/echo hello" }),
    });
    assert.equal(slashRes.status, 200);
    assert.equal(slashRes.json.ok, true);
    assert.equal(slashRes.json.result, "executed:/echo hello");

    const delRes = await api("/api/tavern/messages/2", { method: "DELETE" });
    assert.equal(delRes.status, 200);
    assert.equal(delRes.json.ok, true);
    assert.equal(delRes.json.state.messages.length, 3);

    const reloadRes = await api("/api/tavern/reload", { method: "POST" });
    assert.equal(reloadRes.status, 200);
    assert.equal(reloadRes.json.characters.length, 1);
  });
});

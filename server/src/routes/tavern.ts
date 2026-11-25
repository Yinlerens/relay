import path from "node:path";
import type { FastifyInstance } from "fastify";
import type { AppConfig } from "../config.js";
import { sanitizeStAssetPath } from "../tavern/dom-extractor.js";
import type { TavernBridgeLike, TavernSwipeDirection } from "../tavern/types.js";

function inferMimeType(assetPath: string): string {
  const clean = assetPath.split("?")[0].toLowerCase();
  const ext = path.extname(clean);
  switch (ext) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".webp":
      return "image/webp";
    case ".gif":
      return "image/gif";
    case ".svg":
      return "image/svg+xml";
    case ".css":
      return "text/css; charset=utf-8";
    case ".js":
    case ".mjs":
      return "application/javascript; charset=utf-8";
    case ".woff2":
      return "font/woff2";
    case ".woff":
      return "font/woff";
    case ".mp3":
      return "audio/mpeg";
    case ".ogg":
      return "audio/ogg";
    default:
      return "application/octet-stream";
  }
}

const LONG_CACHE_STATIC_PREFIXES = [
  "/scripts/",
  "/css/",
  "/assets/",
  "/img/",
  "/characters/",
  "/user/",
  "/backgrounds/",
  "/User Avatars/",
  "/User%20Avatars/",
  "/default-expressions/",
  "/uploads/",
];

function sanitizeKnownHashes(raw: unknown): Record<string, string> | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return undefined;
  }
  const out: Record<string, string> = {};
  let count = 0;
  for (const [key, val] of Object.entries(raw as Record<string, unknown>)) {
    if (count >= 300) break;
    if (!/^\d+$/.test(key)) continue;
    if (typeof val !== "string") continue;
    const cleanVal = val.trim();
    if (!cleanVal || cleanVal.length > 64) continue;
    out[key] = cleanVal;
    count++;
  }
  return count > 0 ? out : undefined;
}

function resolveAssetCacheSeconds(safePath: string): number {
  const pathname = safePath.split("?")[0];
  if (pathname === "/thumbnail") {
    return 1800;
  }
  if (LONG_CACHE_STATIC_PREFIXES.some((prefix) => pathname.startsWith(prefix))) {
    return 604800;
  }
  return 3600;
}

export function registerTavernRoutes(
  app: FastifyInstance,
  config: AppConfig,
  bridge: TavernBridgeLike
): void {
  app.get("/api/tavern/status", async () => {
    return bridge.getStatus();
  });

  app.post<{ Body: { handle?: string; password?: string } }>(
    "/api/tavern/login",
    async (req, reply) => {
      const handle = req.body?.handle?.trim();
      if (!handle) {
        return reply.code(400).send({ error: "handle is required" });
      }
      return bridge.login(handle, String(req.body?.password ?? ""));
    }
  );

  app.post("/api/tavern/reload", async () => {
    return bridge.reload();
  });

  app.get("/api/tavern/characters", async () => {
    return bridge.listCharacters();
  });

  app.get<{ Params: { id: string } }>("/api/tavern/characters/:id/chats", async (req, reply) => {
    const id = Number.parseInt(req.params.id, 10);
    if (!Number.isFinite(id) || id < 0) {
      return reply.code(400).send({ error: "Invalid character id" });
    }
    return bridge.listCharacterChats(id);
  });

  app.post<{
    Body: {
      characterId?: number;
      chatFile?: string;
      createNew?: boolean;
      knownChatFile?: string;
      knownHashes?: Record<string, unknown>;
    };
  }>("/api/tavern/select", async (req, reply) => {
    const characterId = req.body?.characterId;
    if (typeof characterId !== "number" || !Number.isFinite(characterId) || characterId < 0) {
      return reply.code(400).send({ error: "characterId is required" });
    }
    const knownChatFile =
      typeof req.body?.knownChatFile === "string" && req.body.knownChatFile.trim()
        ? req.body.knownChatFile.trim().slice(0, 300)
        : undefined;
    const knownHashes = sanitizeKnownHashes(req.body?.knownHashes);
    return bridge.selectCharacter({
      characterId: Math.trunc(characterId),
      chatFile: req.body?.chatFile,
      createNew: Boolean(req.body?.createNew),
      knownChatFile,
      knownHashes,
    });
  });

  app.get<{ Querystring: { limit?: string; before?: string } }>(
    "/api/tavern/current",
    async (req) => {
      const rawLimit = req.query?.limit ? Number.parseInt(req.query.limit, 10) : NaN;
      const rawBefore = req.query?.before ? Number.parseInt(req.query.before, 10) : NaN;
      const limit =
        Number.isFinite(rawLimit) && rawLimit > 0 ? Math.min(200, Math.max(1, rawLimit)) : undefined;
      const beforeMesId =
        Number.isFinite(rawBefore) && rawBefore >= 0 ? rawBefore : undefined;
      return bridge.getCurrentState(
        limit !== undefined || beforeMesId !== undefined ? { limit, beforeMesId } : undefined
      );
    }
  );

  app.post<{ Body: { text?: string } }>("/api/tavern/send", async (req, reply) => {
    const text = req.body?.text ?? "";
    if (!text.trim()) {
      return reply.code(400).send({ error: "text is required" });
    }
    const res = await bridge.sendMessage(text);
    return reply.code(202).send(res);
  });

  app.post("/api/tavern/stop", async () => {
    return bridge.stopGeneration();
  });

  app.post("/api/tavern/regenerate", async (_req, reply) => {
    const res = await bridge.regenerate();
    return reply.code(202).send(res);
  });

  app.post("/api/tavern/continue", async (_req, reply) => {
    const res = await bridge.continueGeneration();
    return reply.code(202).send(res);
  });

  app.post<{
    Body: { mesId?: number; direction?: TavernSwipeDirection };
  }>("/api/tavern/swipe", async (req, reply) => {
    const mesId = req.body?.mesId;
    const direction = req.body?.direction;
    if (typeof mesId !== "number" || !Number.isFinite(mesId) || mesId < 0) {
      return reply.code(400).send({ error: "mesId is required" });
    }
    if (direction !== "left" && direction !== "right" && direction !== "new") {
      return reply.code(400).send({ error: "direction must be left, right, or new" });
    }
    return bridge.swipe(Math.trunc(mesId), direction);
  });

  app.patch<{
    Params: { mesId: string };
    Body: { text?: string };
  }>("/api/tavern/messages/:mesId", async (req, reply) => {
    const mesId = Number.parseInt(req.params.mesId, 10);
    if (!Number.isFinite(mesId) || mesId < 0) {
      return reply.code(400).send({ error: "Invalid mesId" });
    }
    if (typeof req.body?.text !== "string") {
      return reply.code(400).send({ error: "text is required" });
    }
    return bridge.editMessage(mesId, req.body.text);
  });

  app.delete<{ Params: { mesId: string } }>("/api/tavern/messages/:mesId", async (req, reply) => {
    const mesId = Number.parseInt(req.params.mesId, 10);
    if (!Number.isFinite(mesId) || mesId < 0) {
      return reply.code(400).send({ error: "Invalid mesId" });
    }
    return bridge.deleteMessage(mesId);
  });

  app.post<{ Body: { command?: string } }>("/api/tavern/slash", async (req, reply) => {
    const command = req.body?.command ?? "";
    if (!command.trim()) {
      return reply.code(400).send({ error: "command is required" });
    }
    return bridge.runSlash(command);
  });

  app.get<{ Querystring: { path?: string } }>("/api/tavern/asset", async (req, reply) => {
    const rawPath = req.query?.path;
    if (typeof rawPath !== "string" || !rawPath.trim()) {
      return reply.code(400).send({ error: "path query parameter is required" });
    }
    const safePath = sanitizeStAssetPath(rawPath);
    if (!safePath) {
      return reply.code(403).send({ error: "Disallowed asset path" });
    }

    const cookieHeader = await bridge.getAssetCookieHeader();
    const targetUrl = `${config.stUrl}${safePath}`;
    const headers: Record<string, string> = {};
    if (cookieHeader) {
      headers.Cookie = cookieHeader;
    }

    const upstream = await fetch(targetUrl, {
      method: "GET",
      headers,
      redirect: "manual",
    });

    if (upstream.status >= 300 && upstream.status < 400) {
      return reply.code(401).send({ error: "Tavern session requires login" });
    }

    if (!upstream.ok) {
      return reply.code(upstream.status).send({ error: `Upstream asset error (${upstream.status})` });
    }

    const cleanPath = safePath.split("?")[0].toLowerCase();
    let contentType = upstream.headers.get("content-type") || inferMimeType(safePath);
    if (cleanPath.endsWith(".js") || cleanPath.endsWith(".mjs")) {
      contentType = "application/javascript; charset=utf-8";
    } else if (cleanPath.endsWith(".css")) {
      contentType = "text/css; charset=utf-8";
    }
    const cacheSeconds = resolveAssetCacheSeconds(safePath);
    const buf = Buffer.from(await upstream.arrayBuffer());

    reply.header("Content-Type", contentType);
    reply.header("Cache-Control", `private, max-age=${cacheSeconds}`);
    return reply.send(buf);
  });
}

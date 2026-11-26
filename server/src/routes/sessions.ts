import fs from "node:fs";
import path from "node:path";
import type { FastifyInstance } from "fastify";
import type { ConfigValue } from "../acp/types.js";
import type { SessionManager } from "../acp/manager.js";
import type { AppConfig } from "../config.js";
import type { RelayDatabase } from "../db.js";
import type { SwarmManager } from "../swarm/manager.js";

export function registerSessionRoutes(
  app: FastifyInstance,
  config: AppConfig,
  db: RelayDatabase,
  manager: SessionManager,
  swarmManager?: SwarmManager
): void {
  app.get("/api/bootstrap", async () => {
    const running = manager.getRunningSessionIds();
    return {
      agents: manager.getAgents().map(({ id, name, subtitle, icon, accent }) => ({
        id,
        name,
        subtitle,
        icon,
        accent,
      })),
      sessions: db.listSessions(running),
      swarms: db.listSwarms(running),
      defaultCwd: config.defaultCwd,
      settings: {
        barkUrl: db.getSetting("bark_url") || "",
      },
    };
  });

  app.get("/api/agents", async () => ({
    agents: manager.getAgents().map(({ id, name, subtitle, icon, accent }) => ({
      id,
      name,
      subtitle,
      icon,
      accent,
    })),
  }));

  app.get<{ Params: { id: string } }>("/api/agents/:id/models", async (req, reply) => {
    if (!manager.hasAgent(req.params.id)) {
      return reply.code(404).send({ error: `Unknown agent: ${req.params.id}` });
    }
    return manager.probeAgentModels(req.params.id);
  });

  app.get("/api/workspaces", async () => {
    const candidates = new Set<string>([config.defaultCwd]);
    try {
      const entries = fs.readdirSync(config.homeDir, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        if (entry.name.startsWith(".")) continue;
        candidates.add(path.join(config.homeDir, entry.name));
      }
    } catch {
      // ignore
    }
    return { workspaces: Array.from(candidates) };
  });

  app.get("/api/sessions", async () => ({
    sessions: db.listSessions(manager.getRunningSessionIds()),
  }));

  app.post<{
    Body: { agentId?: string; cwd?: string; title?: string };
  }>("/api/sessions", async (req, reply) => {
    const agentId = req.body?.agentId?.trim();
    if (!agentId) {
      return reply.code(400).send({ error: "agentId is required" });
    }
    const session = await manager.createSession({
      agentId,
      cwd: req.body?.cwd,
      title: req.body?.title,
    });
    return reply.code(201).send({ session });
  });

  app.get<{ Params: { id: string } }>("/api/sessions/:id", async (req, reply) => {
    const session = db.getSession(req.params.id, manager.getRunningSessionIds());
    if (!session) {
      return reply.code(404).send({ error: "Session not found" });
    }
    const messages = db.listMessages(session.id);
    return { session, messages };
  });

  app.patch<{ Params: { id: string }; Body: { title?: string; pinned?: boolean } }>(
    "/api/sessions/:id",
    async (req, reply) => {
      const session = db.getSession(req.params.id, manager.getRunningSessionIds());
      if (!session) {
        return reply.code(404).send({ error: "Session not found" });
      }
      const hasTitle = req.body?.title !== undefined;
      const hasPinned = typeof req.body?.pinned === "boolean";
      if (!hasTitle && !hasPinned) {
        return reply.code(400).send({ error: "title or pinned is required" });
      }
      if (hasTitle) {
        const title = req.body?.title?.trim();
        if (!title) {
          return reply.code(400).send({ error: "title cannot be empty" });
        }
        const cleanTitle = title.slice(0, 80);
        if (session.swarmRole === "coordinator" && session.swarmId && swarmManager) {
          swarmManager.updateSwarm(session.swarmId, { title: cleanTitle });
        } else {
          db.updateSession(session.id, {
            title: cleanTitle,
            ...(hasPinned ? { pinned: req.body.pinned } : {}),
          });
        }
      }
      if (hasPinned && (!hasTitle || (session.swarmRole === "coordinator" && session.swarmId && swarmManager))) {
        db.updateSession(session.id, {
          pinned: Boolean(req.body.pinned),
          touchUpdatedAt: false,
        });
      }
      const updated = db.getSession(session.id, manager.getRunningSessionIds());
      if (updated) {
        manager.emitExternal("session_updated", session.id, { session: updated });
      }
      return { session: updated };
    }
  );

  app.delete<{ Params: { id: string } }>("/api/sessions/:id", async (req, reply) => {
    const ok = manager.deleteSession(req.params.id);
    if (!ok) {
      return reply.code(404).send({ error: "Session not found" });
    }
    return { ok: true };
  });

  app.post<{
    Params: { id: string };
    Body: { kind?: "model" | "mode" | "config"; configId?: string; value?: ConfigValue };
  }>("/api/sessions/:id/config", async (req, reply) => {
    const { kind, configId, value } = req.body || {};
    if (!kind || value === undefined) {
      return reply.code(400).send({ error: "kind and value are required" });
    }
    const updated = await manager.updateSessionConfig(req.params.id, {
      kind,
      configId,
      value,
    });
    return { session: updated };
  });

  app.post<{
    Params: { id: string };
    Body: { text?: string; attachmentIds?: string[] };
  }>("/api/sessions/:id/prompt", async (req, reply) => {
    const text = req.body?.text ?? "";
    const attachmentIds = Array.isArray(req.body?.attachmentIds)
      ? req.body.attachmentIds
      : [];
    const result = await manager.startPrompt(req.params.id, { text, attachmentIds });
    return reply.code(202).send(result);
  });

  app.post<{ Params: { id: string } }>("/api/sessions/:id/cancel", async (req) => {
    const cancelled = manager.cancelTurn(req.params.id);
    return { cancelled };
  });
}

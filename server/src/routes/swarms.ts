import type { FastifyInstance } from "fastify";
import type { SwarmStatus, SwarmWorkspaceMode } from "../acp/types.js";
import type { SwarmManager } from "../swarm/manager.js";

export function registerSwarmRoutes(
  app: FastifyInstance,
  swarmManager: SwarmManager
): void {
  app.get("/api/swarms", async () => ({
    swarms: swarmManager.listSwarms(),
  }));

  app.post<{
    Body: {
      title?: string;
      cwd?: string;
      coordinatorAgentId?: string;
      coordinatorModelId?: string | null;
      defaultWorkerAgentId?: string;
      defaultWorkerModelId?: string | null;
    };
  }>("/api/swarms", async (req, reply) => {
    const result = await swarmManager.createSwarm(req.body || {});
    return reply.code(201).send(result);
  });

  app.get<{ Params: { id: string } }>("/api/swarms/:id", async (req, reply) => {
    const detail = swarmManager.getSwarm(req.params.id);
    if (!detail) {
      return reply.code(404).send({ error: "Swarm not found" });
    }
    return detail;
  });

  app.patch<{
    Params: { id: string };
    Body: {
      title?: string;
      status?: SwarmStatus;
      defaultWorkerAgentId?: string;
      defaultWorkerModelId?: string | null;
    };
  }>("/api/swarms/:id", async (req) => {
    const swarm = swarmManager.updateSwarm(req.params.id, req.body || {});
    return { swarm };
  });

  app.post<{
    Params: { id: string };
    Body: {
      name?: string;
      brief?: string;
      agentId?: string;
      modelId?: string | null;
      workspace?: SwarmWorkspaceMode;
    };
  }>("/api/swarms/:id/workers", async (req, reply) => {
    const body = req.body || {};
    const result = await swarmManager.addWorker(req.params.id, {
      name: body.name ?? "",
      brief: body.brief ?? "",
      agentId: body.agentId,
      modelId: body.modelId,
      workspace: body.workspace,
      sender: "coordinator",
    });
    return reply.code(201).send(result);
  });

  app.post<{
    Params: { id: string };
    Body: { text?: string };
  }>("/api/swarms/:id/board", async (req, reply) => {
    const result = await swarmManager.postBoard(req.params.id, {
      sender: "user",
      text: req.body?.text ?? "",
    });
    return reply.code(201).send(result);
  });

  app.post<{
    Params: { id: string; name: string };
    Body: { removeWorktree?: boolean };
  }>("/api/swarms/:id/workers/:name/kill", async (req) => {
    const removeWorktree =
      req.body?.removeWorktree !== undefined ? Boolean(req.body.removeWorktree) : true;
    return swarmManager.killWorker(req.params.id, req.params.name, { removeWorktree });
  });

  app.delete<{ Params: { id: string } }>("/api/swarms/:id", async (req, reply) => {
    const ok = await swarmManager.deleteSwarm(req.params.id);
    if (!ok) {
      return reply.code(404).send({ error: "Swarm not found" });
    }
    return { ok: true };
  });
}

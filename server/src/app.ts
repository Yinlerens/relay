import crypto from "node:crypto";
import multipart from "@fastify/multipart";
import websocket from "@fastify/websocket";
import Fastify, { type FastifyInstance } from "fastify";
import { SessionManager } from "./acp/manager.js";
import { makeAuthHook } from "./auth.js";
import type { AgentProfile, AppConfig } from "./config.js";
import { RelayDatabase } from "./db.js";
import { registerQuotaRoutes } from "./routes/quotas.js";
import { registerSessionRoutes } from "./routes/sessions.js";
import { registerSettingsRoutes } from "./routes/settings.js";
import { registerSwarmRoutes } from "./routes/swarms.js";
import { registerTavernRoutes } from "./routes/tavern.js";
import { registerUploadRoutes } from "./routes/uploads.js";
import { SwarmManager } from "./swarm/manager.js";
import { registerSwarmMcpRoutes } from "./swarm/mcp.js";
import { TavernBridge } from "./tavern/bridge.js";
import type { TavernBridgeLike } from "./tavern/types.js";

export interface RelayServerInstance {
  app: FastifyInstance;
  db: RelayDatabase;
  manager: SessionManager;
  swarmManager: SwarmManager;
  tavernBridge: TavernBridgeLike;
  internalMcpToken: string;
  listen: () => Promise<{ host: string; port: number; baseUrl: string }>;
  close: () => Promise<void>;
}

export interface CreateRelayServerOptions {
  tavernBridge?: TavernBridgeLike;
}

export async function createRelayServer(
  config: AppConfig,
  agents: AgentProfile[],
  options?: CreateRelayServerOptions
): Promise<RelayServerInstance> {
  const db = new RelayDatabase(config.dbPath);
  const manager = new SessionManager(config, db, agents);
  const internalMcpToken = crypto.randomBytes(32).toString("hex");

  let boundPort = config.port;
  const getBaseUrl = () => `http://127.0.0.1:${boundPort}`;
  const swarmManager = new SwarmManager(config, db, manager, internalMcpToken, getBaseUrl);
  const tavernBridge: TavernBridgeLike =
    options?.tavernBridge ?? new TavernBridge(config, db, manager);

  const app = Fastify({ logger: false });

  await app.register(multipart, {
    limits: {
      fileSize: 25 * 1024 * 1024,
      files: 1,
    },
  });
  await app.register(websocket);

  app.addHook("onRequest", makeAuthHook(config.relayToken, internalMcpToken));

  app.get("/healthz", async () => ({
    ok: true,
    service: "relay",
    agents: manager.getAgents().map((a) => a.id),
  }));

  registerSessionRoutes(app, config, db, manager, swarmManager);
  registerUploadRoutes(app, config, db);
  registerSettingsRoutes(app, db);
  registerQuotaRoutes(app, config);
  registerSwarmRoutes(app, swarmManager);
  registerSwarmMcpRoutes(app, swarmManager);
  registerTavernRoutes(app, config, tavernBridge);

  app.get("/ws", { websocket: true }, (socket) => {
    const unsubscribe = manager.subscribe((ev) => {
      if (socket.readyState === 1) {
        socket.send(JSON.stringify(ev));
      }
    });

    socket.on("message", (raw: Buffer | string) => {
      try {
        const msg = JSON.parse(raw.toString()) as { type?: string };
        if (msg.type === "ping" && socket.readyState === 1) {
          socket.send(JSON.stringify({ type: "pong", ts: Date.now() }));
        }
      } catch {
        // ignore malformed frames
      }
    });

    socket.on("close", () => {
      unsubscribe();
    });
  });

  const listen = async () => {
    await app.listen({ host: config.host, port: config.port });
    const addr = app.server.address();
    if (addr && typeof addr === "object") {
      boundPort = addr.port;
    }
    if (tavernBridge instanceof TavernBridge && config.tavernEnabled) {
      tavernBridge.warmup();
    }
    return {
      host: config.host,
      port: boundPort,
      baseUrl: `http://127.0.0.1:${boundPort}`,
    };
  };

  const close = async () => {
    await tavernBridge.dispose();
    swarmManager.disposeAll();
    await manager.disposeAll();
    await app.close();
    db.close();
  };

  return {
    app,
    db,
    manager,
    swarmManager,
    tavernBridge,
    internalMcpToken,
    listen,
    close,
  };
}

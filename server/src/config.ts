import fs from "node:fs";
import path from "node:path";
import os from "node:os";

export interface AgentProfile {
  id: string;
  name: string;
  subtitle: string;
  icon: string;
  accent: string;
  command: string;
  args: string[];
  env?: Record<string, string>;
}

export interface AppConfig {
  host: string;
  port: number;
  relayToken: string;
  dataDir: string;
  uploadsDir: string;
  dbPath: string;
  agentsConfigPath: string;
  defaultCwd: string;
  homeDir: string;
  stUrl: string;
  stPublicUrl: string;
  tavernProfileDir: string;
  tavernAuthPath: string;
  tavernEnabled: boolean;
  stDataDir?: string | null;
}

export function loadConfig(): AppConfig {
  const dataDir = path.resolve(process.env.DATA_DIR || "./data");
  const uploadsDir = path.join(dataDir, "uploads");
  const defaultCwd = path.resolve(
    process.env.DEFAULT_CWD || path.join(os.homedir(), "workspace")
  );
  const agentsConfigPath = path.resolve(
    process.env.AGENTS_CONFIG || "./agents.json"
  );

  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(uploadsDir, { recursive: true });
  fs.mkdirSync(defaultCwd, { recursive: true });

  if (!fs.existsSync(agentsConfigPath)) {
    const exampleCandidates = [
      path.resolve("./agents.example.json"),
      path.resolve(path.dirname(agentsConfigPath), "agents.example.json"),
    ];
    for (const candidate of exampleCandidates) {
      if (fs.existsSync(candidate)) {
        fs.copyFileSync(candidate, agentsConfigPath);
        break;
      }
    }
  }

  const relayToken = (process.env.RELAY_TOKEN || "").trim();
  if (!relayToken && process.env.NODE_ENV === "production") {
    throw new Error("RELAY_TOKEN must be configured in production");
  }

  const stUrl = (process.env.ST_URL || "http://127.0.0.1:8000").replace(/\/+$/, "");
  const stPublicUrl = (process.env.ST_PUBLIC_URL || "https://st.apps.makima.sbs").replace(/\/+$/, "");
  const tavernProfileDir = path.join(dataDir, "tavern-profile");
  const tavernAuthPath = path.join(dataDir, "tavern-auth.enc.json");
  const tavernEnabledEnv = (process.env.TAVERN_ENABLED || "true").trim().toLowerCase();
  const tavernEnabled = !["0", "false", "no", "off"].includes(tavernEnabledEnv);
  const rawStDataDir = (process.env.ST_DATA_DIR || "").trim();
  let stDataDir: string | null = null;
  if (rawStDataDir) {
    stDataDir = path.resolve(rawStDataDir);
  } else if (fs.existsSync("/opt/sillytavern/data")) {
    stDataDir = "/opt/sillytavern/data";
  }

  return {
    host: process.env.HOST || "127.0.0.1",
    port: Number.parseInt(process.env.PORT || "18660", 10),
    relayToken,
    dataDir,
    uploadsDir,
    dbPath: path.join(dataDir, "relay.db"),
    agentsConfigPath,
    defaultCwd,
    homeDir: os.homedir(),
    stUrl,
    stPublicUrl,
    tavernProfileDir,
    tavernAuthPath,
    tavernEnabled,
    stDataDir,
  };
}

export function loadAgentProfiles(configPath: string): AgentProfile[] {
  if (!fs.existsSync(configPath)) {
    return [];
  }
  const raw = fs.readFileSync(configPath, "utf8");
  const parsed = JSON.parse(raw) as unknown;
  if (!Array.isArray(parsed)) {
    throw new Error("agents.json must be a JSON array");
  }
  return parsed as AgentProfile[];
}

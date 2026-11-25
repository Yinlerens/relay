import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export interface TavernCredentials {
  handle: string;
  password: string;
}

interface EncryptedEnvelope {
  v: 1;
  salt: string;
  iv: string;
  tag: string;
  data: string;
}

export class TavernAuthStore {
  private readonly fallbackKeyPath: string;

  constructor(
    private readonly authPath: string,
    private readonly secretSeed: string,
    dataDir?: string
  ) {
    const dir = dataDir || path.dirname(authPath);
    this.fallbackKeyPath = path.join(dir, "tavern-salt");
  }

  private getKeyMaterial(): string {
    const trimmed = this.secretSeed.trim();
    if (trimmed) {
      return trimmed;
    }
    if (fs.existsSync(this.fallbackKeyPath)) {
      const existing = fs.readFileSync(this.fallbackKeyPath, "utf8").trim();
      if (existing) return existing;
    }
    fs.mkdirSync(path.dirname(this.fallbackKeyPath), { recursive: true });
    const generated = crypto.randomBytes(32).toString("hex");
    fs.writeFileSync(this.fallbackKeyPath, generated, { encoding: "utf8", mode: 0o600 });
    try {
      fs.chmodSync(this.fallbackKeyPath, 0o600);
    } catch {
      // Ignore chmod errors on Windows
    }
    return generated;
  }

  private deriveKey(salt: Buffer): Buffer {
    return crypto.scryptSync(this.getKeyMaterial(), salt, 32);
  }

  saveCredentials(creds: TavernCredentials): void {
    const handle = String(creds.handle || "").trim();
    const password = String(creds.password ?? "");
    if (!handle) {
      throw new Error("handle is required");
    }

    fs.mkdirSync(path.dirname(this.authPath), { recursive: true });
    const salt = crypto.randomBytes(16);
    const iv = crypto.randomBytes(12);
    const key = this.deriveKey(salt);

    const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
    const plaintext = Buffer.from(JSON.stringify({ handle, password }), "utf8");
    const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const tag = cipher.getAuthTag();

    const envelope: EncryptedEnvelope = {
      v: 1,
      salt: salt.toString("base64"),
      iv: iv.toString("base64"),
      tag: tag.toString("base64"),
      data: encrypted.toString("base64"),
    };

    fs.writeFileSync(this.authPath, JSON.stringify(envelope), { encoding: "utf8", mode: 0o600 });
    try {
      fs.chmodSync(this.authPath, 0o600);
    } catch {
      // Ignore chmod errors on Windows
    }
  }

  loadCredentials(): TavernCredentials | null {
    if (!fs.existsSync(this.authPath)) {
      return null;
    }
    try {
      const raw = fs.readFileSync(this.authPath, "utf8");
      const envelope = JSON.parse(raw) as Partial<EncryptedEnvelope>;
      if (
        envelope.v !== 1 ||
        typeof envelope.salt !== "string" ||
        typeof envelope.iv !== "string" ||
        typeof envelope.tag !== "string" ||
        typeof envelope.data !== "string"
      ) {
        return null;
      }

      const salt = Buffer.from(envelope.salt, "base64");
      const iv = Buffer.from(envelope.iv, "base64");
      const tag = Buffer.from(envelope.tag, "base64");
      const ciphertext = Buffer.from(envelope.data, "base64");
      const key = this.deriveKey(salt);

      const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
      decipher.setAuthTag(tag);
      const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString(
        "utf8"
      );
      const parsed = JSON.parse(plaintext) as Partial<TavernCredentials>;
      if (typeof parsed.handle !== "string" || !parsed.handle.trim()) {
        return null;
      }
      return {
        handle: parsed.handle.trim(),
        password: typeof parsed.password === "string" ? parsed.password : "",
      };
    } catch {
      return null;
    }
  }

  clearCredentials(): void {
    try {
      if (fs.existsSync(this.authPath)) {
        fs.unlinkSync(this.authPath);
      }
    } catch {
      // ignore
    }
  }
}

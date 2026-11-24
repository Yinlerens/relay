import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { FastifyInstance } from "fastify";
import type { AppConfig } from "../config.js";
import type { RelayDatabase } from "../db.js";

function sanitizeFilename(name: string): string {
  const base = path.basename(name || "upload.bin");
  return base.replace(/[^\w.\-()\u4e00-\u9fa5]/g, "_").slice(0, 100) || "upload.bin";
}

export function registerUploadRoutes(
  app: FastifyInstance,
  config: AppConfig,
  db: RelayDatabase
): void {
  app.post("/api/uploads", async (req, reply) => {
    const data = await req.file();
    if (!data) {
      return reply.code(400).send({ error: "No file uploaded" });
    }

    const id = crypto.randomUUID();
    const safeName = sanitizeFilename(data.filename);
    const mimeType = data.mimetype || "application/octet-stream";
    const diskPath = path.join(config.uploadsDir, `${id}-${safeName}`);

    const chunks: Buffer[] = [];
    for await (const chunk of data.file) {
      chunks.push(chunk as Buffer);
    }
    const buf = Buffer.concat(chunks);
    fs.writeFileSync(diskPath, buf);

    const record = db.createUpload({
      id,
      filename: safeName,
      mimeType,
      sizeBytes: buf.byteLength,
      diskPath,
      createdAt: Date.now(),
    });

    return reply.code(201).send({
      id: record.id,
      filename: record.filename,
      mimeType: record.mimeType,
      sizeBytes: record.sizeBytes,
      isImage: record.mimeType.startsWith("image/"),
    });
  });

  app.get<{ Params: { id: string } }>("/api/uploads/:id", async (req, reply) => {
    const rec = db.getUpload(req.params.id);
    if (!rec || !fs.existsSync(rec.diskPath)) {
      return reply.code(404).send({ error: "Upload not found" });
    }
    reply.header("Content-Type", rec.mimeType);
    reply.header("Cache-Control", "private, max-age=86400");
    return reply.send(fs.createReadStream(rec.diskPath));
  });
}

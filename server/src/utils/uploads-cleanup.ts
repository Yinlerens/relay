import fs from "node:fs";
import path from "node:path";
import type { RelayDatabase } from "../db.js";

/** Deletes upload DB rows and disk files for `candidateIds` that are no longer referenced by any message. */
export function cleanupUploadsByIds(db: RelayDatabase, candidateIds: Iterable<string>): number {
  const unique = Array.from(new Set(candidateIds)).filter(Boolean);
  if (unique.length === 0) return 0;

  const referenced = db.listAllReferencedAttachmentIds();
  let removed = 0;
  for (const id of unique) {
    if (referenced.has(id)) continue;
    const rec = db.getUpload(id);
    if (rec?.diskPath) {
      try {
        fs.rmSync(rec.diskPath, { force: true });
      } catch {
        // best-effort unlink
      }
    }
    if (db.deleteUpload(id)) {
      removed++;
    }
  }
  return removed;
}

/**
 * Purges unreferenced `uploads` rows older than `maxAgeMs` along with stray files in `uploadsDir`
 * not tracked by any DB record. Fresh uploads within `maxAgeMs` are kept (user may attach before sending).
 */
export function cleanupOrphanUploads(
  db: RelayDatabase,
  uploadsDir: string,
  maxAgeMs = 24 * 60 * 60 * 1000,
  now = Date.now()
): { removedRecords: number; removedStrayFiles: number } {
  const referenced = db.listAllReferencedAttachmentIds();
  const uploads = db.listUploads();
  const knownPaths = new Set<string>();

  let removedRecords = 0;
  for (const rec of uploads) {
    const resolvedPath = rec.diskPath ? path.resolve(rec.diskPath) : "";
    const age = now - rec.createdAt;
    if (!referenced.has(rec.id) && age >= maxAgeMs) {
      if (resolvedPath) {
        try {
          fs.rmSync(resolvedPath, { force: true });
        } catch {
          // best-effort unlink
        }
      }
      if (db.deleteUpload(rec.id)) {
        removedRecords++;
      }
    } else if (resolvedPath) {
      knownPaths.add(resolvedPath);
    }
  }

  let removedStrayFiles = 0;
  if (fs.existsSync(uploadsDir)) {
    let entries: fs.Dirent[] = [];
    try {
      entries = fs.readdirSync(uploadsDir, { withFileTypes: true });
    } catch {
      entries = [];
    }
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      const fullPath = path.resolve(uploadsDir, entry.name);
      if (knownPaths.has(fullPath)) continue;
      try {
        const stat = fs.statSync(fullPath);
        if (now - stat.mtimeMs >= maxAgeMs) {
          fs.rmSync(fullPath, { force: true });
          removedStrayFiles++;
        }
      } catch {
        // ignore stat/rm errors
      }
    }
  }

  return { removedRecords, removedStrayFiles };
}

import fs from "node:fs";
import type { SessionManager } from "../acp/manager.js";
import type { AppConfig } from "../config.js";
import type { RelayDatabase } from "../db.js";
import { sendBarkNotification } from "../utils/bark.js";
import { TavernAuthStore } from "./auth-store.js";
import {
  applyIncrementalChatDiff,
  buildExtractChatMessagesScript,
  buildTavernAvatarUrl,
  finalizeExtractedMessages,
  normalizeChatFileName,
  readCharacterChatsDiskSnapshot,
  type RawExtractedMessage,
} from "./dom-extractor.js";
import type {
  TavernBridgeLike,
  TavernCharacter,
  TavernChatFile,
  TavernChatState,
  TavernCurrentOptions,
  TavernLoginUser,
  TavernMessage,
  TavernSelectInput,
  TavernStatus,
  TavernSwipeDirection,
} from "./types.js";

interface PwCookie {
  name: string;
  value: string;
}

interface PwResponse {
  url(): string;
  status(): number;
  text(): Promise<string>;
}

interface PwPage {
  url(): string;
  goto(url: string, opts?: { waitUntil?: string; timeout?: number }): Promise<unknown>;
  reload(opts?: { waitUntil?: string; timeout?: number }): Promise<unknown>;
  evaluate<R = unknown, A = unknown>(fn: string | ((arg: A) => R | Promise<R>), arg?: A): Promise<R>;
  exposeFunction(name: string, fn: (...args: unknown[]) => unknown): Promise<void>;
  isClosed(): boolean;
  on(event: string, listener: (...args: unknown[]) => void): void;
}

interface PwBrowserContext {
  pages(): PwPage[];
  newPage(): Promise<PwPage>;
  cookies(urls?: string | string[]): Promise<PwCookie[]>;
  on(event: string, listener: (...args: unknown[]) => void): void;
  close(): Promise<void>;
}

interface PwModule {
  chromium: {
    launchPersistentContext(
      userDataDir: string,
      options: Record<string, unknown>
    ): Promise<PwBrowserContext>;
  };
}

function httpError(statusCode: number, message: string): Error {
  const err = new Error(message) as Error & { statusCode?: number };
  err.statusCode = statusCode;
  return err;
}

function parseTimestampToMs(raw: unknown): number {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    return raw > 0 && raw < 1e12 ? raw * 1000 : raw;
  }
  if (typeof raw === "string" && raw.trim()) {
    const asNum = Number(raw);
    if (Number.isFinite(asNum)) {
      return asNum > 0 && asNum < 1e12 ? asNum * 1000 : asNum;
    }
    const parsed = Date.parse(raw);
    if (Number.isFinite(parsed)) return parsed;
  }
  return 0;
}

export function formatTavernHttpError(status: number, rawBody: string): string {
  let detail = "";
  const trimmed = String(rawBody || "").trim();
  if (trimmed) {
    try {
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      const errField = parsed?.error;
      if (errField && typeof errField === "object") {
        const msg = (errField as Record<string, unknown>).message;
        if (typeof msg === "string" && msg.trim()) {
          detail = msg.trim();
        }
      } else if (typeof errField === "string" && errField.trim()) {
        detail = errField.trim();
      }
      if (!detail && typeof parsed?.message === "string" && parsed.message.trim()) {
        detail = parsed.message.trim();
      }
    } catch {
      // Plain text or HTML error response
    }
    if (!detail) {
      detail = trimmed.replace(/<[^>]*>/g, " ");
    }
    detail = detail.replace(/\s+/g, " ").trim().slice(0, 180);
  }

  if (status === 429) {
    return detail
      ? `上游接口限流 (429)：${detail}`
      : "上游接口限流 (429)：资源暂时耗尽，请稍后重试";
  }
  if (status === 401 || status === 403) {
    return `上游接口鉴权或权限拒绝 (${status})${detail ? `：${detail}` : ""}`;
  }
  if (status >= 500) {
    return `上游接口服务异常 (${status})${detail ? `：${detail}` : ""}`;
  }
  return `生成请求失败 (${status})${detail ? `：${detail}` : ""}`;
}

export class TavernBridge implements TavernBridgeLike {
  private readonly authStore: TavernAuthStore;
  private context: PwBrowserContext | null = null;
  private page: PwPage | null = null;
  private initPromise: Promise<void> | null = null;
  private queue: Promise<unknown> = Promise.resolve();
  private disposed = false;

  private ready = false;
  private needsLogin = false;
  private handle: string | null = null;
  private currentCharacterId: number | null = null;
  private currentCharacterName: string | null = null;
  private currentCharacterAvatar: string | null = null;
  private currentChatFile: string | null = null;
  private isGenerating = false;
  private lastError: string | null = null;
  private loginUsers: TavernLoginUser[] = [];

  private streamPollTimer: NodeJS.Timeout | null = null;
  private deltaThrottleTimer: NodeJS.Timeout | null = null;
  private finalizeTimer: NodeJS.Timeout | null = null;
  private delayedCheckTimer: NodeJS.Timeout | null = null;
  private renderRefreshTimer: NodeJS.Timeout | null = null;
  private lastDeltaEmitAt = 0;
  private lastDeltaKey = "";
  private generationStartedAt = 0;
  private sawLiveGenerating = false;

  private lastSyncedDiskSig = "";
  private lastSyncedCharAvatar = "";
  private localWriteGraceUntil = 0;
  private externalSyncPollTimer: NodeJS.Timeout | null = null;
  private externalSyncDebounceTimer: NodeJS.Timeout | null = null;
  private postLocalSnapshotTimer: NodeJS.Timeout | null = null;
  private externalSyncPendingSig = "";
  private externalSyncInFlight = false;
  private responseListenerPage: PwPage | null = null;
  private lastErrorEmitAt = 0;
  private lastErrorEmitKey = "";

  constructor(
    private readonly config: AppConfig,
    private readonly db: RelayDatabase,
    private readonly sessionManager: SessionManager
  ) {
    this.authStore = new TavernAuthStore(
      config.tavernAuthPath,
      config.relayToken,
      config.dataDir
    );
  }

  private buildStatus(): TavernStatus {
    return {
      enabled: this.config.tavernEnabled,
      ready: this.ready,
      needsLogin: this.needsLogin,
      handle: this.handle,
      publicUrl: this.config.stPublicUrl,
      currentCharacterId: this.currentCharacterId,
      currentCharacterName: this.currentCharacterName,
      currentChatFile: this.currentChatFile,
      isGenerating: this.isGenerating,
      lastError: this.lastError,
    };
  }

  private emitStatus(): void {
    this.sessionManager.emitExternal("tavern_status", "tavern", {
      status: this.buildStatus(),
    });
  }

  private emitTavernError(message: string, statusCode?: number): void {
    const clean = message.replace(/\s+/g, " ").trim().slice(0, 280);
    if (!clean || this.disposed) return;

    const now = Date.now();
    if (
      now - this.lastErrorEmitAt < 2500 &&
      (clean === this.lastErrorEmitKey || (!statusCode && this.lastErrorEmitKey.includes("(")))
    ) {
      return;
    }
    this.lastErrorEmitAt = now;
    this.lastErrorEmitKey = clean;

    if (this.isGenerating) {
      this.stopStreamPolling();
      this.isGenerating = false;
      this.sawLiveGenerating = false;
      this.generationStartedAt = 0;
      this.emitStatus();
    }

    this.sessionManager.emitExternal("tavern_error", "tavern", {
      characterId: this.currentCharacterId,
      chatFile: this.currentChatFile,
      code: statusCode ?? null,
      message: clean,
    });
  }

  private enqueue<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.queue.then(fn, fn);
    this.queue = run.then(
      () => undefined,
      () => undefined
    );
    return run;
  }

  warmup(): void {
    if (!this.config.tavernEnabled || this.disposed) return;
    void this.ensureInitialized().catch(() => {
      // Errors are captured on lastError; keep server startup resilient
    });
  }

  private async ensureInitialized(): Promise<void> {
    if (!this.config.tavernEnabled) {
      throw httpError(503, "Tavern bridge is disabled");
    }
    if (this.disposed) {
      throw httpError(503, "Tavern bridge has been disposed");
    }
    if (this.page && !this.page.isClosed() && (this.ready || this.needsLogin)) {
      return;
    }
    if (this.initPromise) {
      return this.initPromise;
    }

    this.initPromise = this.launchAndConnect()
      .catch((err) => {
        this.lastError = err instanceof Error ? err.message : String(err);
        this.ready = false;
        this.emitStatus();
        throw err;
      })
      .finally(() => {
        this.initPromise = null;
      });

    return this.initPromise;
  }

  private async launchAndConnect(): Promise<void> {
    if (!this.context) {
      fs.mkdirSync(this.config.tavernProfileDir, { recursive: true });
      const playwrightModuleName = "playwright";
      const pw = (await import(playwrightModuleName)) as PwModule;
      const createdContext = await pw.chromium.launchPersistentContext(this.config.tavernProfileDir, {
        headless: true,
        viewport: { width: 390, height: 844 },
        deviceScaleFactor: 2,
        args: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
      });
      createdContext.on("close", () => {
        if (this.context === createdContext) {
          this.context = null;
          this.page = null;
          this.ready = false;
          this.isGenerating = false;
          this.sawLiveGenerating = false;
          this.generationStartedAt = 0;
          this.stopStreamPolling();
          this.clearFinalizationTimers();
          this.stopExternalChatWatcher();
          if (!this.disposed) {
            this.emitStatus();
          }
        }
      });
      this.context = createdContext;
    }

    const existingPages = this.context.pages().filter((p) => !p.isClosed());
    this.page = existingPages[0] ?? (await this.context.newPage());

    if (this.responseListenerPage !== this.page) {
      this.responseListenerPage = this.page;
      this.page.on("response", (rawRes: unknown) => {
        const res = rawRes as PwResponse | undefined;
        if (!res || typeof res.status !== "function" || typeof res.url !== "function") return;
        const status = res.status();
        if (status < 400) return;
        const url = res.url();
        if (
          !/\/api\/backends\/[^/]+\/generate\b|\/api\/(?:google|openai|anthropic|claude|openrouter)\/|\/generate\b/i.test(
            url
          )
        ) {
          return;
        }
        void res
          .text()
          .catch(() => "")
          .then((body) => {
            this.emitTavernError(formatTavernHttpError(status, body), status);
          });
      });
    }

    try {
      await this.page.exposeFunction("__relayTavernEvent", (name: unknown, payload: unknown) => {
        this.handlePageEvent(String(name || ""), payload);
      });
    } catch {
      // Function already exposed on reused page
    }

    await this.page.goto(this.config.stUrl, { waitUntil: "domcontentloaded", timeout: 30_000 });
    await this.waitForAppOrLogin(false);
  }

  private async waitForAppOrLogin(skipAutoLogin: boolean): Promise<void> {
    const page = this.page;
    if (!page || page.isClosed()) {
      throw httpError(503, "Tavern browser page unavailable");
    }

    const markReadyAndBind = async () => {
      this.ready = true;
      this.needsLogin = false;
      this.lastError = null;
      this.loginUsers = [];
      const saved = this.authStore.loadCredentials();
      if (!this.handle && saved?.handle) {
        this.handle = saved.handle;
      }
      await this.bindPageEvents();
      await this.syncCurrentSelectionMeta();
      this.captureBaselineDiskSnapshot();
      this.startExternalChatWatcher();
      this.emitStatus();
    };

    const deadline = Date.now() + 25_000;
    let contextSeenAt: number | null = null;

    while (Date.now() < deadline) {
      const probe = await page.evaluate<{
        isLogin: boolean;
        hasContext: boolean;
        charCount: number;
        preloaderVisible: boolean;
      }>(`(() => {
        const pathname = window.location.pathname || "";
        const isLogin =
          pathname.startsWith("/login") ||
          Boolean(document.querySelector("#userList, #userHandle, #loginButton"));
        const st = window.SillyTavern;
        const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
        const hasContext = Boolean(ctx && Array.isArray(ctx.characters));
        const preloader = document.querySelector("#preloader");
        let preloaderVisible = false;
        if (preloader) {
          const style = window.getComputedStyle(preloader);
          preloaderVisible =
            style.display !== "none" &&
            style.visibility !== "hidden" &&
            Number(style.opacity || "1") > 0.05;
        }
        return {
          isLogin,
          hasContext,
          charCount: hasContext ? ctx.characters.length : 0,
          preloaderVisible,
        };
      })()`);

      if (probe.isLogin) {
        if (!skipAutoLogin) {
          const saved = this.authStore.loadCredentials();
          if (saved) {
            const ok = await this.performLoginInPage(saved.handle, saved.password).catch(
              () => ({ ok: false, error: "" })
            );
            if (ok.ok) {
              this.handle = saved.handle;
              await page.goto(this.config.stUrl, { waitUntil: "domcontentloaded", timeout: 30_000 });
              await this.waitForAppOrLogin(true);
              return;
            }
          }
        }

        this.ready = false;
        this.needsLogin = true;
        this.lastError = null;
        this.loginUsers = await this.fetchLoginUsersInPage();
        this.emitStatus();
        return;
      }

      if (probe.hasContext) {
        if (contextSeenAt === null) {
          contextSeenAt = Date.now();
        }
        const elapsedSinceContext = Date.now() - contextSeenAt;
        const settled =
          (!probe.preloaderVisible && (probe.charCount > 0 || elapsedSinceContext >= 2500)) ||
          (probe.charCount > 0 && elapsedSinceContext >= 3000) ||
          elapsedSinceContext >= 8000;

        if (settled) {
          // Short stabilization window for extensions / character list hydration
          await new Promise((r) => setTimeout(r, 500));
          await markReadyAndBind();
          return;
        }
      }

      await new Promise((r) => setTimeout(r, 250));
    }

    // Fallback: if context appeared (e.g. genuine 0-character account), proceed cleanly
    if (contextSeenAt !== null) {
      await markReadyAndBind();
      return;
    }

    throw new Error("Timed out waiting for SillyTavern UI to initialize");
  }

  private async fetchLoginUsersInPage(): Promise<TavernLoginUser[]> {
    const page = this.page;
    if (!page || page.isClosed()) return [];
    try {
      return await page.evaluate<TavernLoginUser[]>(`(async () => {
        try {
          const csrfRes = await fetch("/csrf-token");
          const csrfData = await csrfRes.json();
          const res = await fetch("/api/users/list", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-CSRF-Token": csrfData.token || "",
            },
          });
          if (!res.ok || res.status === 204) return [];
          const list = await res.json();
          if (!Array.isArray(list)) return [];
          return list
            .filter((u) => u && typeof u.handle === "string")
            .map((u) => ({
              handle: String(u.handle),
              name: String(u.name || u.handle),
            }));
        } catch {
          return [];
        }
      })()`);
    } catch {
      return [];
    }
  }

  private async performLoginInPage(
    handle: string,
    password: string
  ): Promise<{ ok: boolean; error?: string }> {
    const page = this.page;
    if (!page || page.isClosed()) {
      return { ok: false, error: "Tavern browser page unavailable" };
    }
    return page.evaluate<{ ok: boolean; error?: string }, { handle: string; password: string }>(
      async ({ handle: h, password: p }) => {
        try {
          const csrfRes = await fetch("/csrf-token");
          const csrfData = (await csrfRes.json()) as { token?: string };
          const res = await fetch("/api/users/login", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-CSRF-Token": csrfData.token || "",
            },
            body: JSON.stringify({ handle: h, password: p }),
          });
          if (!res.ok) {
            const errData = (await res.json().catch(() => ({}))) as { error?: string };
            return { ok: false, error: errData.error || `Login failed (${res.status})` };
          }
          const data = (await res.json()) as { handle?: string };
          return data.handle ? { ok: true } : { ok: false, error: "Login response missing handle" };
        } catch (err) {
          return { ok: false, error: String(err) };
        }
      },
      { handle, password }
    );
  }

  private async bindPageEvents(): Promise<void> {
    const page = this.page;
    if (!page || page.isClosed()) return;
    await page.evaluate(`(() => {
      if (window.__relayTavernBound) return;
      const st = window.SillyTavern;
      const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
      if (!ctx || !ctx.eventSource) return;
      window.__relayTavernBound = true;
      const es = ctx.eventSource;
      const et = ctx.eventTypes || ctx.event_types || {};
      const isLiveGen = () => {
        const stopEl = document.querySelector("#mes_stop");
        let stopVisible = false;
        if (stopEl) {
          const style = window.getComputedStyle(stopEl);
          stopVisible = style.display !== "none" && style.visibility !== "hidden";
        }
        return Boolean(
          stopVisible ||
          ctx.streamingProcessor ||
          document.body?.dataset?.generating === "true"
        );
      };
      const emit = (name, payload) => {
        if (typeof window.__relayTavernEvent === "function") {
          window.__relayTavernEvent(name, payload);
        }
      };
      const bind = (eventKey, fallbackName, tag) => {
        const evName = et[eventKey] || fallbackName;
        if (evName && typeof es.on === "function") {
          es.on(evName, (data) => {
            try {
              emit(tag, {
                value: typeof data === "string" || typeof data === "number" ? data : null,
                isLiveGenerating: isLiveGen(),
              });
            } catch {}
          });
        }
      };
      bind("GENERATION_STARTED", "generation_started", "GENERATION_STARTED");
      bind("STREAM_TOKEN_RECEIVED", "stream_token_received", "STREAM_TOKEN_RECEIVED");
      bind("GENERATION_ENDED", "generation_ended", "GENERATION_ENDED");
      bind("GENERATION_STOPPED", "generation_stopped", "GENERATION_STOPPED");
      bind("MESSAGE_RECEIVED", "message_received", "MESSAGE_RECEIVED");
      bind("CHARACTER_MESSAGE_RENDERED", "character_message_rendered", "CHARACTER_MESSAGE_RENDERED");
      bind("MESSAGE_SWIPED", "message_swiped", "MESSAGE_SWIPED");
      bind("CHAT_CHANGED", "chat_changed", "CHAT_CHANGED");

      const reportToastError = (node) => {
        if (!node || node.nodeType !== 1) return;
        const targets = [];
        if (node.matches && node.matches(".toast-error")) targets.push(node);
        if (node.querySelectorAll) {
          node.querySelectorAll(".toast-error").forEach((el) => targets.push(el));
        }
        for (const toast of targets) {
          const title = (toast.querySelector(".toast-title")?.textContent || "").trim();
          const body = (toast.querySelector(".toast-message")?.textContent || "").trim();
          const combined = [title, body].filter(Boolean).join("：") || (toast.textContent || "").trim();
          if (combined) emit("TOAST_ERROR", { message: combined });
        }
      };
      if (typeof MutationObserver !== "undefined" && document.body) {
        const toastObserver = new MutationObserver((mutations) => {
          for (const m of mutations) {
            for (const added of m.addedNodes) {
              if (added && added.nodeType === 1) {
                const inToast =
                  (added.closest && added.closest("#toast-container")) ||
                  (added.id === "toast-container") ||
                  (added.classList && added.classList.contains("toast-error")) ||
                  (added.querySelector && added.querySelector(".toast-error"));
                if (inToast) reportToastError(added);
              }
            }
          }
        });
        toastObserver.observe(document.body, { childList: true, subtree: true });
      }
    })()`);
  }

  private async syncCurrentSelectionMeta(): Promise<void> {
    const page = this.page;
    if (!page || page.isClosed() || !this.ready) return;
    try {
      const meta = await page.evaluate<{
        characterId: number | null;
        characterName: string | null;
        characterAvatar: string | null;
        chatFile: string | null;
        isLiveGenerating: boolean;
      }>(`(() => {
        const st = window.SillyTavern;
        const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
        if (!ctx) return { characterId: null, characterName: null, characterAvatar: null, chatFile: null, isLiveGenerating: false };
        const rawId = ctx.characterId;
        const idNum = rawId !== undefined && rawId !== null && rawId !== "" ? Number(rawId) : NaN;
        const ch = Number.isFinite(idNum) && Array.isArray(ctx.characters) ? ctx.characters[idNum] : null;
        const chatId = typeof ctx.getCurrentChatId === "function" ? ctx.getCurrentChatId() : ctx.chatId;
        const stopEl = document.querySelector("#mes_stop");
        let stopVisible = false;
        if (stopEl) {
          const style = window.getComputedStyle(stopEl);
          stopVisible = style.display !== "none" && style.visibility !== "hidden";
        }
        const isLiveGenerating = Boolean(
          stopVisible ||
          ctx.streamingProcessor ||
          document.body?.dataset?.generating === "true"
        );
        return {
          characterId: ch ? idNum : null,
          characterName: ch ? String(ch.name || "") : null,
          characterAvatar: ch && ch.avatar ? String(ch.avatar) : null,
          chatFile: chatId ? String(chatId) : (ch && ch.chat ? String(ch.chat) : null),
          isLiveGenerating,
        };
      })()`);
      this.currentCharacterId = meta.characterId;
      this.currentCharacterName = meta.characterName;
      this.currentCharacterAvatar = meta.characterAvatar;
      this.currentChatFile = meta.chatFile;
      this.reconcileLiveGenerating(meta.isLiveGenerating);
    } catch {
      // ignore transient eval error
    }
  }

  private captureBaselineDiskSnapshot(): void {
    const snap = readCharacterChatsDiskSnapshot(
      this.config.stDataDir,
      this.handle,
      this.currentCharacterAvatar
    );
    this.lastSyncedCharAvatar = this.currentCharacterAvatar ?? "";
    this.lastSyncedDiskSig = snap?.signature ?? "";
  }

  private markLocalMutationAndSnapshot(): void {
    this.localWriteGraceUntil = Date.now() + 2_500;
    this.captureBaselineDiskSnapshot();
    if (this.postLocalSnapshotTimer) {
      clearTimeout(this.postLocalSnapshotTimer);
    }
    this.postLocalSnapshotTimer = setTimeout(() => {
      this.postLocalSnapshotTimer = null;
      if (!this.disposed && this.ready) {
        this.captureBaselineDiskSnapshot();
      }
    }, 1400);
    this.postLocalSnapshotTimer.unref();
  }

  private stopExternalChatWatcher(): void {
    if (this.externalSyncPollTimer) {
      clearInterval(this.externalSyncPollTimer);
      this.externalSyncPollTimer = null;
    }
    if (this.externalSyncDebounceTimer) {
      clearTimeout(this.externalSyncDebounceTimer);
      this.externalSyncDebounceTimer = null;
    }
    if (this.postLocalSnapshotTimer) {
      clearTimeout(this.postLocalSnapshotTimer);
      this.postLocalSnapshotTimer = null;
    }
    this.externalSyncPendingSig = "";
    this.externalSyncInFlight = false;
  }

  private startExternalChatWatcher(): void {
    if (this.externalSyncPollTimer || !this.config.stDataDir || this.disposed) return;
    this.externalSyncPollTimer = setInterval(() => {
      if (
        this.disposed ||
        !this.ready ||
        this.isGenerating ||
        this.externalSyncInFlight ||
        Date.now() < this.localWriteGraceUntil ||
        this.currentCharacterId === null ||
        !this.currentCharacterAvatar
      ) {
        return;
      }
      const snap = readCharacterChatsDiskSnapshot(
        this.config.stDataDir,
        this.handle,
        this.currentCharacterAvatar
      );
      if (!snap) return;
      if (this.lastSyncedCharAvatar !== this.currentCharacterAvatar) {
        this.lastSyncedCharAvatar = this.currentCharacterAvatar;
        this.lastSyncedDiskSig = snap.signature;
        return;
      }
      if (snap.signature === this.lastSyncedDiskSig) return;
      if (snap.signature === this.externalSyncPendingSig && this.externalSyncDebounceTimer) {
        return;
      }

      this.externalSyncPendingSig = snap.signature;
      if (this.externalSyncDebounceTimer) {
        clearTimeout(this.externalSyncDebounceTimer);
      }
      this.externalSyncDebounceTimer = setTimeout(() => {
        this.externalSyncDebounceTimer = null;
        this.externalSyncPendingSig = "";
        if (this.disposed || !this.ready || this.isGenerating || this.externalSyncInFlight) return;
        this.externalSyncInFlight = true;
        void this.enqueue(async () => {
          const reloaded = await this.syncExternalChatIfStale({ allowChatSwitch: true });
          if (reloaded) {
            const state = await this.extractChatState();
            this.sessionManager.emitExternal("tavern_chat_updated", "tavern", { state });
          }
        })
          .catch(() => {})
          .finally(() => {
            this.externalSyncInFlight = false;
          });
      }, 600);
      this.externalSyncDebounceTimer.unref();
    }, 2500);
    this.externalSyncPollTimer.unref();
  }

  /**
   * Checks whether SillyTavern's backend/disk state for the active character changed externally
   * (e.g., user sent a message or created a branch in the web UI) and reloads Playwright in-place.
   * Must ONLY be called from inside `this.enqueue(...)` (never calls `enqueue` itself).
   */
  private async syncExternalChatIfStale(opts?: {
    allowChatSwitch?: boolean;
    targetChatFile?: string;
    forceCheckApi?: boolean;
  }): Promise<boolean> {
    if (
      this.disposed ||
      !this.ready ||
      !this.page ||
      this.page.isClosed() ||
      this.isGenerating ||
      this.currentCharacterId === null
    ) {
      return false;
    }

    const snap = readCharacterChatsDiskSnapshot(
      this.config.stDataDir,
      this.handle,
      this.currentCharacterAvatar
    );

    if (
      snap &&
      !opts?.forceCheckApi &&
      this.currentCharacterAvatar &&
      this.lastSyncedCharAvatar === this.currentCharacterAvatar &&
      snap.signature === this.lastSyncedDiskSig
    ) {
      return false;
    }

    const inGraceWindow = Date.now() < this.localWriteGraceUntil;

    try {
      const check = await this.page.evaluate<
        {
          ok: boolean;
          chatFileChanged: boolean;
          countChanged: boolean;
          lastTextChanged: boolean;
          targetChat: string;
        },
        {
          characterId: number;
          allowChatSwitch: boolean;
          targetChatFile?: string;
        }
      >(
        async ({ characterId, allowChatSwitch, targetChatFile }) => {
          const g = globalThis as Record<string, any>;
          const st = g.SillyTavern;
          const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
          if (!ctx || !Array.isArray(ctx.characters) || !ctx.characters[characterId]) {
            return {
              ok: false,
              chatFileChanged: false,
              countChanged: false,
              lastTextChanged: false,
              targetChat: "",
            };
          }
          const norm = (s: unknown) =>
            String(s || "")
              .trim()
              .replace(/\.jsonl$/i, "");
          const ch = ctx.characters[characterId];
          const memChat = norm(
            (typeof ctx.getCurrentChatId === "function" ? ctx.getCurrentChatId() : ctx.chatId) ||
              ch.chat ||
              ""
          );
          const memCount = Array.isArray(ctx.chat) ? ctx.chat.length : 0;
          const memLastMes = memCount > 0 ? String(ctx.chat[memCount - 1]?.mes || "") : "";

          let activeChat = memChat;
          try {
            const charRes = await fetch("/api/characters/get", {
              method: "POST",
              headers: ctx.getRequestHeaders(),
              body: JSON.stringify({ avatar_url: ch.avatar }),
            });
            if (charRes.ok) {
              const freshChar = (await charRes.json()) as Record<string, any>;
              const fetchedChat = norm(freshChar?.chat);
              if (fetchedChat) activeChat = fetchedChat;
            }
          } catch {
            // keep memChat on transient error
          }

          const requestedNorm = norm(targetChatFile);
          const resolvedTarget =
            requestedNorm || (allowChatSwitch && activeChat ? activeChat : memChat);

          let diskCount: number | null = null;
          let diskLastMes: string | null = null;
          try {
            const chatsRes = await fetch("/api/characters/chats", {
              method: "POST",
              headers: ctx.getRequestHeaders(),
              body: JSON.stringify({ avatar_url: ch.avatar }),
            });
            if (chatsRes.ok) {
              const data = (await chatsRes.json()) as Record<string, any> | Array<Record<string, any>>;
              const items = Array.isArray(data) ? data : Object.values(data || {});
              const matched = items.find((x) => x && norm(x.file_name) === resolvedTarget);
              if (matched) {
                if (matched.chat_items !== undefined && matched.chat_items !== null) {
                  const n = Number(matched.chat_items);
                  if (Number.isFinite(n)) diskCount = n;
                }
                if (typeof matched.mes === "string") {
                  diskLastMes = matched.mes;
                }
              }
            }
          } catch {
            // ignore transient /chats error
          }

          const chatFileChanged = Boolean(resolvedTarget && resolvedTarget !== memChat);
          const countChanged = diskCount !== null && diskCount !== memCount;
          let lastTextChanged = false;
          if (diskLastMes !== null) {
            const sameExact = diskLastMes === memLastMes;
            const samePrefix =
              diskLastMes.length >= 40 && memLastMes.startsWith(diskLastMes);
            lastTextChanged = !sameExact && !samePrefix;
          }

          return {
            ok: true,
            chatFileChanged,
            countChanged,
            lastTextChanged,
            targetChat: resolvedTarget,
          };
        },
        {
          characterId: this.currentCharacterId,
          allowChatSwitch: opts?.allowChatSwitch !== false,
          targetChatFile: opts?.targetChatFile,
        }
      );

      if (!check.ok) return false;

      const hasApiDiff = check.chatFileChanged || check.countChanged || check.lastTextChanged;
      if (inGraceWindow && !hasApiDiff) {
        this.captureBaselineDiskSnapshot();
        return false;
      }
      if (!snap && !hasApiDiff) {
        return false;
      }

      if (hasApiDiff || snap) {
        await this.page.evaluate<
          void,
          { characterId: number; targetChat: string; chatFileChanged: boolean }
        >(
          async ({ characterId, targetChat, chatFileChanged }) => {
            const g = globalThis as Record<string, any>;
            const st = g.SillyTavern;
            const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
            if (!ctx || !Array.isArray(ctx.characters) || !ctx.characters[characterId]) return;
            if (chatFileChanged && targetChat) {
              ctx.characters[characterId].chat = targetChat;
            }
            if (typeof ctx.reloadCurrentChat === "function") {
              await ctx.reloadCurrentChat();
            }
          },
          {
            characterId: this.currentCharacterId,
            targetChat: check.targetChat,
            chatFileChanged: check.chatFileChanged,
          }
        );

        await new Promise((r) => setTimeout(r, 350));
        await this.syncCurrentSelectionMeta();
        this.captureBaselineDiskSnapshot();
        return true;
      }

      return false;
    } catch {
      return false;
    }
  }

  private reconcileLiveGenerating(isLiveGenerating: boolean): void {
    if (isLiveGenerating) {
      this.sawLiveGenerating = true;
      return;
    }
    if (!this.isGenerating) return;
    const stale =
      this.sawLiveGenerating ||
      this.generationStartedAt === 0 ||
      Date.now() - this.generationStartedAt > 8_000;
    if (stale) {
      this.isGenerating = false;
      this.sawLiveGenerating = false;
      this.generationStartedAt = 0;
      this.stopStreamPolling();
    }
  }

  private scheduleRenderRefresh(): void {
    if (this.renderRefreshTimer) {
      clearTimeout(this.renderRefreshTimer);
    }
    this.renderRefreshTimer = setTimeout(() => {
      this.renderRefreshTimer = null;
      if (!this.disposed && !this.isGenerating && this.ready) {
        void this.extractChatState()
          .then((state) => {
            this.sessionManager.emitExternal("tavern_chat_updated", "tavern", { state });
          })
          .catch(() => {});
      }
    }, 350);
    this.renderRefreshTimer.unref();
  }

  private handlePageEvent(eventName: string, payload: unknown): void {
    if (this.disposed) return;
    const payloadObj =
      payload && typeof payload === "object" ? (payload as Record<string, unknown>) : null;
    const payloadLiveGen =
      typeof payloadObj?.isLiveGenerating === "boolean" ? payloadObj.isLiveGenerating : undefined;

    switch (eventName) {
      case "GENERATION_STARTED": {
        this.clearFinalizationTimers();
        this.isGenerating = true;
        this.generationStartedAt = Date.now();
        this.sawLiveGenerating = Boolean(payloadLiveGen);
        this.lastDeltaKey = "";
        this.emitStatus();
        this.startStreamPolling();
        break;
      }

      case "STREAM_TOKEN_RECEIVED": {
        if (!this.isGenerating) {
          this.isGenerating = true;
          this.generationStartedAt = Date.now();
          this.sawLiveGenerating = true;
          this.emitStatus();
          this.startStreamPolling();
        } else {
          this.sawLiveGenerating = true;
        }
        this.scheduleDeltaEmit();
        break;
      }

      case "GENERATION_ENDED":
      case "GENERATION_STOPPED": {
        this.stopStreamPolling();
        this.scheduleFinalization(eventName === "GENERATION_ENDED");
        break;
      }

      case "MESSAGE_RECEIVED":
      case "CHARACTER_MESSAGE_RENDERED": {
        if (payloadLiveGen === false && this.isGenerating) {
          this.stopStreamPolling();
          this.scheduleFinalization(true);
        } else if (!this.isGenerating && payloadLiveGen !== true) {
          this.scheduleRenderRefresh();
        }
        break;
      }

      case "MESSAGE_SWIPED":
      case "CHAT_CHANGED": {
        if (!this.isGenerating) {
          this.scheduleRenderRefresh();
        }
        break;
      }

      case "TOAST_ERROR": {
        const msg = typeof payloadObj?.message === "string" ? payloadObj.message : "";
        if (msg) {
          this.emitTavernError(msg);
        }
        break;
      }
    }
  }

  private startStreamPolling(): void {
    if (this.streamPollTimer) return;
    this.streamPollTimer = setInterval(() => {
      if (!this.isGenerating || this.disposed) {
        this.stopStreamPolling();
        return;
      }
      this.scheduleDeltaEmit();
    }, 100);
    this.streamPollTimer.unref();
  }

  private stopStreamPolling(): void {
    if (this.streamPollTimer) {
      clearInterval(this.streamPollTimer);
      this.streamPollTimer = null;
    }
    if (this.deltaThrottleTimer) {
      clearTimeout(this.deltaThrottleTimer);
      this.deltaThrottleTimer = null;
    }
  }

  private clearFinalizationTimers(): void {
    if (this.finalizeTimer) {
      clearTimeout(this.finalizeTimer);
      this.finalizeTimer = null;
    }
    if (this.delayedCheckTimer) {
      clearTimeout(this.delayedCheckTimer);
      this.delayedCheckTimer = null;
    }
    if (this.renderRefreshTimer) {
      clearTimeout(this.renderRefreshTimer);
      this.renderRefreshTimer = null;
    }
  }

  private scheduleDeltaEmit(): void {
    const now = Date.now();
    const elapsed = now - this.lastDeltaEmitAt;
    if (elapsed >= 65) {
      this.lastDeltaEmitAt = now;
      void this.emitCurrentStreamDelta();
      return;
    }
    if (!this.deltaThrottleTimer) {
      this.deltaThrottleTimer = setTimeout(() => {
        this.deltaThrottleTimer = null;
        this.lastDeltaEmitAt = Date.now();
        void this.emitCurrentStreamDelta();
      }, 65 - elapsed);
      this.deltaThrottleTimer.unref();
    }
  }

  private async emitCurrentStreamDelta(): Promise<void> {
    const page = this.page;
    if (!page || page.isClosed() || !this.ready || !this.isGenerating) return;
    try {
      const snap = await page.evaluate<{
        isLiveGenerating: boolean;
        mesId: number | null;
        text: string;
        reasoning: string;
      } | null>(`(() => {
        const st = window.SillyTavern;
        const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
        if (!ctx || !Array.isArray(ctx.chat)) return null;
        const stopEl = document.querySelector("#mes_stop");
        let stopVisible = false;
        if (stopEl) {
          const style = window.getComputedStyle(stopEl);
          stopVisible = style.display !== "none" && style.visibility !== "hidden";
        }
        const isLiveGenerating = Boolean(
          stopVisible ||
          ctx.streamingProcessor ||
          document.body?.dataset?.generating === "true"
        );
        if (ctx.chat.length === 0) {
          return { isLiveGenerating, mesId: null, text: "", reasoning: "" };
        }
        const sp = ctx.streamingProcessor;
        const mesId = sp && typeof sp.messageId === "number" ? sp.messageId : ctx.chat.length - 1;
        const m = ctx.chat[mesId];
        if (!m || m.is_user) {
          return { isLiveGenerating, mesId: null, text: "", reasoning: "" };
        }
        const mesEl = document.querySelector('.mes[mesid="' + mesId + '"]');
        const domReasoning = mesEl ? (mesEl.querySelector(".mes_reasoning")?.textContent || "") : "";
        const text =
          (sp && typeof sp.text === "string" && sp.text) ||
          String(m.mes || "");
        const reasoning =
          (sp && typeof sp.reasoning === "string" && sp.reasoning) ||
          (m.extra && typeof m.extra.reasoning === "string" ? m.extra.reasoning : "") ||
          domReasoning;
        return { isLiveGenerating, mesId, text, reasoning };
      })()`);

      if (!snap) return;

      if (!snap.isLiveGenerating) {
        const timedOut =
          this.generationStartedAt > 0 && Date.now() - this.generationStartedAt > 8_000;
        if (this.sawLiveGenerating || timedOut) {
          const shouldNotify = this.sawLiveGenerating;
          this.stopStreamPolling();
          this.scheduleFinalization(shouldNotify);
        }
        return;
      }

      this.sawLiveGenerating = true;
      if (snap.mesId === null) return;

      const key = `${snap.mesId}:${snap.text.length}:${snap.reasoning.length}:${snap.text.slice(-32)}`;
      if (key === this.lastDeltaKey) return;
      this.lastDeltaKey = key;

      this.sessionManager.emitExternal("tavern_stream_delta", "tavern", {
        characterId: this.currentCharacterId,
        chatFile: this.currentChatFile,
        mesId: snap.mesId,
        text: snap.text,
        reasoning: snap.reasoning,
      });
    } catch {
      // ignore transient poll failure
    }
  }

  private scheduleFinalization(notifyBark: boolean): void {
    this.clearFinalizationTimers();
    // Wait 450ms for MVU & JS-Slash-Runner scripts to finish mutating DOM/variables
    this.finalizeTimer = setTimeout(() => {
      this.finalizeTimer = null;
      void this.runFinalization(notifyBark);
    }, 450);
    this.finalizeTimer.unref();
  }

  private async runFinalization(notifyBark: boolean): Promise<void> {
    if (this.disposed || !this.ready) return;
    this.isGenerating = false;
    this.sawLiveGenerating = false;
    this.generationStartedAt = 0;
    try {
      const state = await this.extractChatState();
      const lastMsg = state.messages[state.messages.length - 1] ?? null;
      if (lastMsg) {
        lastMsg.isStreaming = false;
        this.sessionManager.emitExternal("tavern_message_finalized", "tavern", {
          characterId: state.status.currentCharacterId,
          chatFile: state.chatFile,
          message: lastMsg,
          variables: state.variables,
          isGenerating: false,
        });
      }
      this.emitStatus();
      this.markLocalMutationAndSnapshot();

      if (notifyBark && lastMsg && !lastMsg.isUser) {
        const barkUrl = this.db.getSetting("bark_url");
        if (barkUrl) {
          const preview = lastMsg.rawText.replace(/\s+/g, " ").trim().slice(0, 90) || "新回复已生成";
          void sendBarkNotification(
            barkUrl,
            `酒馆 · ${state.character?.name || lastMsg.name || "角色"}`,
            preview
          );
        }
      }

      // Re-check 1200ms later for delayed DOM/iframe scripts (MVU/JS-Slash-Runner)
      if (lastMsg) {
        const prevMesId = lastMsg.mesId;
        const prevHash = lastMsg.renderedHash;
        this.delayedCheckTimer = setTimeout(() => {
          this.delayedCheckTimer = null;
          if (this.disposed || this.isGenerating || !this.ready) return;
          void this.extractChatState()
            .then((nextState) => {
              const updated = nextState.messages.find((m) => m.mesId === prevMesId);
              if (updated && updated.renderedHash !== prevHash) {
                updated.isStreaming = false;
                this.sessionManager.emitExternal("tavern_message_finalized", "tavern", {
                  characterId: nextState.status.currentCharacterId,
                  chatFile: nextState.chatFile,
                  message: updated,
                  variables: nextState.variables,
                  isGenerating: false,
                });
              }
            })
            .catch(() => {});
        }, 1200);
        this.delayedCheckTimer.unref();
      }
    } catch {
      this.emitStatus();
    }
  }

  private async extractCharactersInternal(): Promise<TavernCharacter[]> {
    const page = this.page;
    if (!page || page.isClosed() || !this.ready) return [];
    const raw = await page.evaluate<
      Array<{
        id: number;
        name: string;
        avatar: string;
        chat: string | null;
        lastChatRaw: unknown;
        tags: string[];
        tagline: string;
      }>
    >(`(() => {
      const st = window.SillyTavern;
      const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
      if (!ctx || !Array.isArray(ctx.characters)) return [];
      const tagById = new Map();
      if (Array.isArray(ctx.tags)) {
        for (const t of ctx.tags) {
          if (t && t.id && t.name) tagById.set(String(t.id), String(t.name));
        }
      }
      const tagMap = ctx.tagMap && typeof ctx.tagMap === "object" ? ctx.tagMap : {};
      return ctx.characters.map((ch, idx) => {
        const avatar = String(ch.avatar || "");
        const tagSet = new Set();
        const mappedIds = Array.isArray(tagMap[avatar]) ? tagMap[avatar] : [];
        for (const tid of mappedIds) {
          const tn = tagById.get(String(tid));
          if (tn) tagSet.add(tn);
        }
        const embeddedTags = Array.isArray(ch.data?.tags)
          ? ch.data.tags
          : Array.isArray(ch.tags)
            ? ch.tags
            : [];
        for (const t of embeddedTags) {
          if (typeof t === "string" && t.trim()) tagSet.add(t.trim());
        }
        const rawNotes = String(
          ch.data?.creator_notes || ch.creatorcomment || ch.description || ch.first_mes || ""
        );
        const tagline = rawNotes.replace(/\\s+/g, " ").trim().slice(0, 120);
        return {
          id: idx,
          name: String(ch.name || "未命名角色"),
          avatar,
          chat: ch.chat ? String(ch.chat) : null,
          lastChatRaw: ch.date_last_chat ?? ch.last_mes ?? 0,
          tags: Array.from(tagSet).slice(0, 8),
          tagline,
        };
      });
    })()`);

    return raw
      .map((c) => ({
        id: c.id,
        name: c.name,
        avatar: c.avatar,
        avatarUrl: buildTavernAvatarUrl(c.avatar),
        chat: c.chat,
        lastChatAt: parseTimestampToMs(c.lastChatRaw),
        tags: c.tags,
        tagline: c.tagline,
      }))
      .sort((a, b) => b.lastChatAt - a.lastChatAt || a.name.localeCompare(b.name));
  }

  private async extractChatState(options?: TavernCurrentOptions): Promise<TavernChatState> {
    await this.syncCurrentSelectionMeta();
    if (!this.ready || !this.page || this.page.isClosed()) {
      return {
        status: this.buildStatus(),
        character: null,
        chatFile: null,
        userName: "User",
        messages: [],
        variables: {},
        totalMessageCount: 0,
        hasMore: false,
      };
    }

    const characters = await this.extractCharactersInternal();
    const character =
      this.currentCharacterId !== null
        ? characters.find((c) => c.id === this.currentCharacterId) ?? null
        : null;

    const extracted = await this.page.evaluate<{
      userName: string;
      messages: RawExtractedMessage[];
      variables: Record<string, unknown>;
      totalMessageCount: number;
      hasMore: boolean;
      isLiveGenerating: boolean;
    }>(
      buildExtractChatMessagesScript({
        limit: options?.limit ?? 25,
        beforeMesId: options?.beforeMesId,
      })
    );

    this.reconcileLiveGenerating(Boolean(extracted.isLiveGenerating));
    const messages = finalizeExtractedMessages(extracted.messages || []);
    return {
      status: this.buildStatus(),
      character,
      chatFile: this.currentChatFile,
      userName: extracted.userName || "User",
      messages,
      variables: extracted.variables || {},
      totalMessageCount: extracted.totalMessageCount ?? messages.length,
      hasMore: Boolean(extracted.hasMore),
    };
  }

  async getStatus(): Promise<{ status: TavernStatus; loginUsers?: TavernLoginUser[] }> {
    if (!this.config.tavernEnabled) {
      return { status: this.buildStatus() };
    }
    try {
      await this.ensureInitialized();
      if (this.ready) {
        await this.syncCurrentSelectionMeta();
      }
    } catch {
      // lastError already recorded
    }
    return {
      status: this.buildStatus(),
      ...(this.needsLogin ? { loginUsers: this.loginUsers } : {}),
    };
  }

  async login(handle: string, password: string): Promise<{ status: TavernStatus }> {
    return this.enqueue(async () => {
      const cleanHandle = String(handle || "").trim();
      if (!cleanHandle) {
        throw httpError(400, "handle is required");
      }
      await this.ensureInitialized();
      const page = this.page!;
      if (!page.url().includes("/login")) {
        await page.goto(`${this.config.stUrl}/login`, {
          waitUntil: "domcontentloaded",
          timeout: 30_000,
        });
      }
      const res = await this.performLoginInPage(cleanHandle, String(password ?? ""));
      if (!res.ok) {
        this.lastError = res.error || "Invalid credentials";
        this.emitStatus();
        throw httpError(401, this.lastError);
      }

      this.authStore.saveCredentials({ handle: cleanHandle, password: String(password ?? "") });
      this.handle = cleanHandle;
      await page.goto(this.config.stUrl, { waitUntil: "domcontentloaded", timeout: 30_000 });
      await this.waitForAppOrLogin(true);
      return { status: this.buildStatus() };
    });
  }

  async reload(): Promise<{ status: TavernStatus; characters: TavernCharacter[] }> {
    return this.enqueue(async () => {
      await this.ensureInitialized();
      const page = this.page!;
      await page.reload({ waitUntil: "domcontentloaded", timeout: 30_000 });
      await this.waitForAppOrLogin(false);
      const characters = this.ready ? await this.extractCharactersInternal() : [];
      this.markLocalMutationAndSnapshot();
      return { status: this.buildStatus(), characters };
    });
  }

  async listCharacters(): Promise<{ status: TavernStatus; characters: TavernCharacter[] }> {
    await this.ensureInitialized();
    if (this.ready && this.page && !this.page.isClosed() && !this.isGenerating) {
      await this.page
        .evaluate(`(async () => {
          const st = window.SillyTavern;
          const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
          if (!ctx || !Array.isArray(ctx.characters)) return;
          const res = await fetch("/api/characters/all", {
            method: "POST",
            headers: ctx.getRequestHeaders(),
            body: JSON.stringify({}),
          });
          if (!res.ok) return;
          const freshList = await res.json();
          if (!Array.isArray(freshList)) return;
          const byAvatar = new Map();
          for (const item of freshList) {
            if (item && item.avatar) byAvatar.set(String(item.avatar), item);
          }
          for (const ch of ctx.characters) {
            if (!ch || !ch.avatar) continue;
            const fresh = byAvatar.get(String(ch.avatar));
            if (!fresh) continue;
            if (fresh.chat) ch.chat = String(fresh.chat);
            if (fresh.date_last_chat !== undefined) ch.date_last_chat = fresh.date_last_chat;
            if (fresh.last_mes !== undefined) ch.last_mes = fresh.last_mes;
          }
        })()`)
        .catch(() => {});
    }
    const characters = this.ready ? await this.extractCharactersInternal() : [];
    return { status: this.buildStatus(), characters };
  }

  async listCharacterChats(
    characterId: number
  ): Promise<{ characterId: number; chats: TavernChatFile[] }> {
    await this.ensureInitialized();
    if (!this.ready || !this.page) {
      throw httpError(409, "Tavern is not logged in");
    }

    const rawChats = await this.page.evaluate<
      Array<{
        fileName: string;
        lastMessage: string;
        messageCount: number;
        updatedAtRaw: unknown;
        isCurrent: boolean;
      }>,
      number
    >(async (charId) => {
      const g = globalThis as Record<string, any>;
      const st = g.SillyTavern;
      const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
      if (!ctx || !Array.isArray(ctx.characters) || !ctx.characters[charId]) {
        throw new Error("Character not found");
      }
      const ch = ctx.characters[charId];
      const res = await fetch("/api/characters/chats", {
        method: "POST",
        headers: ctx.getRequestHeaders(),
        body: JSON.stringify({ avatar_url: ch.avatar }),
      });
      if (!res.ok) {
        throw new Error(`Failed to fetch chats (${res.status})`);
      }
      const data = (await res.json()) as Record<string, any> | Array<Record<string, any>>;
      const items = Array.isArray(data) ? data : Object.values(data || {});
      const currentChat = String(ch.chat || "").replace(/\.jsonl$/i, "");
      return items
        .filter((x) => x && typeof x.file_name === "string")
        .map((x) => {
          const fn = String(x.file_name);
          const clean = fn.replace(/\.jsonl$/i, "");
          return {
            fileName: fn,
            lastMessage: String(x.mes || "").replace(/\s+/g, " ").trim().slice(0, 140),
            messageCount: Number(x.chat_items || 0),
            updatedAtRaw: x.last_mes ?? 0,
            isCurrent: clean === currentChat,
          };
        });
    }, characterId);

    const chats: TavernChatFile[] = rawChats
      .map((c) => ({
        fileName: c.fileName,
        displayName: c.fileName.replace(/\.jsonl$/i, ""),
        lastMessage: c.lastMessage,
        messageCount: c.messageCount,
        updatedAt: parseTimestampToMs(c.updatedAtRaw),
        isCurrent: c.isCurrent,
      }))
      .sort((a, b) => b.updatedAt - a.updatedAt);

    return { characterId, chats };
  }

  async selectCharacter(input: TavernSelectInput): Promise<{ state: TavernChatState }> {
    return this.enqueue(async () => {
      await this.ensureInitialized();
      if (!this.ready || !this.page) {
        throw httpError(409, "Tavern is not logged in");
      }

      await this.syncCurrentSelectionMeta();

      const requestedChat = normalizeChatFileName(input.chatFile);
      const currentChat = normalizeChatFileName(this.currentChatFile);
      const hitFastPath =
        !input.createNew &&
        this.currentCharacterId === input.characterId &&
        (!requestedChat || requestedChat === currentChat);

      let externallyReloaded = false;
      if (hitFastPath) {
        externallyReloaded = await this.syncExternalChatIfStale({
          allowChatSwitch: !requestedChat,
          targetChatFile: requestedChat || undefined,
        });
      } else {
        await this.page.evaluate<
          void,
          { characterId: number; chatFile?: string; createNew?: boolean }
        >(
          async ({ characterId, chatFile, createNew }) => {
            const g = globalThis as Record<string, any>;
            const st = g.SillyTavern;
            const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
            if (!ctx || !Array.isArray(ctx.characters) || !ctx.characters[characterId]) {
              throw new Error(`Character not found: ${characterId}`);
            }
            await ctx.selectCharacterById(String(characterId));
            if (createNew) {
              await ctx.executeSlashCommandsWithOptions("/newchat");
            } else if (chatFile && chatFile.trim()) {
              const cleanName = chatFile.trim().replace(/\.jsonl$/i, "");
              await ctx.openCharacterChat(cleanName);
            }
          },
          {
            characterId: input.characterId,
            chatFile: input.chatFile,
            createNew: input.createNew,
          }
        );

        // Give ST DOM + extensions (MVU / JS-Slash-Runner) time to render the newly loaded chat
        await new Promise((r) => setTimeout(r, 350));
      }

      const fullState = await this.extractChatState();
      if (!hitFastPath) {
        this.markLocalMutationAndSnapshot();
      }
      if (!hitFastPath || externallyReloaded) {
        this.sessionManager.emitExternal("tavern_chat_updated", "tavern", { state: fullState });
      }

      const diffedState = input.createNew
        ? fullState
        : applyIncrementalChatDiff(fullState, input.knownChatFile, input.knownHashes);
      return { state: diffedState };
    });
  }

  async getCurrentState(options?: TavernCurrentOptions): Promise<{ state: TavernChatState }> {
    if (!this.config.tavernEnabled) {
      return {
        state: {
          status: this.buildStatus(),
          character: null,
          chatFile: null,
          userName: "User",
          messages: [],
          variables: {},
          totalMessageCount: 0,
          hasMore: false,
        },
      };
    }
    if (options?.beforeMesId === undefined) {
      return this.enqueue(async () => {
        await this.ensureInitialized();
        await this.syncExternalChatIfStale({ allowChatSwitch: true });
        const state = await this.extractChatState(options);
        return { state };
      });
    }
    await this.ensureInitialized();
    const state = await this.extractChatState(options);
    return { state };
  }

  async sendMessage(text: string): Promise<{ ok: true; state: TavernChatState }> {
    return this.enqueue(async () => {
      const clean = String(text || "").trim();
      if (!clean) {
        throw httpError(400, "text is required");
      }
      await this.ensureInitialized();
      if (!this.ready || !this.page) {
        throw httpError(409, "Tavern is not logged in");
      }

      await this.syncExternalChatIfStale({ allowChatSwitch: true });

      await this.page.evaluate<void, string>((msgText) => {
        const g = globalThis as Record<string, any>;
        const doc = g.document;
        const ta = doc?.querySelector("#send_textarea");
        const btn = doc?.querySelector("#send_but");
        if (!ta || !btn) {
          throw new Error("SillyTavern composer is not available");
        }
        ta.value = msgText;
        ta.dispatchEvent(new g.Event("input", { bubbles: true }));
        btn.click();
      }, clean);

      this.clearFinalizationTimers();
      this.isGenerating = true;
      this.generationStartedAt = Date.now();
      this.sawLiveGenerating = false;
      this.lastDeltaKey = "";
      this.emitStatus();
      this.startStreamPolling();

      await new Promise((r) => setTimeout(r, 180));
      const state = await this.extractChatState();
      this.markLocalMutationAndSnapshot();
      this.sessionManager.emitExternal("tavern_chat_updated", "tavern", { state });
      return { ok: true, state };
    });
  }

  async stopGeneration(): Promise<{ stopped: boolean }> {
    if (!this.ready || !this.page || this.page.isClosed()) {
      return { stopped: false };
    }
    const wasGenerating = this.isGenerating;
    const stopped = await this.page
      .evaluate<boolean>(`(() => {
        const st = window.SillyTavern;
        const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
        if (ctx && typeof ctx.stopGeneration === "function") {
          ctx.stopGeneration();
          return true;
        }
        const stopBtn = document.querySelector("#mes_stop");
        if (stopBtn) {
          stopBtn.click();
          return true;
        }
        return false;
      })()`)
      .catch(() => false);

    if (stopped || wasGenerating) {
      this.stopStreamPolling();
      this.isGenerating = false;
      this.sawLiveGenerating = false;
      this.generationStartedAt = 0;
      this.emitStatus();
    }
    return { stopped: Boolean(stopped || wasGenerating) };
  }

  async regenerate(): Promise<{ ok: true }> {
    return this.enqueue(async () => {
      await this.ensureInitialized();
      if (!this.ready || !this.page) {
        throw httpError(409, "Tavern is not logged in");
      }
      await this.syncExternalChatIfStale({ allowChatSwitch: true });
      await this.page.evaluate(`(() => {
        const st = window.SillyTavern;
        const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
        if (ctx && typeof ctx.generate === "function") {
          void ctx.generate("regenerate");
          return;
        }
        const btn = document.querySelector("#option_regenerate");
        if (btn) btn.click();
      })()`);
      this.clearFinalizationTimers();
      this.isGenerating = true;
      this.generationStartedAt = Date.now();
      this.sawLiveGenerating = false;
      this.lastDeltaKey = "";
      this.emitStatus();
      this.startStreamPolling();
      return { ok: true };
    });
  }

  async continueGeneration(): Promise<{ ok: true }> {
    return this.enqueue(async () => {
      await this.ensureInitialized();
      if (!this.ready || !this.page) {
        throw httpError(409, "Tavern is not logged in");
      }
      await this.syncExternalChatIfStale({ allowChatSwitch: true });
      await this.page.evaluate(`(() => {
        const st = window.SillyTavern;
        const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
        if (ctx && typeof ctx.generate === "function") {
          void ctx.generate("continue");
          return;
        }
        const btn = document.querySelector("#option_continue");
        if (btn) btn.click();
      })()`);
      this.clearFinalizationTimers();
      this.isGenerating = true;
      this.generationStartedAt = Date.now();
      this.sawLiveGenerating = false;
      this.lastDeltaKey = "";
      this.emitStatus();
      this.startStreamPolling();
      return { ok: true };
    });
  }

  async swipe(
    mesId: number,
    direction: TavernSwipeDirection
  ): Promise<{ message: TavernMessage | null; state: TavernChatState }> {
    return this.enqueue(async () => {
      await this.ensureInitialized();
      if (!this.ready || !this.page) {
        throw httpError(409, "Tavern is not logged in");
      }

      await this.page.evaluate<void, { mesId: number; direction: TavernSwipeDirection }>(
        async ({ mesId: targetId, direction: dir }) => {
          const g = globalThis as Record<string, any>;
          const doc = g.document;
          const st = g.SillyTavern;
          const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
          if (!ctx || !Array.isArray(ctx.chat) || !ctx.chat[targetId]) {
            throw new Error(`Message not found: ${targetId}`);
          }
          const mes = ctx.chat[targetId];
          const swipes = Array.isArray(mes.swipes) ? mes.swipes : [mes.mes];
          const curIdx = typeof mes.swipe_id === "number" ? mes.swipe_id : 0;
          const isLast = targetId === ctx.chat.length - 1;

          if (dir === "new") {
            if (!isLast) {
              throw new Error("Can only generate a new swipe for the latest message");
            }
            if (curIdx < swipes.length - 1 && ctx.swipe && typeof ctx.swipe.to === "function") {
              await ctx.swipe.to(targetId, swipes.length - 1);
            }
            if (ctx.swipe && typeof ctx.swipe.right === "function") {
              void ctx.swipe.right();
            } else {
              const btn = doc?.querySelector(`.mes[mesid="${targetId}"] .swipe_right`);
              btn?.click();
            }
            return;
          }

          if (dir === "left") {
            if (isLast && ctx.swipe && typeof ctx.swipe.left === "function") {
              await ctx.swipe.left();
            } else {
              const btn = doc?.querySelector(`.mes[mesid="${targetId}"] .swipe_left`);
              btn?.click();
            }
            return;
          }

          if (dir === "right") {
            if (isLast && ctx.swipe && typeof ctx.swipe.right === "function") {
              void ctx.swipe.right();
            } else {
              const btn = doc?.querySelector(`.mes[mesid="${targetId}"] .swipe_right`);
              btn?.click();
            }
          }
        },
        { mesId, direction }
      );

      await new Promise((r) => setTimeout(r, 280));
      const state = await this.extractChatState();
      const message = state.messages.find((m) => m.mesId === mesId) ?? null;
      this.markLocalMutationAndSnapshot();
      this.sessionManager.emitExternal("tavern_chat_updated", "tavern", { state });
      return { message, state };
    });
  }

  async editMessage(
    mesId: number,
    text: string
  ): Promise<{ message: TavernMessage | null; state: TavernChatState }> {
    return this.enqueue(async () => {
      await this.ensureInitialized();
      if (!this.ready || !this.page) {
        throw httpError(409, "Tavern is not logged in");
      }

      await this.page.evaluate<void, { mesId: number; text: string }>(
        async ({ mesId: targetId, text: nextText }) => {
          const g = globalThis as Record<string, any>;
          const st = g.SillyTavern;
          const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
          if (!ctx || !Array.isArray(ctx.chat) || !ctx.chat[targetId]) {
            throw new Error(`Message not found: ${targetId}`);
          }
          const mes = ctx.chat[targetId];
          mes.mes = nextText;
          if (Array.isArray(mes.swipes)) {
            const idx = typeof mes.swipe_id === "number" ? mes.swipe_id : 0;
            if (idx >= 0 && idx < mes.swipes.length) {
              mes.swipes[idx] = nextText;
            }
          }
          if (typeof ctx.updateMessageBlock === "function") {
            ctx.updateMessageBlock(targetId, mes);
          }
          const evType = ctx.eventTypes?.MESSAGE_EDITED || "message_edited";
          if (ctx.eventSource && typeof ctx.eventSource.emit === "function") {
            await ctx.eventSource.emit(evType, targetId);
          }
          if (typeof ctx.saveChat === "function") {
            await ctx.saveChat();
          }
        },
        { mesId, text }
      );

      await new Promise((r) => setTimeout(r, 250));
      const state = await this.extractChatState();
      const message = state.messages.find((m) => m.mesId === mesId) ?? null;
      this.markLocalMutationAndSnapshot();
      this.sessionManager.emitExternal("tavern_chat_updated", "tavern", { state });
      return { message, state };
    });
  }

  async deleteMessage(mesId: number): Promise<{ ok: true; state: TavernChatState }> {
    return this.enqueue(async () => {
      await this.ensureInitialized();
      if (!this.ready || !this.page) {
        throw httpError(409, "Tavern is not logged in");
      }

      await this.page.evaluate<void, number>(async (targetId) => {
        const g = globalThis as Record<string, any>;
        const st = g.SillyTavern;
        const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
        if (!ctx || !Array.isArray(ctx.chat) || !ctx.chat[targetId]) {
          throw new Error(`Message not found: ${targetId}`);
        }
        if (typeof ctx.deleteMessage === "function") {
          await ctx.deleteMessage(targetId);
        } else {
          ctx.chat.splice(targetId, 1);
          if (typeof ctx.saveChat === "function") {
            await ctx.saveChat();
          }
          if (typeof ctx.reloadCurrentChat === "function") {
            await ctx.reloadCurrentChat();
          }
        }
      }, mesId);

      await new Promise((r) => setTimeout(r, 250));
      const state = await this.extractChatState();
      this.markLocalMutationAndSnapshot();
      this.sessionManager.emitExternal("tavern_chat_updated", "tavern", { state });
      return { ok: true, state };
    });
  }

  async runSlash(command: string): Promise<{ ok: true; result?: string; state: TavernChatState }> {
    return this.enqueue(async () => {
      const clean = String(command || "").trim();
      if (!clean) {
        throw httpError(400, "command is required");
      }
      await this.ensureInitialized();
      if (!this.ready || !this.page) {
        throw httpError(409, "Tavern is not logged in");
      }

      const result = await this.page.evaluate<string | undefined, string>(async (cmd) => {
        const g = globalThis as Record<string, any>;
        const st = g.SillyTavern;
        const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
        if (!ctx || typeof ctx.executeSlashCommandsWithOptions !== "function") {
          throw new Error("Slash command engine is not available");
        }
        const out = await ctx.executeSlashCommandsWithOptions(cmd);
        if (out && out.pipe !== undefined && out.pipe !== null && String(out.pipe) !== "") {
          return String(out.pipe);
        }
        return undefined;
      }, clean);

      await new Promise((r) => setTimeout(r, 250));
      const state = await this.extractChatState();
      this.markLocalMutationAndSnapshot();
      this.sessionManager.emitExternal("tavern_chat_updated", "tavern", { state });
      return { ok: true, ...(result !== undefined ? { result } : {}), state };
    });
  }

  async getAssetCookieHeader(): Promise<string> {
    if (!this.context) return "";
    try {
      const cookies = await this.context.cookies(this.config.stUrl);
      return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
    } catch {
      return "";
    }
  }

  async dispose(): Promise<void> {
    this.disposed = true;
    this.stopStreamPolling();
    this.clearFinalizationTimers();
    this.stopExternalChatWatcher();
    const ctx = this.context;
    this.context = null;
    this.page = null;
    this.ready = false;
    if (ctx) {
      try {
        await ctx.close();
      } catch {
        // ignore close failure
      }
    }
  }
}

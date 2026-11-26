export interface PwCookie {
  name: string;
  value: string;
}

export interface PwResponse {
  url(): string;
  status(): number;
  headers(): Record<string, string>;
  text(): Promise<string>;
}

export interface PwPage {
  url(): string;
  goto(url: string, opts?: { waitUntil?: string; timeout?: number }): Promise<unknown>;
  reload(opts?: { waitUntil?: string; timeout?: number }): Promise<unknown>;
  evaluate<R = unknown, A = unknown>(fn: string | ((arg: A) => R | Promise<R>), arg?: A): Promise<R>;
  exposeFunction(name: string, fn: (...args: unknown[]) => unknown): Promise<void>;
  isClosed(): boolean;
  on(event: string, listener: (...args: unknown[]) => void): void;
}

export interface PwBrowserContext {
  pages(): PwPage[];
  newPage(): Promise<PwPage>;
  cookies(urls?: string | string[]): Promise<PwCookie[]>;
  on(event: string, listener: (...args: unknown[]) => void): void;
  close(): Promise<void>;
}

export interface PwModule {
  chromium: {
    launchPersistentContext(
      userDataDir: string,
      options: Record<string, unknown>
    ): Promise<PwBrowserContext>;
  };
}

export function parseTimestampToMs(raw: unknown): number {
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

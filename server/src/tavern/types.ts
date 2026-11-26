export type TavernErrorKind =
  | "rate_limit"
  | "safety"
  | "auth"
  | "server"
  | "network"
  | "unknown";

export interface TavernGenerationError {
  id: string;
  characterId: number | null;
  characterName: string | null;
  chatFile: string | null;
  code: number | null;
  kind: TavernErrorKind;
  message: string;
  occurredAt: number;
}

export interface TavernStatus {
  enabled: boolean;
  ready: boolean;
  needsLogin: boolean;
  handle: string | null;
  publicUrl: string;
  currentCharacterId: number | null;
  currentCharacterName: string | null;
  currentChatFile: string | null;
  isGenerating: boolean;
  lastError: string | null;
  lastGenerationError?: TavernGenerationError | null;
}

export interface TavernLoginUser {
  handle: string;
  name: string;
}

export interface TavernCharacter {
  id: number;
  name: string;
  avatar: string;
  avatarUrl: string;
  chat: string | null;
  lastChatAt: number;
  tags: string[];
  tagline: string;
}

export interface TavernChatFile {
  fileName: string;
  displayName: string;
  lastMessage: string;
  messageCount: number;
  updatedAt: number;
  isCurrent: boolean;
}

export type TavernRenderBlockKind = "markdown" | "html" | "iframe" | "image" | "details";

export interface TavernRenderBlock {
  id: string;
  kind: TavernRenderBlockKind;
  markdown?: string;
  summary?: string;
  html?: string;
  imageUrl?: string;
  imageAlt?: string;
  estimatedHeight?: number;
}

export interface TavernMessage {
  mesId: number;
  name: string;
  avatarUrl: string | null;
  isUser: boolean;
  isSystem: boolean;
  sendDate: string;
  rawText: string;
  reasoning: string;
  swipeId: number;
  swipeCount: number;
  blocks: TavernRenderBlock[];
  renderedHash: string;
  isStreaming: boolean;
  mvuData?: Record<string, unknown> | null;
}

export interface TavernChatState {
  status: TavernStatus;
  character: TavernCharacter | null;
  chatFile: string | null;
  userName: string;
  messages: TavernMessage[];
  variables: Record<string, unknown>;
  totalMessageCount?: number;
  hasMore?: boolean;
  unchangedMesIds?: number[];
}

export interface TavernSelectInput {
  characterId: number;
  chatFile?: string;
  createNew?: boolean;
  knownChatFile?: string;
  knownHashes?: Record<string, string>;
}

export interface TavernCurrentOptions {
  limit?: number;
  beforeMesId?: number;
}

export type TavernSwipeDirection = "left" | "right" | "new";

export interface TavernBridgeLike {
  getStatus(): Promise<{ status: TavernStatus; loginUsers?: TavernLoginUser[] }>;
  login(handle: string, password: string): Promise<{ status: TavernStatus }>;
  reload(): Promise<{ status: TavernStatus; characters: TavernCharacter[] }>;
  listCharacters(): Promise<{ status: TavernStatus; characters: TavernCharacter[] }>;
  listCharacterChats(characterId: number): Promise<{ characterId: number; chats: TavernChatFile[] }>;
  selectCharacter(input: TavernSelectInput): Promise<{ state: TavernChatState }>;
  getCurrentState(options?: TavernCurrentOptions): Promise<{ state: TavernChatState }>;
  sendMessage(text: string): Promise<{ ok: true; state: TavernChatState }>;
  stopGeneration(): Promise<{ stopped: boolean }>;
  regenerate(): Promise<{ ok: true }>;
  continueGeneration(): Promise<{ ok: true }>;
  swipe(
    mesId: number,
    direction: TavernSwipeDirection
  ): Promise<{ message: TavernMessage | null; state: TavernChatState }>;
  editMessage(
    mesId: number,
    text: string
  ): Promise<{ message: TavernMessage | null; state: TavernChatState }>;
  deleteMessage(mesId: number): Promise<{ ok: true; state: TavernChatState }>;
  runSlash(command: string): Promise<{ ok: true; result?: string; state: TavernChatState }>;
  clearGenerationError(): { ok: true; status: TavernStatus };
  getAssetCookieHeader(): Promise<string>;
  dispose(): Promise<void>;
}

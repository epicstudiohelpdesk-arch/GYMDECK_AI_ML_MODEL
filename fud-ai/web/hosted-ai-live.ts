/**
 * Fud AI hosted voice assistant: a metered WebSocket relay between the apps
 * and Gemini Live for Plus/Pro subscribers (`GET /api/hosted-ai/v1/live`).
 * Contract: shared/voice-assistant/README.md ("Hosted relay"). Operations and
 * design notes: services/hosted-ai/README.md.
 *
 * hosted-ai-api.ts runs the identity, rate-limit, plan and balance checks and
 * opens the upstream socket before the upgrade. This module runs the session:
 *
 *   - The first client message must be `setup`. It is rebuilt from an
 *     allow-list (model pinned server-side, function declarations only,
 *     bounded instructions and tools), so a subscriber cannot turn the relay
 *     into a general-purpose Gemini Live key.
 *   - Later client messages may only be `realtimeInput`, `clientContent` or
 *     `toolResponse`, ≤ 1 MiB each. File references are refused and the input
 *     rate is bounded, so what a block costs upstream stays close to real-time
 *     voice. Every client message is parsed once to check this; nothing else
 *     is inspected.
 *   - Metering is time-based: 15-second blocks, each charged when it starts,
 *     from `setupComplete` until close. Client input is held, not forwarded,
 *     until the first block is paid.
 *   - Server messages keep their frame type. Resumption handles are signed
 *     for this subscriber; other frames pass through unchanged. Nothing a user says, shows or receives is
 *     stored; logs carry structured codes and a hashed user id prefix only.
 */

import {
  VOICE_BLOCK_SECONDS,
  spendVoiceBlock,
  voiceBlocksRemaining,
  type LedgerContext,
  type LedgerRow,
  type VoiceSpendOutcome,
} from "./hosted-ai-ledger";
import { MAX_RESUMPTION_TOKEN_CHARS, type LiveResumptionCodec } from "./hosted-ai-live-resumption";

export const DEFAULT_LIVE_MODEL = "gemini-3.8-live";

export const LIVE_LIMITS = {
  /** Largest client frame, setup included ("≤ 1 MB" in the contract). */
  maxMessageBytes: 1024 * 1024,
  maxSystemInstructionChars: 60_000,
  maxSystemInstructionParts: 32,
  maxFunctionDeclarations: 64,
  /** Serialized `tools` after sanitizing, in UTF-8 bytes. */
  maxToolsBytes: 64 * 1024,
  maxFunctionNameChars: 64,
  maxFunctionDescriptionChars: 4_096,
  maxJsonDepth: 12,
  maxLanguageCodes: 8,
  maxResumptionHandleChars: MAX_RESUMPTION_TOKEN_CHARS,
  maxActivityTimingMs: 60_000,
  maxContextTokens: 100_000_000,
  /** Metered length of one session; the block that would start here closes with 4408 instead. */
  sessionSeconds: 15 * 60,
  /** `secondsRemaining` goes out after setup and then every this many blocks (60 s). */
  secondsRemainingEveryBlocks: 4,
  /** The unmetered phases are bounded: setup must arrive, and be answered, in time. */
  setupTimeoutMs: 10_000,
  setupCompleteTimeoutMs: 15_000,
  /** Close instead of serving an unbounded session while D1 is stalled. */
  chargeTimeoutMs: 5_000,
  /** Client input sent before the first block is paid is held up to this size. */
  maxPendingClientBytes: 2 * 1024 * 1024,
  /** Provider output held while the first block is paid has its own byte cap. */
  maxPendingUpstreamBytes: 2 * 1024 * 1024,
  /**
   * Abuse guards, about 3× what the apps send (16 kHz PCM plus at most one
   * ≤ 768 px JPEG a second); legitimate sessions never reach them.
   */
  inputBytesPerSecond: 1024 * 1024,
  inputBurstBytes: 4 * 1024 * 1024,
  videoFramesPerSecond: 2,
  videoFrameBurst: 10,
} as const;

export const LIVE_CLOSE_CODES = {
  normal: 1000,
  policy: 1008,
  upstreamFailure: 1011,
  quotaExceeded: 4402,
  sessionLimit: 4408,
} as const;

/** Backoff between attempts to charge a block after D1 rejected the write. */
const CHARGE_RETRY_DELAYS_MS: readonly number[] = [250, 1_000];

const FUNCTION_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_.-]{0,63}$/;
const VOICE_NAME_PATTERN = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
const LANGUAGE_CODE_PATTERN = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}$/;
const ENUM_NAME_PATTERN = /^[A-Z][A-Z0-9_]{0,63}$/;
const INT64_STRING_PATTERN = /^[0-9]{1,12}$/;
const LIVE_MODEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

const SETUP_KEYS = [
  "model",
  "generationConfig",
  "systemInstruction",
  "tools",
  "inputAudioTranscription",
  "outputAudioTranscription",
  "contextWindowCompression",
  "sessionResumption",
  "realtimeInputConfig",
] as const;

const CLIENT_MESSAGE_TYPES: ReadonlySet<string> = new Set(["realtimeInput", "clientContent", "toolResponse"]);

/** Keys refused anywhere inside `clientContent` / `toolResponse`: they make Gemini fetch content by reference. */
const FORBIDDEN_CONTENT_KEYS: ReadonlySet<string> = new Set(["fileData"]);

type JsonObject = Record<string, unknown>;
type Frame = string | ArrayBuffer;

export type LiveSetupResult = { ok: true; message: string } | { ok: false; error: string };
export type LiveClientInspection = { ok: true; videoFrames: number } | { ok: false; error: string };

/** Normalizes the configured model (`HOSTED_AI_LIVE_MODEL`); null when it is not a plain model id. */
export function resolveLiveModel(configured: string | undefined): string | null {
  const value = configured?.trim() || DEFAULT_LIVE_MODEL;
  const name = value.startsWith("models/") ? value.slice("models/".length) : value;
  return LIVE_MODEL_PATTERN.test(name) ? name : null;
}

// MARK: Setup allow-list

class LiveRejectError extends Error {}

function reject(path: string, reason: string): never {
  throw new LiveRejectError(`${reason}:${path}`);
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function assertObject(value: unknown, path: string): JsonObject {
  if (!isObject(value)) reject(path, "invalid_type");
  return value;
}

function assertOnlyKeys(value: JsonObject, allowed: readonly string[], path: string): void {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) reject(`${path}.${key}`, "unsupported_field");
  }
}

function requireString(value: unknown, path: string, maxChars: number): string {
  if (typeof value !== "string") reject(path, "invalid_type");
  if (value.length > maxChars) reject(path, "too_long");
  return value;
}

function requireMatch(value: unknown, path: string, maxChars: number, pattern: RegExp): string {
  const text = requireString(value, path, maxChars);
  if (!pattern.test(text)) reject(path, "invalid_value");
  return text;
}

function requireBoolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") reject(path, "invalid_type");
  return value;
}

function requireInteger(value: unknown, path: string, max: number): number {
  if (typeof value !== "number" || !Number.isInteger(value)) reject(path, "invalid_type");
  if (value < 0 || value > max) reject(path, "out_of_range");
  return value;
}

/** Proto3 JSON writes int64 as a number or a decimal string; both are accepted and forwarded as given. */
function requireTokenCount(value: unknown, path: string): number | string {
  if (typeof value === "string") {
    if (!INT64_STRING_PATTERN.test(value)) reject(path, "invalid_type");
    if (Number(value) > LIVE_LIMITS.maxContextTokens) reject(path, "out_of_range");
    return value;
  }
  return requireInteger(value, path, LIVE_LIMITS.maxContextTokens);
}

function jsonDepth(value: unknown, depth = 0): number {
  if (depth > LIVE_LIMITS.maxJsonDepth) return depth;
  if (Array.isArray(value)) {
    return value.reduce<number>((max, item) => Math.max(max, jsonDepth(item, depth + 1)), depth);
  }
  if (isObject(value)) {
    return Object.values(value).reduce<number>((max, item) => Math.max(max, jsonDepth(item, depth + 1)), depth);
  }
  return depth;
}

export function utf8ByteLength(text: string): number {
  let bytes = 0;
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        index += 1;
      } else {
        bytes += 3;
      }
    } else bytes += 3;
  }
  return bytes;
}

function sanitizeGenerationConfig(value: unknown): JsonObject {
  const path = "setup.generationConfig";
  const input = assertObject(value, path);
  assertOnlyKeys(input, ["responseModalities", "speechConfig"], path);
  const config: JsonObject = {};
  if (input.responseModalities !== undefined) {
    const modalitiesPath = `${path}.responseModalities`;
    const modalities = input.responseModalities;
    if (!Array.isArray(modalities) || modalities.length === 0) reject(modalitiesPath, "invalid_type");
    if (modalities.length > 2) reject(modalitiesPath, "too_many");
    const seen = new Set<string>();
    config.responseModalities = modalities.map((modality, index) => {
      if (modality !== "AUDIO" && modality !== "TEXT") reject(`${modalitiesPath}[${index}]`, "unsupported_value");
      if (seen.has(modality)) reject(`${modalitiesPath}[${index}]`, "duplicate");
      seen.add(modality);
      return modality;
    });
  }
  if (input.speechConfig !== undefined) {
    const speechPath = `${path}.speechConfig`;
    const speech = assertObject(input.speechConfig, speechPath);
    assertOnlyKeys(speech, ["voiceConfig", "languageCode"], speechPath);
    const speechConfig: JsonObject = {};
    if (speech.voiceConfig !== undefined) {
      const voicePath = `${speechPath}.voiceConfig`;
      const voice = assertObject(speech.voiceConfig, voicePath);
      assertOnlyKeys(voice, ["prebuiltVoiceConfig"], voicePath);
      const voiceConfig: JsonObject = {};
      if (voice.prebuiltVoiceConfig !== undefined) {
        const prebuiltPath = `${voicePath}.prebuiltVoiceConfig`;
        const prebuilt = assertObject(voice.prebuiltVoiceConfig, prebuiltPath);
        assertOnlyKeys(prebuilt, ["voiceName"], prebuiltPath);
        voiceConfig.prebuiltVoiceConfig = {
          voiceName: requireMatch(prebuilt.voiceName, `${prebuiltPath}.voiceName`, 64, VOICE_NAME_PATTERN),
        };
      }
      speechConfig.voiceConfig = voiceConfig;
    }
    if (speech.languageCode !== undefined) {
      speechConfig.languageCode = requireMatch(
        speech.languageCode,
        `${speechPath}.languageCode`,
        35,
        LANGUAGE_CODE_PATTERN
      );
    }
    config.speechConfig = speechConfig;
  }
  return config;
}

function sanitizeSystemInstruction(value: unknown): JsonObject {
  const path = "setup.systemInstruction";
  const input = assertObject(value, path);
  assertOnlyKeys(input, ["role", "parts"], path);
  // Gemini ignores the role of a system instruction; it is accepted and dropped.
  if (input.role !== undefined) requireString(input.role, `${path}.role`, 16);
  const parts = input.parts;
  if (!Array.isArray(parts) || parts.length === 0) reject(`${path}.parts`, "invalid_type");
  if (parts.length > LIVE_LIMITS.maxSystemInstructionParts) reject(`${path}.parts`, "too_many");
  let chars = 0;
  return {
    parts: parts.map((part, index) => {
      const partPath = `${path}.parts[${index}]`;
      const partObject = assertObject(part, partPath);
      assertOnlyKeys(partObject, ["text"], partPath);
      const text = requireString(partObject.text, `${partPath}.text`, LIVE_LIMITS.maxSystemInstructionChars);
      chars += text.length;
      if (chars > LIVE_LIMITS.maxSystemInstructionChars) reject(path, "too_long");
      return { text };
    }),
  };
}

function sanitizeFunctionDeclaration(value: unknown, path: string, seen: Set<string>): JsonObject {
  const input = assertObject(value, path);
  assertOnlyKeys(input, ["name", "description", "parameters", "behavior"], path);
  const name = requireString(input.name, `${path}.name`, LIVE_LIMITS.maxFunctionNameChars);
  if (!FUNCTION_NAME_PATTERN.test(name)) reject(`${path}.name`, "invalid_function_name");
  if (seen.has(name)) reject(`${path}.name`, "duplicate_function_name");
  seen.add(name);
  const declaration: JsonObject = { name };
  if (input.description !== undefined) {
    declaration.description = requireString(
      input.description,
      `${path}.description`,
      LIVE_LIMITS.maxFunctionDescriptionChars
    );
  }
  if (input.parameters !== undefined) {
    const parameters = assertObject(input.parameters, `${path}.parameters`);
    if (jsonDepth(parameters) > LIVE_LIMITS.maxJsonDepth) reject(`${path}.parameters`, "too_deep");
    const serialized = JSON.stringify(parameters);
    if (serialized.length > LIVE_LIMITS.maxToolsBytes) reject(`${path}.parameters`, "too_long");
    declaration.parameters = JSON.parse(serialized) as JsonObject;
  }
  if (input.behavior !== undefined) {
    if (input.behavior !== "BLOCKING" && input.behavior !== "NON_BLOCKING") {
      reject(`${path}.behavior`, "unsupported_value");
    }
    declaration.behavior = input.behavior;
  }
  return declaration;
}

function sanitizeTools(value: unknown): JsonObject[] {
  const path = "setup.tools";
  if (!Array.isArray(value)) reject(path, "invalid_type");
  if (value.length > LIVE_LIMITS.maxFunctionDeclarations) reject(path, "too_many");
  const seen = new Set<string>();
  let declarations = 0;
  const tools = value.map((tool, index) => {
    const toolPath = `${path}[${index}]`;
    const toolObject = assertObject(tool, toolPath);
    // Function declarations only: googleSearch, codeExecution, urlContext, … are refused here.
    assertOnlyKeys(toolObject, ["functionDeclarations"], toolPath);
    const list = toolObject.functionDeclarations;
    if (!Array.isArray(list)) reject(`${toolPath}.functionDeclarations`, "invalid_type");
    if (list.length === 0) reject(`${toolPath}.functionDeclarations`, "empty");
    declarations += list.length;
    if (declarations > LIVE_LIMITS.maxFunctionDeclarations) reject(path, "too_many_function_declarations");
    return {
      functionDeclarations: list.map((declaration, declarationIndex) =>
        sanitizeFunctionDeclaration(declaration, `${toolPath}.functionDeclarations[${declarationIndex}]`, seen)
      ),
    };
  });
  if (utf8ByteLength(JSON.stringify(tools)) > LIVE_LIMITS.maxToolsBytes) reject(path, "too_large");
  return tools;
}

function sanitizeTranscription(value: unknown, path: string): JsonObject {
  const input = assertObject(value, path);
  assertOnlyKeys(input, ["languageCodes"], path);
  const config: JsonObject = {};
  if (input.languageCodes !== undefined) {
    const codes = input.languageCodes;
    if (!Array.isArray(codes)) reject(`${path}.languageCodes`, "invalid_type");
    if (codes.length > LIVE_LIMITS.maxLanguageCodes) reject(`${path}.languageCodes`, "too_many");
    config.languageCodes = codes.map((code, index) =>
      requireMatch(code, `${path}.languageCodes[${index}]`, 35, LANGUAGE_CODE_PATTERN)
    );
  }
  return config;
}

function sanitizeContextWindowCompression(value: unknown): JsonObject {
  const path = "setup.contextWindowCompression";
  const input = assertObject(value, path);
  assertOnlyKeys(input, ["triggerTokens", "slidingWindow"], path);
  const config: JsonObject = {};
  if (input.triggerTokens !== undefined) config.triggerTokens = requireTokenCount(input.triggerTokens, `${path}.triggerTokens`);
  if (input.slidingWindow !== undefined) {
    const windowPath = `${path}.slidingWindow`;
    const window = assertObject(input.slidingWindow, windowPath);
    assertOnlyKeys(window, ["targetTokens"], windowPath);
    const slidingWindow: JsonObject = {};
    if (window.targetTokens !== undefined) {
      slidingWindow.targetTokens = requireTokenCount(window.targetTokens, `${windowPath}.targetTokens`);
    }
    config.slidingWindow = slidingWindow;
  }
  return config;
}

function sanitizeSessionResumption(value: unknown): JsonObject {
  const path = "setup.sessionResumption";
  const input = assertObject(value, path);
  assertOnlyKeys(input, ["handle"], path);
  const config: JsonObject = {};
  if (input.handle !== undefined) {
    config.handle = requireString(input.handle, `${path}.handle`, LIVE_LIMITS.maxResumptionHandleChars);
  }
  return config;
}

function sanitizeRealtimeInputConfig(value: unknown): JsonObject {
  const path = "setup.realtimeInputConfig";
  const input = assertObject(value, path);
  assertOnlyKeys(input, ["automaticActivityDetection", "activityHandling", "turnCoverage"], path);
  const config: JsonObject = {};
  if (input.automaticActivityDetection !== undefined) {
    const detectionPath = `${path}.automaticActivityDetection`;
    const detection = assertObject(input.automaticActivityDetection, detectionPath);
    assertOnlyKeys(
      detection,
      ["disabled", "startOfSpeechSensitivity", "endOfSpeechSensitivity", "prefixPaddingMs", "silenceDurationMs"],
      detectionPath
    );
    const sanitized: JsonObject = {};
    if (detection.disabled !== undefined) sanitized.disabled = requireBoolean(detection.disabled, `${detectionPath}.disabled`);
    for (const key of ["startOfSpeechSensitivity", "endOfSpeechSensitivity"] as const) {
      if (detection[key] !== undefined) {
        sanitized[key] = requireMatch(detection[key], `${detectionPath}.${key}`, 64, ENUM_NAME_PATTERN);
      }
    }
    for (const key of ["prefixPaddingMs", "silenceDurationMs"] as const) {
      if (detection[key] !== undefined) {
        sanitized[key] = requireInteger(detection[key], `${detectionPath}.${key}`, LIVE_LIMITS.maxActivityTimingMs);
      }
    }
    config.automaticActivityDetection = sanitized;
  }
  for (const key of ["activityHandling", "turnCoverage"] as const) {
    if (input[key] !== undefined) config[key] = requireMatch(input[key], `${path}.${key}`, 64, ENUM_NAME_PATTERN);
  }
  return config;
}

/**
 * Validates the client's first message and returns the serialized `setup`
 * the Worker sends upstream: rebuilt from scratch with only the fields in the
 * contract, `model` replaced by `models/<model>`. Rejections read
 * `<reason>:<json.path>`, like the `/gemini` allow-list.
 */
export function sanitizeLiveSetup(input: unknown, model: string): LiveSetupResult {
  try {
    if (!isObject(input)) reject("message", "invalid_type");
    const keys = Object.keys(input);
    if (keys.length !== 1 || keys[0] !== "setup") reject("message", "setup_required");
    const setup = assertObject(input.setup, "setup");
    assertOnlyKeys(setup, SETUP_KEYS, "setup");

    // The client's `model` is accepted and ignored: hosted sessions always use the Worker's model.
    const rebuilt: JsonObject = { model: `models/${model}` };
    if (setup.generationConfig !== undefined) rebuilt.generationConfig = sanitizeGenerationConfig(setup.generationConfig);
    if (setup.systemInstruction !== undefined) {
      rebuilt.systemInstruction = sanitizeSystemInstruction(setup.systemInstruction);
    }
    if (setup.tools !== undefined) rebuilt.tools = sanitizeTools(setup.tools);
    for (const key of ["inputAudioTranscription", "outputAudioTranscription"] as const) {
      if (setup[key] !== undefined) rebuilt[key] = sanitizeTranscription(setup[key], `setup.${key}`);
    }
    if (setup.contextWindowCompression !== undefined) {
      rebuilt.contextWindowCompression = sanitizeContextWindowCompression(setup.contextWindowCompression);
    }
    if (setup.sessionResumption !== undefined) rebuilt.sessionResumption = sanitizeSessionResumption(setup.sessionResumption);
    if (setup.realtimeInputConfig !== undefined) {
      rebuilt.realtimeInputConfig = sanitizeRealtimeInputConfig(setup.realtimeInputConfig);
    }
    return { ok: true, message: JSON.stringify({ setup: rebuilt }) };
  } catch (error) {
    if (error instanceof LiveRejectError) return { ok: false, error: error.message };
    throw error;
  }
}

// MARK: Later client messages

function findForbiddenKey(value: unknown, path: string, depth: number): string | null {
  if (depth > 64) return `too_deep:${path}`;
  if (Array.isArray(value)) {
    for (const [index, item] of value.entries()) {
      const found = findForbiddenKey(item, `${path}[${index}]`, depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (!isObject(value)) return null;
  for (const [key, item] of Object.entries(value)) {
    if (FORBIDDEN_CONTENT_KEYS.has(key)) return `unsupported_field:${path}.${key}`;
    const found = findForbiddenKey(item, `${path}.${key}`, depth + 1);
    if (found) return found;
  }
  return null;
}

function countVideoFrames(input: JsonObject): number {
  let frames = input.video === undefined ? 0 : 1;
  // `mediaChunks` is the deprecated pre-`audio`/`video` field; non-audio chunks are frames.
  const chunks = input.mediaChunks;
  if (Array.isArray(chunks)) {
    for (const chunk of chunks) {
      const mimeType = isObject(chunk) ? chunk.mimeType : undefined;
      if (typeof mimeType !== "string" || !mimeType.startsWith("audio/")) frames += 1;
    }
  }
  return frames;
}

/**
 * Checks a parsed client message after `setup`: exactly one of
 * `realtimeInput`, `clientContent` or `toolResponse`, holding an object.
 * `realtimeInput` (the audio stream) is not inspected further; the rarer
 * `clientContent` / `toolResponse` are scanned for file references.
 */
export function inspectLiveClientMessage(message: unknown): LiveClientInspection {
  if (!isObject(message)) return { ok: false, error: "invalid_type:message" };
  const keys = Object.keys(message);
  if (keys.length !== 1) return { ok: false, error: "one_message_type_required:message" };
  const type = keys[0]!;
  if (!CLIENT_MESSAGE_TYPES.has(type)) return { ok: false, error: `unsupported_message:${type}` };
  const body = message[type];
  if (!isObject(body)) return { ok: false, error: `invalid_type:${type}` };
  if (type === "realtimeInput") return { ok: true, videoFrames: countVideoFrames(body) };
  const forbidden = findForbiddenKey(body, type, 0);
  return forbidden ? { ok: false, error: forbidden } : { ok: true, videoFrames: 0 };
}

// `ignoreBOM: true` keeps a byte-order mark in the text, so JSON.parse rejects
// it: what is forwarded upstream is always exactly what was validated.
const strictUtf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const lenientUtf8 = new TextDecoder();

type ParsedFrame = { ok: true; value: unknown } | { ok: false; error: string };

/** Client frames may be text or binary; binary must be valid UTF-8 JSON. */
function parseClientFrame(frame: Frame): ParsedFrame {
  let text: string;
  if (typeof frame === "string") {
    text = frame;
  } else {
    try {
      text = strictUtf8.decode(frame);
    } catch {
      return { ok: false, error: "invalid_utf8:message" };
    }
  }
  try {
    return { ok: true, value: JSON.parse(text) as unknown };
  } catch {
    return { ok: false, error: "invalid_json:message" };
  }
}

function isSetupComplete(frame: Frame): boolean {
  const text = typeof frame === "string" ? frame : lenientUtf8.decode(frame);
  if (!text.includes("setupComplete")) return false;
  try {
    const parsed = JSON.parse(text) as unknown;
    return isObject(parsed) && parsed.setupComplete !== undefined;
  } catch {
    return false;
  }
}

/** Exact UTF-8 size for both the per-frame limit and the shared byte budget. */
function frameBytes(frame: Frame): number {
  if (typeof frame !== "string") return frame.byteLength;
  return utf8ByteLength(frame);
}

function isFrame(value: unknown): value is Frame {
  return typeof value === "string" || value instanceof ArrayBuffer;
}

/** Keeps client-chosen key names in rejection details short and log-safe. */
function safeDetail(detail: string): string {
  return detail.replace(/[^A-Za-z0-9_.:[\]-]/g, "").slice(0, 160);
}

function fudVoice(payload: Record<string, unknown>): string {
  return JSON.stringify({ fudVoice: payload });
}

function trySend(socket: WebSocket, frame: Frame): boolean {
  try {
    socket.send(frame);
    return true;
  } catch {
    return false;
  }
}

function tryClose(socket: WebSocket, code: number, reason: string): void {
  try {
    socket.close(code, reason);
  } catch {
    // Already closed.
  }
}

class TokenBucket {
  private tokens: number;
  private updatedAt: number;

  constructor(
    private readonly capacity: number,
    private readonly perSecond: number,
    now: number
  ) {
    this.tokens = capacity;
    this.updatedAt = now;
  }

  take(amount: number, now: number): boolean {
    const elapsedMs = Math.max(0, now - this.updatedAt);
    this.tokens = Math.min(this.capacity, this.tokens + (elapsedMs / 1000) * this.perSecond);
    this.updatedAt = now;
    if (amount > this.tokens) return false;
    this.tokens -= amount;
    return true;
  }
}

// MARK: Relay session

export interface LiveRelayOptions {
  /** The Worker's end of the WebSocketPair; the app holds the other end. */
  client: WebSocket;
  /** The Gemini Live socket, already connected. */
  upstream: WebSocket;
  model: string;
  ledger: LedgerContext;
  userIdHash: string;
  /** Ledger row whose plan and balance were verified before the upgrade. */
  row: LedgerRow;
  /** Milliseconds since the epoch. */
  clock: () => number;
  setTimer: (callback: () => void, ms: number) => () => void;
  sleep: (ms: number) => Promise<void>;
  /** Keeps a block charge that is in flight when the client disconnects from being cancelled. */
  waitUntil?: (promise: Promise<unknown>) => void;
  log: (event: Record<string, unknown>) => void;
  /** Scrubs configured secrets out of error text before it is logged. */
  redact: (text: string) => string;
  /** `X-Fud-Platform`, for logs only. */
  platform: string;
  resumption: LiveResumptionCodec;
}

export type LiveRelayPhase = "awaiting_setup" | "validating_setup" | "awaiting_setup_complete" | "starting" | "live" | "closed";

/**
 * One relayed conversation. Phases:
 *
 *   awaiting_setup ─setup─▶ awaiting_setup_complete ─setupComplete─▶ starting ─block 0 paid─▶ live ─▶ closed
 *
 * Every Worker-initiated close is preceded by `{"fudVoice":{"error":…}}`.
 */
export class LiveRelaySession {
  private phase: LiveRelayPhase = "awaiting_setup";
  private row: LedgerRow;
  private meterStartMs = 0;
  private blocks = 0;
  private cancelTimer: (() => void) | null = null;
  private cancelChargeTimer: (() => void) | null = null;
  private cancelSessionTimer: (() => void) | null = null;
  private heldSetupComplete: Frame | null = null;
  private pendingClient: Frame[] = [];
  private pendingClientBytes = 0;
  private pendingUpstream: Frame[] = [];
  private pendingUpstreamBytes = 0;
  private upstreamTransforming = false;
  private queuedUpstream: Array<{ frame: Frame } | { closeCode: number }> = [];
  private queuedUpstreamBytes = 0;
  private readonly inputBytes: TokenBucket;
  private readonly videoFrames: TokenBucket;

  constructor(private readonly options: LiveRelayOptions) {
    this.row = options.row;
    const now = options.clock();
    this.inputBytes = new TokenBucket(LIVE_LIMITS.inputBurstBytes, LIVE_LIMITS.inputBytesPerSecond, now);
    this.videoFrames = new TokenBucket(LIVE_LIMITS.videoFrameBurst, LIVE_LIMITS.videoFramesPerSecond, now);
  }

  get state(): LiveRelayPhase {
    return this.phase;
  }

  /** Blocks paid so far in this session. */
  get blocksCharged(): number {
    return this.blocks;
  }

  start(): void {
    const { client, upstream } = this.options;
    // Binary frames as ArrayBuffer (the default is Blob from compatibility date
    // 2026-03-17), so they can be checked and forwarded synchronously.
    client.binaryType = "arraybuffer";
    upstream.binaryType = "arraybuffer";
    upstream.accept();
    client.accept();
    // A listener that throws drops the connection, so every handler is guarded.
    client.addEventListener("message", (event) => this.guard(() => this.onClientFrame(event.data)));
    client.addEventListener("close", () => this.guard(() => this.onClientGone()));
    client.addEventListener("error", () => this.guard(() => this.onClientGone()));
    upstream.addEventListener("message", (event) => this.guard(() => this.onUpstreamFrame(event.data)));
    upstream.addEventListener("close", (event) => this.guard(() => this.onUpstreamClosed(event.code)));
    upstream.addEventListener("error", () => this.guard(() => this.onUpstreamClosed(1006)));
    this.startTimer(LIVE_LIMITS.setupTimeoutMs, () => this.reject("setup_timeout"));
  }

  private isClosed(): boolean {
    return this.phase === "closed";
  }

  private onClientFrame(data: unknown): void {
    if (this.isClosed()) return;
    const awaitingSetup = this.phase === "awaiting_setup";
    const errorCode = awaitingSetup ? "invalid_setup" : "invalid_message";
    if (!isFrame(data)) {
      this.reject(errorCode, "unsupported_frame:message");
      return;
    }
    const bytes = frameBytes(data);
    if (bytes > LIVE_LIMITS.maxMessageBytes) {
      this.reject(errorCode, "too_large:message");
      return;
    }
    const now = this.options.clock();
    if (!this.inputBytes.take(bytes, now)) {
      this.reject("rate_limited");
      return;
    }
    const parsed = parseClientFrame(data);
    if (!parsed.ok) {
      this.reject(errorCode, parsed.error);
      return;
    }
    if (awaitingSetup) {
      void this.onSetup(parsed.value).catch((error: unknown) => this.internalError(error));
      return;
    }

    const inspection = inspectLiveClientMessage(parsed.value);
    if (!inspection.ok) {
      this.reject("invalid_message", inspection.error);
      return;
    }
    if (inspection.videoFrames > 0 && !this.videoFrames.take(inspection.videoFrames, now)) {
      this.reject("rate_limited");
      return;
    }
    if (this.phase === "live") {
      this.sendUpstream(data);
      return;
    }
    // Setup is out but the first block is not paid yet: hold the input so
    // nothing reaches Gemini unpaid. Protocol-following clients send nothing
    // before setupComplete, so this only absorbs early microphone audio.
    this.pendingClientBytes += bytes;
    if (this.pendingClientBytes > LIVE_LIMITS.maxPendingClientBytes) {
      this.reject("invalid_message", "sent_before_setup_complete:message");
      return;
    }
    this.pendingClient.push(data);
  }

  private async onSetup(message: unknown): Promise<void> {
    const result = sanitizeLiveSetup(message, this.options.model);
    if (!result.ok) {
      this.reject("invalid_setup", result.error);
      return;
    }
    this.phase = "validating_setup";
    let forwarded = result.message;
    const setup = (JSON.parse(result.message) as { setup: JsonObject }).setup;
    const resumption = setup.sessionResumption;
    if (isObject(resumption) && typeof resumption.handle === "string") {
      const handle = await this.options.resumption.open(resumption.handle);
      if (this.isClosed()) return;
      if (handle === null) {
        this.reject("invalid_setup", "invalid_resumption:setup.sessionResumption.handle");
        return;
      }
      resumption.handle = handle;
      forwarded = JSON.stringify({ setup });
    }
    this.clearTimer();
    if (!this.sendUpstream(forwarded)) return;
    this.phase = "awaiting_setup_complete";
    this.startTimer(LIVE_LIMITS.setupCompleteTimeoutMs, () => this.upstreamFailed("setup_complete_timeout"));
  }

  private onUpstreamFrame(data: unknown): void {
    if (this.isClosed() || !isFrame(data)) return;
    if (this.upstreamTransforming) {
      this.queuedUpstreamBytes += frameBytes(data);
      if (this.queuedUpstreamBytes > LIVE_LIMITS.maxPendingClientBytes) {
        this.upstreamFailed("resumption_buffer_limit");
        return;
      }
      this.queuedUpstream.push({ frame: data });
      return;
    }
    const text = typeof data === "string" ? data : lenientUtf8.decode(data);
    if (text.includes("sessionResumptionUpdate")) {
      let parsed: unknown;
      try { parsed = JSON.parse(text) as unknown; } catch { /* Forward other provider frames unchanged. */ }
      const update = isObject(parsed) ? parsed.sessionResumptionUpdate : undefined;
      if (isObject(update) && typeof update.newHandle === "string" && update.newHandle.length > 0) {
        this.upstreamTransforming = true;
        void this.options.resumption.seal(update.newHandle).then((handle) => {
          if (this.isClosed()) return;
          update.newHandle = handle;
          const transformed = JSON.stringify(parsed);
          this.relayUpstreamFrame(typeof data === "string" ? transformed : new TextEncoder().encode(transformed).buffer as ArrayBuffer);
          this.upstreamTransforming = false;
          while (!this.upstreamTransforming && !this.isClosed() && this.queuedUpstream.length > 0) {
            const event = this.queuedUpstream.shift()!;
            if ("frame" in event) {
              this.queuedUpstreamBytes -= frameBytes(event.frame);
              this.onUpstreamFrame(event.frame);
            } else this.onUpstreamClosed(event.closeCode);
          }
        }).catch((error: unknown) => this.internalError(error));
        return;
      }
    }
    this.relayUpstreamFrame(data);
  }

  private relayUpstreamFrame(data: Frame): void {
    if (this.isClosed()) return;
    switch (this.phase) {
      case "live":
        this.sendClient(data);
        return;
      case "starting":
        // Keep server order: these follow setupComplete, which waits for block 0.
        this.pendingUpstreamBytes += frameBytes(data);
        if (this.pendingUpstreamBytes > LIVE_LIMITS.maxPendingUpstreamBytes) {
          this.upstreamFailed("starting_buffer_limit");
          return;
        }
        this.pendingUpstream.push(data);
        return;
      case "awaiting_setup_complete":
        if (isSetupComplete(data)) {
          this.clearTimer();
          this.phase = "starting";
          this.heldSetupComplete = data;
          this.meterStartMs = this.options.clock();
          this.cancelSessionTimer = this.options.setTimer(
            () => this.endWith("session_limit", LIVE_CLOSE_CODES.sessionLimit),
            LIVE_LIMITS.sessionSeconds * 1000
          );
          this.runBlockSafely(0);
          return;
        }
        this.sendClient(data);
        return;
      default:
        this.sendClient(data);
    }
  }

  private onUpstreamClosed(code: number): void {
    if (this.isClosed()) return;
    if (this.upstreamTransforming) {
      this.queuedUpstream.push({ closeCode: code });
      return;
    }
    // A clean upstream close of a running conversation (for example after
    // `goAway`) ends the session normally; anything else is an upstream failure.
    if (this.phase === "live" && (code === 1000 || code === 1001)) {
      this.shutDown();
      tryClose(this.options.client, LIVE_CLOSE_CODES.normal, "upstream_closed");
      return;
    }
    this.upstreamFailed("upstream_closed", code);
  }

  private onClientGone(): void {
    if (this.isClosed()) return;
    this.shutDown();
    tryClose(this.options.upstream, LIVE_CLOSE_CODES.normal, "client_closed");
  }

  // MARK: Metering

  private runBlockSafely(index: number): void {
    this.runBlock(index).catch((error: unknown) => this.internalError(error));
  }

  /** Block `index` covers seconds [15·index, 15·index + 15) after setupComplete and is paid at its start. */
  private async runBlock(index: number): Promise<void> {
    if (this.isClosed()) return;
    if (index * VOICE_BLOCK_SECONDS >= LIVE_LIMITS.sessionSeconds) {
      this.endWith("session_limit", LIVE_CLOSE_CODES.sessionLimit);
      return;
    }
    this.cancelChargeTimer = this.options.setTimer(
      () => {
        this.options.log({ event: "hosted_ai_live_charge_failed", reason: "charge_timeout", blocksCharged: this.blocks, ...this.logContext() });
        this.endWith("voice_unavailable", LIVE_CLOSE_CODES.upstreamFailure);
      },
      LIVE_LIMITS.chargeTimeoutMs
    );
    const outcome = await this.chargeBlock();
    this.cancelChargeTimer?.();
    this.cancelChargeTimer = null;
    if (outcome === null || this.isClosed()) return;
    if (outcome.status === "quota_exceeded") {
      this.endWith("voice_quota_exceeded", LIVE_CLOSE_CODES.quotaExceeded);
      return;
    }
    this.row = outcome.row;
    this.blocks += 1;
    // The balance left after this charge, plus the block just paid for.
    const secondsRemaining = (voiceBlocksRemaining(outcome.voice) + 1) * VOICE_BLOCK_SECONDS;
    if (index === 0) {
      if (!this.goLive(secondsRemaining)) return;
    } else if (index % LIVE_LIMITS.secondsRemainingEveryBlocks === 0) {
      if (!this.sendClient(fudVoice({ secondsRemaining }))) return;
    }
    const dueMs = this.meterStartMs + (index + 1) * VOICE_BLOCK_SECONDS * 1000;
    this.startTimer(Math.max(0, dueMs - this.options.clock()), () => this.runBlockSafely(index + 1));
  }

  /** Pays for the next block, retrying D1 failures; null when the session is over. */
  private async chargeBlock(): Promise<VoiceSpendOutcome | null> {
    let lastError: unknown = null;
    const receiptId = crypto.randomUUID();
    for (let attempt = 0; attempt <= CHARGE_RETRY_DELAYS_MS.length; attempt += 1) {
      if (attempt > 0) await this.options.sleep(CHARGE_RETRY_DELAYS_MS[attempt - 1]!);
      if (this.isClosed()) return null;
      const charge = spendVoiceBlock(this.options.ledger, this.options.userIdHash, this.row, receiptId);
      this.options.waitUntil?.(charge.catch(() => undefined));
      try {
        return await charge;
      } catch (error) {
        lastError = error;
      }
    }
    if (this.isClosed()) return null;
    this.options.log({
      event: "hosted_ai_live_charge_failed",
      attempts: CHARGE_RETRY_DELAYS_MS.length + 1,
      errorType: lastError instanceof Error ? lastError.name : typeof lastError,
      message: this.options.redact((lastError instanceof Error ? lastError.message : String(lastError)).slice(0, 300)),
      blocksCharged: this.blocks,
      ...this.logContext(),
    });
    this.endWith("voice_unavailable", LIVE_CLOSE_CODES.upstreamFailure);
    return null;
  }

  /** Delivers setupComplete, the first balance, and everything held while block 0 was paid. */
  private goLive(secondsRemaining: number): boolean {
    this.phase = "live";
    const setupComplete = this.heldSetupComplete;
    this.heldSetupComplete = null;
    if (setupComplete !== null && !this.sendClient(setupComplete)) return false;
    if (!this.sendClient(fudVoice({ secondsRemaining }))) return false;
    this.pendingUpstreamBytes = 0;
    for (const frame of this.pendingUpstream.splice(0)) {
      if (!this.sendClient(frame)) return false;
    }
    const held = this.pendingClient.splice(0);
    this.pendingClientBytes = 0;
    for (const frame of held) {
      if (!this.sendUpstream(frame)) return false;
    }
    return true;
  }

  // MARK: Closing

  private reject(error: string, detail?: string): void {
    if (this.isClosed()) return;
    const safe = detail === undefined ? undefined : safeDetail(detail);
    this.options.log({ event: "hosted_ai_live_rejected", error, detail: safe, ...this.logContext() });
    this.endWith(error, LIVE_CLOSE_CODES.policy, safe === undefined ? {} : { detail: safe });
  }

  private upstreamFailed(reason: string, upstreamCode?: number): void {
    if (this.isClosed()) return;
    // The upstream close reason is free text and is neither logged nor relayed.
    this.options.log({
      event: "hosted_ai_live_upstream_failed",
      reason,
      upstreamCode,
      blocksCharged: this.blocks,
      ...this.logContext(),
    });
    this.endWith("upstream_error", LIVE_CLOSE_CODES.upstreamFailure, upstreamCode === undefined ? {} : { upstreamCode });
  }

  private internalError(error: unknown): void {
    if (this.isClosed()) return;
    this.options.log({
      event: "hosted_ai_live_internal_error",
      errorType: error instanceof Error ? error.name : typeof error,
      message: this.options.redact((error instanceof Error ? error.message : String(error)).slice(0, 300)),
      ...this.logContext(),
    });
    this.endWith("voice_unavailable", LIVE_CLOSE_CODES.upstreamFailure);
  }

  /** Tells the app why, then closes both sides. */
  private endWith(error: string, code: number, extra: Record<string, unknown> = {}): void {
    if (this.isClosed()) return;
    this.shutDown();
    trySend(this.options.client, fudVoice({ error, ...extra }));
    tryClose(this.options.client, code, error);
    tryClose(this.options.upstream, LIVE_CLOSE_CODES.normal, "session_ended");
  }

  private shutDown(): void {
    this.phase = "closed";
    this.clearTimer();
    this.cancelChargeTimer?.();
    this.cancelChargeTimer = null;
    this.cancelSessionTimer?.();
    this.cancelSessionTimer = null;
    this.heldSetupComplete = null;
    this.pendingClient = [];
    this.pendingClientBytes = 0;
    this.pendingUpstream = [];
    this.pendingUpstreamBytes = 0;
    this.queuedUpstream = [];
    this.queuedUpstreamBytes = 0;
  }

  // MARK: Plumbing

  private sendUpstream(frame: Frame): boolean {
    if (trySend(this.options.upstream, frame)) return true;
    this.upstreamFailed("send_failed");
    return false;
  }

  private sendClient(frame: Frame): boolean {
    if (trySend(this.options.client, frame)) return true;
    this.onClientGone();
    return false;
  }

  private startTimer(ms: number, callback: () => void): void {
    this.clearTimer();
    this.cancelTimer = this.options.setTimer(() => {
      this.cancelTimer = null;
      this.guard(callback);
    }, ms);
  }

  private clearTimer(): void {
    this.cancelTimer?.();
    this.cancelTimer = null;
  }

  private guard(action: () => void): void {
    try {
      action();
    } catch (error) {
      this.internalError(error);
    }
  }

  private logContext(): Record<string, unknown> {
    return { phase: this.phase, platform: this.options.platform, userIdHash: this.options.userIdHash.slice(0, 12) };
  }
}

export function startLiveRelay(options: LiveRelayOptions): LiveRelaySession {
  const session = new LiveRelaySession(options);
  session.start();
  return session;
}

// MARK: Workers runtime defaults (tests replace these)

export function createWebSocketPair(): { client: WebSocket; server: WebSocket } {
  const pair = new WebSocketPair();
  return { client: pair[0], server: pair[1] };
}

export function webSocketUpgradeResponse(client: WebSocket): Response {
  return new Response(null, { status: 101, webSocket: client });
}

export function setRuntimeTimer(callback: () => void, ms: number): () => void {
  const id = setTimeout(callback, ms);
  return () => clearTimeout(id);
}

#!/usr/bin/env node
/**
 * Live hosted-voice smoke test using an isolated, entitled synthetic customer.
 * Run only after migrations and deployment:
 *   FUD_VOICE_SMOKE_USER_ID=<anonymous-test-id> node scripts/hosted_ai_voice_smoke.mjs
 * Requires `npm ci --prefix web`. Uses web's existing `ws` dependency.
 * Spends about 45 voice seconds (two blocks, then one resumed block), takes
 * about 20 seconds, and stops after 60 seconds. Never records or plays audio.
 * Credentials, handles, transcripts and provider response bodies are not logged.
 */

import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const BASE = "https://fud-ai.app/api/hosted-ai/v1";
const BLOCK_MS = 15_000;
const TOOL_NAME = "voice_smoke_fixture";
const MARKER = "synthetic-voice-smoke";
const requireWeb = createRequire(new URL("../web/package.json", import.meta.url));

class SmokeFailure extends Error {
  constructor(code) { super(code); this.code = code; }
}
const failure = (code) => new SmokeFailure(code);
const terminate = (socket) => { try { socket?.terminate(); } catch { /* Best-effort cleanup. */ } };

function setup(handle) {
  return {
    setup: {
      generationConfig: {
        responseModalities: ["AUDIO"],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: "Kore" } } },
      },
      systemInstruction: { parts: [{ text:
        `This is an automated test using synthetic fixtures only. When asked to begin, call ${TOOL_NAME} ` +
        `exactly once with marker ${MARKER}. After receiving its result, say one brief sentence confirming ` +
        "the synthetic test succeeded, then finish your turn. Do not ask questions or call other functions.",
      }] },
      tools: [{ functionDeclarations: [{
        name: TOOL_NAME,
        description: "Returns a harmless synthetic fixture. Does not read or change user data.",
        parameters: { type: "OBJECT", properties: { marker: { type: "STRING" } }, required: ["marker"] },
      }] }],
      inputAudioTranscription: {},
      outputAudioTranscription: {},
      contextWindowCompression: { slidingWindow: {} },
      sessionResumption: handle ? { handle } : {},
    },
  };
}

/** Exported only to permit deterministic offline transport/failure checks. */
export async function runVoiceSmoke({
  userId,
  fetchImpl = fetch,
  WebSocketClass = requireWeb("ws"),
  holdMs = 17_000,
  timeoutMs = 60_000,
  signal: externalSignal,
} = {}) {
  if (!/^\$RCAnonymousID:[0-9a-f]{32}$/.test(userId ?? "")) throw failure("invalid_test_identity");
  const controller = new AbortController();
  const abort = () => controller.abort();
  externalSignal?.addEventListener("abort", abort, { once: true });
  if (externalSignal?.aborted) abort();
  const deadline = setTimeout(abort, timeoutMs);
  const sockets = new Set();
  const headers = {
    "X-Fud-User-Id": userId,
    "X-Fud-Platform": "android",
    "User-Agent": "FudAI-Voice-Smoke/1.0",
  };

  async function quota() {
    let response;
    try {
      response = await fetchImpl(`${BASE}/quota`, { headers, signal: controller.signal, redirect: "error" });
    } catch {
      throw failure(controller.signal.aborted ? "timeout_or_cancelled" : "quota_network_error");
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw failure(`quota_http_${response.status}`);
    }
    let payload;
    try { payload = await response.json(); } catch { throw failure("quota_invalid_json"); }
    const { quota: action, voice } = payload ?? {};
    if (!action || !["plus", "pro"].includes(action.plan) || !voice ||
        !/^\d{4}-\d{2}$/.test(voice.month ?? "") ||
        ![voice.secondsUsed, voice.secondsLimit, voice.creditBank, action.dailyUsed].every((n) => Number.isSafeInteger(n) && n >= 0) ||
        voice.creditBank !== action.creditBank || voice.secondsLimit === 0) {
      throw failure("quota_invalid_or_not_entitled");
    }
    return { action, voice };
  }

  function session(resumeHandle = null) {
    const exercise = resumeHandle === null;
    return new Promise((resolve, reject) => {
      let socket;
      let settled = false;
      let intentionalClose = false;
      let setupSentAt = null;
      let setupAt = null;
      let closeAt = null;
      let closedAt = null;
      let holdElapsed = !exercise;
      let holdTimer;
      let closeTimer;
      let handle = null;
      let audioBytes = 0;
      let transcriptCharacters = 0;
      let toolResponses = 0;
      const calls = new Set();

      const finish = (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(holdTimer);
        clearTimeout(closeTimer);
        controller.signal.removeEventListener("abort", onAbort);
        if (error) {
          terminate(socket);
          reject(error);
        } else {
          resolve({ handle, audioBytes, transcriptCharacters, toolCalls: calls.size, toolResponses,
            minimumBlocks: Math.floor(Math.max(0, closeAt - setupAt) / BLOCK_MS) + 1,
            maximumBlocks: Math.floor(Math.max(0, closedAt - setupSentAt) / BLOCK_MS) + 1 });
        }
      };
      const onAbort = () => finish(failure("timeout_or_cancelled"));
      const send = (message) => {
        if (settled || intentionalClose) return;
        try { socket.send(JSON.stringify(message)); } catch { finish(failure("socket_send_failed")); }
      };
      const maybeClose = () => {
        if (settled || intentionalClose || setupAt === null || !holdElapsed) return;
        if (exercise && !(calls.size > 0 && toolResponses > 0 && audioBytes > 0 && transcriptCharacters > 0)) return;
        intentionalClose = true;
        closeAt = Date.now();
        closeTimer = setTimeout(() => finish(failure("socket_close_timeout")), 3_000);
        try { socket.close(1000, "synthetic_test_complete"); } catch { finish(failure("socket_close_failed")); }
      };

      if (controller.signal.aborted) return finish(failure("timeout_or_cancelled"));
      try {
        socket = new WebSocketClass(`${BASE.replace("https:", "wss:")}/live`, {
          headers, handshakeTimeout: 10_000, maxPayload: 4 * 1024 * 1024, followRedirects: false,
        });
      } catch { return finish(failure("socket_create_failed")); }
      sockets.add(socket);
      controller.signal.addEventListener("abort", onAbort, { once: true });
      socket.on("error", () => finish(failure("socket_error")));
      socket.on("unexpected-response", (_request, response) => {
        response.resume();
        finish(failure(`upgrade_http_${response.statusCode}`));
      });
      socket.on("open", () => { setupSentAt = Date.now(); send(setup(resumeHandle)); });
      socket.on("close", (code) => {
        sockets.delete(socket);
        if (settled) return;
        closedAt = Date.now();
        if (!intentionalClose || code !== 1000) finish(failure(`socket_closed_${code}`));
        else finish();
      });
      socket.on("message", (data) => {
        if (settled || intentionalClose) return;
        let message;
        try { message = JSON.parse(data.toString()); } catch { return finish(failure("invalid_server_json")); }
        if (message === null || typeof message !== "object") return finish(failure("invalid_server_message"));
        if (message.error || message.fudVoice?.error) return finish(failure("provider_or_relay_error"));
        if (message.setupComplete !== undefined && setupAt === null) {
          setupAt = Date.now();
          if (exercise) {
            holdTimer = setTimeout(() => { holdElapsed = true; maybeClose(); }, holdMs);
            send({ clientContent: { turns: [{ role: "user", parts: [{ text:
              "Begin the synthetic voice smoke test now. Call the provided fixture function, then speak a brief confirmation.",
            }] }], turnComplete: true } });
          }
        }
        const update = message.sessionResumptionUpdate;
        if (update?.resumable !== false && typeof update?.newHandle === "string" && update.newHandle.length > 0) {
          if (!update.newHandle.startsWith("fudv1.") || update.newHandle.length > 8192) return finish(failure("invalid_signed_resumption_handle"));
          handle = update.newHandle;
        }
        const functionCalls = message.toolCall?.functionCalls ?? [];
        if (!Array.isArray(functionCalls)) return finish(failure("invalid_server_message"));
        for (const call of functionCalls) {
          if (!exercise || call?.name !== TOOL_NAME || typeof call.id !== "string" || !call.id ||
              call.args?.marker !== MARKER || calls.size >= 4) return finish(failure("unexpected_fixture_call"));
          calls.add(call.id);
          send({ toolResponse: { functionResponses: [{ id: call.id, name: TOOL_NAME,
            response: { ok: true, fixture: "synthetic", value: 7 } }] } });
          toolResponses += 1;
        }
        // Only post-tool audio/transcription proves the model continued after the response.
        if (toolResponses > 0) {
          const content = message.serverContent;
          const parts = content?.modelTurn?.parts ?? [];
          if (!Array.isArray(parts)) return finish(failure("invalid_server_message"));
          for (const part of parts) {
            const inline = part?.inlineData;
            if (typeof inline?.mimeType === "string" && inline.mimeType.startsWith("audio/pcm") && typeof inline.data === "string") {
              audioBytes += Buffer.from(inline.data, "base64").byteLength;
            }
          }
          if (typeof content?.outputTranscription?.text === "string") transcriptCharacters += content.outputTranscription.text.trim().length;
        }
        maybeClose();
      });
    });
  }

  try {
    const before = await quota();
    const first = await session();
    const resumed = first.handle ? await session(first.handle) : null;
    const after = await quota();
    if (before.voice.month !== after.voice.month) throw failure("quota_month_changed");
    const allowanceSeconds = after.voice.secondsUsed - before.voice.secondsUsed;
    const credits = before.voice.creditBank - after.voice.creditBank;
    const seconds = allowanceSeconds + credits * 15;
    const sessions = resumed ? 2 : 1;
    const minimumBlocks = first.minimumBlocks + (resumed?.minimumBlocks ?? 0);
    const maximumBlocks = first.maximumBlocks + (resumed?.maximumBlocks ?? 0);
    // Metering begins between sending setup and receiving its acknowledgement,
    // and stops between sending close and observing it. Bound debit by those
    // timings; normally the 17-second session costs two blocks and resume one.
    if (allowanceSeconds < 0 || allowanceSeconds % 15 !== 0 || credits < 0 || seconds % 15 !== 0 ||
        seconds < minimumBlocks * 15 || seconds > maximumBlocks * 15) throw failure("voice_metering_mismatch");
    if (before.action.day === after.action.day && before.action.dailyUsed !== after.action.dailyUsed) throw failure("unexpected_action_debit");
    return { ok: true, sessions, setupAcknowledgements: sessions, toolCalls: first.toolCalls,
      toolResponses: first.toolResponses, audioBytes: first.audioBytes, transcriptCharacters: first.transcriptCharacters,
      resumption: resumed ? "verified" : "not_issued", allowanceSecondsSpent: allowanceSeconds,
      creditsSpent: credits, blocksCharged: seconds / 15,
      expectedMinimumBlocks: minimumBlocks, expectedMaximumBlocks: maximumBlocks };
  } finally {
    clearTimeout(deadline);
    externalSignal?.removeEventListener("abort", abort);
    for (const socket of sockets) terminate(socket);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const abort = new AbortController();
  const stop = () => abort.abort();
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    const result = await runVoiceSmoke({ userId: process.env.FUD_VOICE_SMOKE_USER_ID, signal: abort.signal });
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error(JSON.stringify({ ok: false, error: error instanceof SmokeFailure ? error.code : "internal_error" }));
    process.exitCode = 1;
  } finally {
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
  }
}

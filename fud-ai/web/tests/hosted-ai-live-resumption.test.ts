import { describe, expect, it } from "vitest";
import { createLiveResumptionCodec, MAX_RESUMPTION_TOKEN_CHARS, RESUMPTION_TTL_SECONDS } from "../hosted-ai-live-resumption";

describe("hosted voice resumption handles", () => {
  const start = Date.parse("2026-10-16T12:00:00Z");
  const key = "fake-provider-key";
  const owner = "a".repeat(64);

  it("authenticates opaque provider handles for the same subscriber only", async () => {
    const codec = createLiveResumptionCodec(key, owner, () => start);
    const token = await codec.seal("provider opaque handle/+=食");
    expect(token.length).toBeLessThan(MAX_RESUMPTION_TOKEN_CHARS);
    expect(await codec.open(token)).toBe("provider opaque handle/+=食");
    expect(await createLiveResumptionCodec(key, "b".repeat(64), () => start).open(token)).toBeNull();
    expect(await createLiveResumptionCodec("rotated-key", owner, () => start).open(token)).toBeNull();
  });

  it("rejects tampering, unwrapped provider handles, malformed and oversized tokens", async () => {
    const codec = createLiveResumptionCodec(key, owner, () => start);
    const token = await codec.seal("original");
    const parts = token.split(".");
    parts[1] = btoa(JSON.stringify([owner, start / 1000 + RESUMPTION_TTL_SECONDS, "different"])).replace(/=+$/, "");
    for (const bad of [parts.join("."), token.slice(0, -1), "provider-handle", "fudv1.!.!", "a".repeat(MAX_RESUMPTION_TOKEN_CHARS + 1)]) {
      expect(await codec.open(bad)).toBeNull();
    }
  });

  it("expires at the TTL boundary and accepts the preceding second", async () => {
    let now = start;
    const codec = createLiveResumptionCodec(key, owner, () => now);
    const token = await codec.seal("original");
    now = start + RESUMPTION_TTL_SECONDS * 1000 - 1000;
    expect(await codec.open(token)).toBe("original");
    now += 1000;
    expect(await codec.open(token)).toBeNull();
  });

  it("bounds provider handles before signing and keeps maximum-size handles resumable", async () => {
    const codec = createLiveResumptionCodec(key, owner, () => start);
    const handle = "a".repeat(4096);
    expect(await codec.open(await codec.seal(handle))).toBe(handle);
    await expect(codec.seal("a".repeat(4097))).rejects.toThrow("invalid_provider_resumption_handle");
    await expect(codec.seal("")).rejects.toThrow("invalid_provider_resumption_handle");
  });
});

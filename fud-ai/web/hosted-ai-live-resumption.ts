/** Subscriber-bound, authenticated Gemini resumption handles; never persisted. */
export const RESUMPTION_TTL_SECONDS = 2 * 60 * 60;
export const MAX_RESUMPTION_TOKEN_CHARS = 8192;
const MAX_PROVIDER_HANDLE_BYTES = 4096;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const PURPOSE = "fud-ai/hosted-voice/resumption/v1";

export interface LiveResumptionCodec {
  seal(handle: string): Promise<string>;
  open(token: string): Promise<string | null>;
}

function encode(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decode(text: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(text)) throw new Error("invalid_resumption_encoding");
  const bytes = Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (char) => char.charCodeAt(0));
  if (encode(bytes) !== text) throw new Error("invalid_resumption_encoding");
  return bytes;
}

export function createLiveResumptionCodec(
  apiKey: string,
  userIdHash: string,
  clock: () => number
): LiveResumptionCodec {
  // Derive a purpose-specific signing key without provisioning another secret.
  // Rotating the provider key invalidates existing wrappers.
  let derivedKey: Promise<CryptoKey> | undefined;
  const key = (): Promise<CryptoKey> => derivedKey ??= (async () => {
    const root = await crypto.subtle.importKey("raw", encoder.encode(apiKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const derived = await crypto.subtle.sign("HMAC", root, encoder.encode(`${PURPOSE}/key`));
    return await crypto.subtle.importKey("raw", derived, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
  })();
  return {
    async seal(handle) {
      if (handle.length === 0 || encoder.encode(handle).byteLength > MAX_PROVIDER_HANDLE_BYTES) {
        throw new Error("invalid_provider_resumption_handle");
      }
      const expires = Math.floor(clock() / 1000) + RESUMPTION_TTL_SECONDS;
      const payload = encode(encoder.encode(JSON.stringify([userIdHash, expires, handle])));
      const signed = `fudv1.${payload}`;
      const signature = await crypto.subtle.sign("HMAC", await key(), encoder.encode(`${PURPOSE}\n${signed}`));
      return `${signed}.${encode(new Uint8Array(signature))}`;
    },
    async open(token) {
      try {
        if (token.length > MAX_RESUMPTION_TOKEN_CHARS) return null;
        const parts = token.split(".");
        if (parts.length !== 3 || parts[0] !== "fudv1") return null;
        const signed = `${parts[0]}.${parts[1]}`;
        const signature = decode(parts[2]!);
        if (signature.byteLength !== 32 || !await crypto.subtle.verify("HMAC", await key(), signature, encoder.encode(`${PURPOSE}\n${signed}`))) return null;
        const payload: unknown = JSON.parse(decoder.decode(decode(parts[1]!)));
        if (!Array.isArray(payload) || payload.length !== 3) return null;
        const [owner, expires, handle] = payload;
        const now = Math.floor(clock() / 1000);
        if (owner !== userIdHash || !Number.isSafeInteger(expires) || expires <= now || expires > now + RESUMPTION_TTL_SECONDS) return null;
        if (typeof handle !== "string" || handle.length === 0 || encoder.encode(handle).byteLength > MAX_PROVIDER_HANDLE_BYTES) return null;
        return handle;
      } catch {
        return null;
      }
    },
  };
}

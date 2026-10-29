import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../worker";
import {
  ANDROID_BUG_CHANNEL_ID,
  deriveIssueTitle,
  DISCORD_INTERACTIONS_PATH,
  FEATURE_ISSUE_LABEL,
  formatWait,
  handleDiscordInteractionsRequest,
  IOS_BUG_CHANNEL_ID,
  labelsForBugPlatform,
  labelsForFeatureRequest,
  parseStructuredIssue,
  recentReports,
  reportCooldownSeconds,
  resolveBugPlatform,
  resolveFeaturePlatform,
  verifyDiscordSignature,
} from "../discord-interactions";

const APP_ID = "1548469419922038845";
const GUILD_ID = "1548469034570354709";
const ISSUE_URL = "https://github.com/apoorvdarshan/fud-ai/issues/42";

// Match the request's exact host; a substring check would also match e.g. "api.github.com.evil.test".
function hasHost(url: unknown, host: string): boolean {
  const href = url instanceof Request ? url.url : String(url);
  return URL.canParse(href) && new URL(href).hostname === host;
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function ed25519Pair(): Promise<{ privateKey: CryptoKey; publicKeyHex: string }> {
  const pair = (await crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
  return { privateKey: pair.privateKey, publicKeyHex: bytesToHex(new Uint8Array(raw as ArrayBuffer)) };
}

type MockFetch = (input: string, init?: RequestInit) => Promise<Response>;

function requestBody(init: RequestInit | undefined): string {
  return String(init?.body ?? "");
}

async function signedRequest(
  privateKey: CryptoKey,
  body: unknown,
): Promise<Request> {
  const timestamp = "1710000000";
  const text = JSON.stringify(body);
  const message = new TextEncoder().encode(timestamp + text);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, privateKey, message));
  return new Request(`https://fud-ai.app${DISCORD_INTERACTIONS_PATH}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Signature-Ed25519": bytesToHex(sig),
      "X-Signature-Timestamp": timestamp,
    },
    body: text,
  });
}

function env(publicKeyHex: string, extra: Record<string, string> = {}) {
  type Metadata = { owner: string; reports?: number[] };
  const state = new Map<string, { value: string; expiresAt: number; metadata: Metadata | undefined }>();
  return {
    DISCORD_PUBLIC_KEY: publicKeyHex,
    DISCORD_APPLICATION_ID: APP_ID,
    DISCORD_GEMINI_API_KEY: "test-gemini-key",
    GITHUB_TOKEN: "test-github-token",
    DISCORD_STATE: {
      async getWithMetadata(key: string): Promise<{ value: string | null; metadata: unknown }> {
        const entry = state.get(key);
        return entry && entry.expiresAt > Date.now()
          ? { value: entry.value, metadata: entry.metadata ?? null }
          : { value: null, metadata: null };
      },
      async get(key: string): Promise<string | null> {
        const entry = state.get(key);
        return entry && entry.expiresAt > Date.now() ? entry.value : null;
      },
      async put(key: string, value: string, options: { expirationTtl: number; metadata?: Metadata }): Promise<void> {
        state.set(key, { value, metadata: options.metadata, expiresAt: Date.now() + options.expirationTtl * 1000 });
      },
    },
    ...extra,
  };
}

function waiters() {
  const pending: Promise<unknown>[] = [];
  return {
    ctx: { waitUntil: (promise: Promise<unknown>) => pending.push(promise) },
    flush: async () => {
      // Background rollback work may register another waiter while commands run.
      for (let i = 0; i < pending.length; i++) await pending[i];
    },
  };
}

function command(name: string, options: Array<{ name: string; value: string }>, extra: Record<string, unknown> = {}) {
  return {
    type: 2,
    token: "interaction-token",
    id: "interaction-id",
    application_id: APP_ID,
    guild_id: GUILD_ID,
    channel_id: "999",
    data: { name, options: options.map((option) => ({ type: 3, ...option })) },
    member: { user: { id: "user-1", username: "reporter", global_name: "Reporter" } },
    ...extra,
  };
}

function geminiIssueResponse(
  title: string,
  body: string,
  fenced = false,
  platform: "iOS" | "Android" | null = null,
): Response {
  const json = JSON.stringify({ title, body, platform });
  return Response.json({
    candidates: [{ content: { parts: [{ text: fenced ? `\`\`\`json\n${json}\n\`\`\`` : json }] } }],
  });
}

function issueFlowFetch(gemini: Response | "fail" | "skip" = geminiIssueResponse("Draft title", "Draft body")): MockFetch {
  return async (url) => {
    if (String(url).includes("generativelanguage")) {
      if (gemini === "skip") throw new Error(`unexpected Gemini fetch ${url}`);
      if (gemini === "fail") {
        return Response.json({ error: { message: "boom" } }, { status: 500 });
      }
      return gemini;
    }
    if (hasHost(url, "api.github.com")) {
      return Response.json({ html_url: ISSUE_URL, number: 42 }, { status: 201 });
    }
    if (hasHost(url, "discord.com")) return new Response(null, { status: 200 });
    throw new Error(`unexpected fetch ${url}`);
  };
}

function githubPayload(fetchMock: ReturnType<typeof vi.fn<MockFetch>>): {
  title: string;
  body: string;
  labels: string[];
} {
  const githubCall = fetchMock.mock.calls.find(([url]) => hasHost(url, "api.github.com"));
  return JSON.parse(requestBody(githubCall?.[1])) as {
    title: string;
    body: string;
    labels: string[];
  };
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("discord interactions", () => {
  it("exports the interactions path", () => {
    expect(DISCORD_INTERACTIONS_PATH).toBe("/api/discord/interactions");
  });

  it("rejects garbage signatures", async () => {
    const ok = await verifyDiscordSignature(
      "{}",
      "00".repeat(64),
      "0",
      "0ce6e6014282b489ce0930fad550e978c7d623cc71040d14250223110a9a9f57",
    );
    expect(ok).toBe(false);
  });

  it("prefers report-text platform signals over the Discord bug channel", () => {
    expect(resolveBugPlatform("", IOS_BUG_CHANNEL_ID)).toBe("iOS");
    expect(resolveBugPlatform("", ANDROID_BUG_CHANNEL_ID)).toBe("Android");
    expect(resolveBugPlatform("Android", IOS_BUG_CHANNEL_ID)).toBe("Android");
    expect(resolveBugPlatform("ios", "other")).toBe("iOS");
    expect(resolveBugPlatform("", "other")).toBe("");
    expect(resolveBugPlatform("Crash on my Pixel 8 after save", IOS_BUG_CHANNEL_ID)).toBe(
      "Android",
    );
    expect(resolveBugPlatform("iPhone 15 crashes on save", ANDROID_BUG_CHANNEL_ID)).toBe("iOS");
    expect(resolveBugPlatform("ipad widget is blank", ANDROID_BUG_CHANNEL_ID)).toBe("iOS");
    expect(resolveBugPlatform("galaxy s24 overlay flicker", IOS_BUG_CHANNEL_ID)).toBe("Android");
    expect(resolveBugPlatform("oneplus 12 can't log a meal", IOS_BUG_CHANNEL_ID)).toBe("Android");
    expect(resolveBugPlatform("samsung fold theme flip", IOS_BUG_CHANNEL_ID)).toBe("Android");
    expect(resolveBugPlatform("Dark mode flicker", ANDROID_BUG_CHANNEL_ID)).toBe("Android");
    expect(resolveBugPlatform("Dark mode flicker", IOS_BUG_CHANNEL_ID)).toBe("iOS");
    expect(resolveBugPlatform("Broken on iPhone and Android", IOS_BUG_CHANNEL_ID)).toBe("iOS");
    expect(resolveBugPlatform("Broken on iOS and Android", ANDROID_BUG_CHANNEL_ID)).toBe(
      "Android",
    );
    expect(resolveBugPlatform("Broken on iPhone and Android", "other")).toBe("");
    expect(resolveBugPlatform("Something broke", "other")).toBe("");
    expect(
      resolveBugPlatform("", IOS_BUG_CHANNEL_ID, { title: "t", body: "b", platform: "Android" }),
    ).toBe("Android");
    expect(
      resolveBugPlatform("no device", IOS_BUG_CHANNEL_ID, {
        title: "Pixel overlay",
        body: "Repro on Pixel 9.",
        platform: null,
      }),
    ).toBe("Android");
    expect(labelsForBugPlatform("iOS")).toEqual(["bug", "ios"]);
    expect(labelsForBugPlatform("Android")).toEqual(["bug", "android"]);
    expect(labelsForBugPlatform("")).toEqual(["bug"]);
  });

  it("does not infer /feature platform from Discord channels", () => {
    expect(resolveFeaturePlatform("")).toBe("");
    expect(resolveFeaturePlatform("iOS")).toBe("iOS");
    expect(resolveFeaturePlatform("android")).toBe("Android");
    expect(resolveFeaturePlatform("both")).toBe("both");
    expect(resolveFeaturePlatform("none")).toBe("");
    expect(labelsForFeatureRequest()).toEqual([FEATURE_ISSUE_LABEL]);
    expect(FEATURE_ISSUE_LABEL).toBe("enhancement");
  });

  it("derives a GitHub title from freeform report text", () => {
    expect(deriveIssueTitle("Crash on save")).toBe("Crash on save");
    expect(deriveIssueTitle("  Crash on save  \n\nTap save after logging a meal.")).toBe(
      "Crash on save",
    );
    expect(deriveIssueTitle("\n\nWidget calories\nShow leftover calories.")).toBe("Widget calories");
    expect(deriveIssueTitle("")).toBe("Discord report");

    const longLine =
      "This first line is deliberately longer than one hundred characters so it cannot be used as the issue title";
    expect(longLine.length).toBeGreaterThan(100);
    const clipped = deriveIssueTitle(`${longLine}\nMore details after the break.`);
    expect(clipped.endsWith("…")).toBe(true);
    expect(clipped.length).toBeLessThanOrEqual(101);
    expect(clipped.includes("\n")).toBe(false);
    expect(clipped.startsWith("This first line is deliberately")).toBe(true);
    expect(clipped).not.toContain("More details");

    const oneWord = "x".repeat(140);
    expect(deriveIssueTitle(oneWord)).toBe(`${"x".repeat(100)}…`);
  });

  it("parses Gemini JSON issue drafts, including fenced replies", () => {
    expect(parseStructuredIssue('{"title":"Crash on save","body":"## Details\\nTap save."}')).toEqual({
      title: "Crash on save",
      body: "## Details\nTap save.",
      platform: null,
    });
    expect(
      parseStructuredIssue('```json\n{"title":"Widget calories","body":"Show leftovers."}\n```'),
    ).toEqual({
      title: "Widget calories",
      body: "Show leftovers.",
      platform: null,
    });
    expect(
      parseStructuredIssue(
        '{"title":"Pixel overlay","body":"Flickers on resume.","platform":"Android"}',
      ),
    ).toEqual({
      title: "Pixel overlay",
      body: "Flickers on resume.",
      platform: "Android",
    });
    expect(
      parseStructuredIssue('{"title":"Crash","body":"Steps","platform":"iOS"}'),
    ).toEqual({
      title: "Crash",
      body: "Steps",
      platform: "iOS",
    });
    expect(parseStructuredIssue('{"title":"Crash","body":"Steps","platform":null}')).toEqual({
      title: "Crash",
      body: "Steps",
      platform: null,
    });
    expect(parseStructuredIssue("not json")).toBeNull();
    expect(parseStructuredIssue('{"title":"","body":"x"}')).toBeNull();
  });

  it("answers Discord PINGs", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const response = await handleDiscordInteractionsRequest(
      await signedRequest(privateKey, { type: 1 }),
      env(publicKeyHex),
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ type: 1 });
  });

  it("defers /ask and follows up with the Gemini reply", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(async (url) => {
      if (String(url).includes("generativelanguage")) {
        return Response.json({
          candidates: [{ content: { parts: [{ text: "Add your key in Settings → AI Access." }] } }],
        });
      }
      if (hasHost(url, "discord.com")) return new Response(null, { status: 200 });
      throw new Error(`unexpected fetch ${url}`);
    });
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command("ask", [{ name: "question", value: "How do I add my Gemini key?" }]),
      ),
      env(publicKeyHex),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();

    expect(fetch.mock.calls.some(([url]) => String(url).includes("generativelanguage"))).toBe(true);
    expect(fetch.mock.calls.some(([url]) => hasHost(url, "api.github.com"))).toBe(false);
    const askGeminiBody = requestBody(
      fetch.mock.calls.find(([url]) => String(url).includes("generativelanguage"))?.[1],
    );
    expect(askGeminiBody).toContain("You are the Fud AI Discord helper");
    expect(askGeminiBody).toContain("\"temperature\":0.7");
    expect(askGeminiBody).not.toContain("kind: bug");
    const discordCall = fetch.mock.calls.find(([url]) => String(url).includes("discord.com/api/v10/webhooks"));
    expect(discordCall?.[1]).toEqual({
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content: "Add your key in Settings → AI Access.", allowed_mentions: { parse: [], replied_user: false } }),
    });
  });

  it("defers /bug, files a Gemini-structured GitHub issue, and replies with the URL", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(
      issueFlowFetch(
        geminiIssueResponse(
          "Crash on save",
          "## Details\n\nTap save after logging a meal.\n\n- iPhone 15, 7.1 (38)",
          true,
        ),
      ),
    );
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();
    const report = "Crash on save\n\nTap save after logging a meal.\niPhone 15, 7.1 (38)";

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command("bug", [{ name: "report", value: report }], { channel_id: IOS_BUG_CHANNEL_ID }),
      ),
      env(publicKeyHex),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();

    const geminiCall = fetch.mock.calls.find(([url]) => String(url).includes("generativelanguage"));
    expect(String(geminiCall?.[0])).toContain("key=test-gemini-key");
    expect(requestBody(geminiCall?.[1])).toContain("kind: bug");
    expect(requestBody(geminiCall?.[1])).toContain(
      "only when the report clearly indicates one mobile platform",
    );
    expect(requestBody(geminiCall?.[1])).toContain("Crash on save");
    expect(requestBody(geminiCall?.[1])).toContain("Tap save after logging a meal.");

    const githubCall = fetch.mock.calls.find(([url]) => hasHost(url, "api.github.com"));
    expect(githubCall?.[0]).toBe("https://api.github.com/repos/apoorvdarshan/fud-ai/issues");
    expect(githubCall?.[1]).toMatchObject({
      method: "POST",
      headers: expect.objectContaining({
        Authorization: "Bearer test-github-token",
      }),
    });
    const created = githubPayload(fetch);
    expect(created.title).toBe("Crash on save");
    expect(created.labels).toEqual(["bug", "ios"]);
    expect(created.body).toContain("## Details");
    expect(created.body).toContain("Tap save after logging a meal.");
    expect(created.body).toContain("iPhone 15, 7.1 (38)");
    expect(created.body).toContain("**Platform:** iOS");
    expect(created.body).toContain("Reported via Discord `/bug`");
    expect(created.body).not.toContain("Reporter");
    expect(created.body).not.toContain("`user-1`");
    expect(created.body).not.toContain(IOS_BUG_CHANNEL_ID);
    expect(created.body).not.toContain(GUILD_ID);

    const discordCall = fetch.mock.calls.find(([url]) => String(url).includes("discord.com/api/v10/webhooks"));
    expect(requestBody(discordCall?.[1])).toBe(JSON.stringify({ content: `Opened ${ISSUE_URL}`, allowed_mentions: { parse: [], replied_user: false } }));
  });

  it("labels Android when the report says Pixel even in the iOS bug channel", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(issueFlowFetch("fail"));
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();
    const report = "Overlay flicker on Pixel 8 after I resume the app.";

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command("bug", [{ name: "report", value: report }], { channel_id: IOS_BUG_CHANNEL_ID }),
      ),
      env(publicKeyHex),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();

    const created = githubPayload(fetch);
    expect(created.labels).toEqual(["bug", "android"]);
    expect(created.body).toContain("**Platform:** Android");
    expect(created.body).not.toContain(IOS_BUG_CHANNEL_ID);
  });

  it("labels iOS when the report says iPhone even in the Android bug channel", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(issueFlowFetch("fail"));
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();
    const report = "Save crashes every time on iPhone 15.";

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command("bug", [{ name: "report", value: report }], {
          channel_id: ANDROID_BUG_CHANNEL_ID,
        }),
      ),
      env(publicKeyHex),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();

    const created = githubPayload(fetch);
    expect(created.labels).toEqual(["bug", "ios"]);
    expect(created.body).toContain("**Platform:** iOS");
    expect(created.body).not.toContain(ANDROID_BUG_CHANNEL_ID);
  });

  it("uses the channel when the report mentions both platforms", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(issueFlowFetch("skip"));
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command(
          "bug",
          [{ name: "report", value: "Sync is broken on iPhone and Android." }],
          { channel_id: IOS_BUG_CHANNEL_ID },
        ),
      ),
      env(publicKeyHex, { DISCORD_GEMINI_API_KEY: "" }),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();
    expect(githubPayload(fetch).labels).toEqual(["bug", "ios"]);
  });

  it("uses Gemini platform when the report text has no device words", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(
      issueFlowFetch(geminiIssueResponse("Overlay flicker", "Flickers after resume.", false, "Android")),
    );
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command("bug", [{ name: "report", value: "Overlay flicker after resume." }], {
          channel_id: IOS_BUG_CHANNEL_ID,
        }),
      ),
      env(publicKeyHex),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();
    const created = githubPayload(fetch);
    expect(created.labels).toEqual(["bug", "android"]);
    expect(created.body).toContain("**Platform:** Android");
    expect(created.body).not.toContain(IOS_BUG_CHANNEL_ID);
  });

  it("labels only bug when there is no channel and no platform signal", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(issueFlowFetch("skip"));
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command("bug", [{ name: "report", value: "Dark mode flicker\nTheme flips on resume." }]),
      ),
      env(publicKeyHex, { DISCORD_GEMINI_API_KEY: "" }),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();
    const created = githubPayload(fetch);
    expect(created.labels).toEqual(["bug"]);
    expect(created.body).not.toContain("**Platform:**");
  });

  it("infers Android from the Android channel when platform is omitted", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(issueFlowFetch("skip"));
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command(
          "bug",
          [{ name: "report", value: "Dark mode flicker\nTheme flips on resume." }],
          { channel_id: ANDROID_BUG_CHANNEL_ID },
        ),
      ),
      env(publicKeyHex, { DISCORD_GEMINI_API_KEY: "" }),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();
    expect(githubPayload(fetch).labels).toEqual(["bug", "android"]);
    expect(fetch.mock.calls.some(([url]) => String(url).includes("generativelanguage"))).toBe(false);
  });

  it("retries with only the bug label when ios/android labels are missing on GitHub", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(async (url) => {
      if (hasHost(url, "api.github.com")) {
        if (fetch.mock.calls.filter(([called]) => hasHost(called, "api.github.com")).length === 1) {
          return Response.json({ message: "Validation Failed" }, { status: 422 });
        }
        return Response.json({ html_url: ISSUE_URL, number: 42 }, { status: 201 });
      }
      return new Response(null, { status: 200 });
    });
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();

    await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command(
          "bug",
          [{ name: "report", value: "Crash on save\nSteps" }],
          { channel_id: IOS_BUG_CHANNEL_ID },
        ),
      ),
      env(publicKeyHex, { DISCORD_GEMINI_API_KEY: "" }),
      ctx,
    );
    await flush();

    const githubBodies = fetch.mock.calls
      .filter(([url]) => hasHost(url, "api.github.com"))
      .map(([, options]) => JSON.parse(requestBody(options)) as { labels: string[] });
    expect(githubBodies.map((body) => body.labels)).toEqual([["bug", "ios"], ["bug"]]);
  });

  it("follows up when GITHUB_TOKEN is missing", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(async (url) => {
      if (hasHost(url, "discord.com")) return new Response(null, { status: 200 });
      throw new Error(`unexpected fetch ${url}`);
    });
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command("bug", [{ name: "report", value: "Crash on save\nSteps" }]),
      ),
      env(publicKeyHex, { GITHUB_TOKEN: "" }),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();
    expect(fetch.mock.calls.some(([url]) => hasHost(url, "api.github.com"))).toBe(false);
    expect(requestBody(fetch.mock.calls[0]?.[1])).toContain("GitHub isn’t configured");
  });

  it("defers /feature, files a Gemini-structured enhancement issue, and replies with the URL", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(
      issueFlowFetch(
        geminiIssueResponse(
          "Widget remaining calories",
          "## Summary\n\nShow leftover calories on the home-screen widget.",
        ),
      ),
    );
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();
    const report = "Widget remaining calories\n\nShow leftover calories on the home-screen widget.";

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command("feature", [{ name: "report", value: report }], { channel_id: IOS_BUG_CHANNEL_ID }),
      ),
      env(publicKeyHex),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();

    const geminiCall = fetch.mock.calls.find(([url]) => String(url).includes("generativelanguage"));
    expect(String(geminiCall?.[0])).toContain("key=test-gemini-key");
    expect(requestBody(geminiCall?.[1])).toContain("kind: feature");
    expect(requestBody(geminiCall?.[1])).toContain("Widget remaining calories");

    const githubCall = fetch.mock.calls.find(([url]) => hasHost(url, "api.github.com"));
    expect(githubCall?.[0]).toBe("https://api.github.com/repos/apoorvdarshan/fud-ai/issues");
    expect(githubCall?.[1]).toMatchObject({
      method: "POST",
      headers: expect.objectContaining({
        Authorization: "Bearer test-github-token",
        "User-Agent": "fud-ai-discord-feature",
      }),
    });
    const created = githubPayload(fetch);
    expect(created.title).toBe("Widget remaining calories");
    expect(created.labels).toEqual(["enhancement"]);
    expect(created.body).toContain("## Summary");
    expect(created.body).toContain("Show leftover calories on the home-screen widget.");
    expect(created.body).toContain("Opened via Discord `/feature`");
    expect(created.body).not.toContain("Reporter");
    expect(created.body).not.toContain("`user-1`");
    expect(created.body).not.toContain(IOS_BUG_CHANNEL_ID);
    expect(created.body).not.toContain(GUILD_ID);
    expect(created.body).not.toContain("**Platform:**");
    expect(created.body).not.toContain("ios");

    const discordCall = fetch.mock.calls.find(([url]) => String(url).includes("discord.com/api/v10/webhooks"));
    expect(requestBody(discordCall?.[1])).toBe(JSON.stringify({ content: `Opened ${ISSUE_URL}`, allowed_mentions: { parse: [], replied_user: false } }));
  });

  it("leaves /feature platform unspecified when omitted, even in a platform channel", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(async (url) => {
      if (hasHost(url, "api.github.com")) {
        return Response.json({ html_url: ISSUE_URL, number: 42 }, { status: 201 });
      }
      return new Response(null, { status: 200 });
    });
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(
        privateKey,
        command(
          "feature",
          [{ name: "report", value: "Dark mode for widgets\nMatch system appearance." }],
          { channel_id: ANDROID_BUG_CHANNEL_ID },
        ),
      ),
      env(publicKeyHex, { DISCORD_GEMINI_API_KEY: "" }),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();
    const created = githubPayload(fetch);
    expect(created.labels).toEqual(["enhancement"]);
    expect(created.body).toContain("Dark mode for widgets");
    expect(created.body).toContain("Match system appearance.");
    expect(created.body).not.toContain(ANDROID_BUG_CHANNEL_ID);
    expect(created.body).not.toContain("**Platform:**");
    expect(created.body).not.toMatch(/## Platform\n\nAndroid/);
  });

  it("rejects /feature without report", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const response = await handleDiscordInteractionsRequest(
      await signedRequest(privateKey, command("feature", [])),
      env(publicKeyHex),
    );
    expect(await response.json()).toMatchObject({
      type: 4,
      data: { flags: 64 },
    });
  });

  it("rejects /bug without report", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const response = await handleDiscordInteractionsRequest(
      await signedRequest(privateKey, command("bug", [])),
      env(publicKeyHex),
    );
    expect(await response.json()).toMatchObject({
      type: 4,
      data: { flags: 64 },
    });
  });

  it("falls back to a heuristic title and raw report when Gemini fails", async () => {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const fetch = vi.fn<MockFetch>(issueFlowFetch("fail"));
    vi.stubGlobal("fetch", fetch);
    const { ctx, flush } = waiters();
    const report =
      "The save button crashes every time I log a meal after coming back from the fasting timer on iPhone 15";

    const response = await handleDiscordInteractionsRequest(
      await signedRequest(privateKey, command("bug", [{ name: "report", value: report }])),
      env(publicKeyHex),
      ctx,
    );
    expect(await response.json()).toEqual({ type: 5 });
    await flush();

    expect(fetch.mock.calls.some(([url]) => String(url).includes("generativelanguage"))).toBe(true);
    const created = githubPayload(fetch);
    expect(created.title).toBe(deriveIssueTitle(report));
    expect(created.title.endsWith("…")).toBe(true);
    expect(created.labels).toEqual(["bug", "ios"]);
    expect(created.body.startsWith(report)).toBe(true);
    expect(created.body).toContain("**Platform:** iOS");
    expect(created.body).toContain("Reported via Discord `/bug`");
    const discordCall = fetch.mock.calls.find(([url]) => String(url).includes("discord.com/api/v10/webhooks"));
    expect(requestBody(discordCall?.[1])).toBe(JSON.stringify({ content: `Opened ${ISSUE_URL}`, allowed_mentions: { parse: [], replied_user: false } }));
  });

  it("routes the live interactions path on the Worker", async () => {
    const response = await worker.fetch(
      new Request(`https://fud-ai.app${DISCORD_INTERACTIONS_PATH}`, { method: "GET" }),
      { DISCORD_PUBLIC_KEY: "abc", GITHUB_TOKEN: "token" } as unknown as Env,
    );
    expect(response.status).toBe(405);
  });
});


describe("Discord command reservations", () => {
  async function setup() {
    const { privateKey, publicKeyHex } = await ed25519Pair();
    const bindings = env(publicKeyHex);
    const fetch = vi.fn<MockFetch>(async (url) => {
      if (new URL(String(url)).hostname === "generativelanguage.googleapis.com") return geminiIssueResponse("Title", "Body");
      if (new URL(String(url)).hostname === "api.github.com") return Response.json({ html_url: ISSUE_URL, number: 42 });
      return new Response(null, { status: 200 });
    });
    vi.stubGlobal("fetch", fetch);
    const warnings = vi.spyOn(console, "warn").mockImplementation(() => {});
    async function send(name = "ask", id = "first", extra: Record<string, unknown> = {}) {
      const waiter = waiters();
      const response = await handleDiscordInteractionsRequest(
        await signedRequest(privateKey, command(name, [
          { name: name === "ask" ? "question" : "report", value: "Help with food logging" },
        ], { id, ...extra })), bindings, waiter.ctx,
      );
      expect(await response.json()).toEqual({ type: 5 });
      return waiter;
    }
    const aiCalls = () => fetch.mock.calls.filter(([url]) => new URL(String(url)).hostname === "generativelanguage.googleapis.com");
    const replies = () => fetch.mock.calls.filter(([url]) => new URL(String(url)).hostname === "discord.com")
      .map(([, init]) => JSON.parse(requestBody(init)).content as string);
    return { bindings, fetch, warnings, send, aiCalls, replies };
  }

  it("suppresses replays and blocks new questions without extending cooldown", async () => {
    const h = await setup();
    const now = Date.now();
    vi.spyOn(Date, "now").mockReturnValue(now);
    await (await h.send()).flush();
    await (await h.send()).flush();
    expect(h.replies()).toHaveLength(1);
    vi.spyOn(Date, "now").mockReturnValue(now + 30_000);
    await (await h.send("ask", "second")).flush();
    expect(h.replies().at(-1)).toContain("wait a minute");
    expect(h.aiCalls()).toHaveLength(1);
    vi.spyOn(Date, "now").mockReturnValue(now + 60_001);
    await (await h.send("ask", "third")).flush();
    expect(h.aiCalls()).toHaveLength(2);
    await (await h.send()).flush();
    expect(h.aiCalls()).toHaveLength(2);
  });

  it("keeps cooldown values readable by the deployed numeric reader", async () => {
    const h = await setup();
    const writes = vi.spyOn(h.bindings.DISCORD_STATE, "put");
    await (await h.send()).flush();
    const cooldown = writes.mock.calls.find(([key]) => key.includes(":cooldown:"));
    expect(Number(cooldown?.[1])).toBeGreaterThan(Date.now());
    expect(cooldown?.[2].metadata?.owner).toBeTruthy();
  });

  it("shares the report cooldown across bug/feature and channels, but scopes by user and server", async () => {
    const h = await setup();
    await (await h.send("bug")).flush();
    await (await h.send("feature", "second", { channel_id: "different" })).flush();
    expect(h.replies().at(-1)).toContain("10 minutes");
    expect(h.aiCalls()).toHaveLength(1);
    await (await h.send("ask", "question")).flush();
    await (await h.send("feature", "other-user", { member: { user: { id: "user-2" } } })).flush();
    await (await h.send("feature", "other-server", { guild_id: "server-2" })).flush();
    expect(h.aiCalls()).toHaveLength(4);
  });

  it("doubles the report wait for each report in a streak, up to a day", async () => {
    const h = await setup();
    let clock = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    const writes = vi.spyOn(h.bindings.DISCORD_STATE, "put");
    const minute = 60_000;
    const sent: number[] = [];
    // Report again the moment each wait ends: 10, 20, 40, 80, 160, 320, 640 and 1280 minutes, then the cap.
    for (const wait of [10, 20, 40, 80, 160, 320, 640, 1280, 1440, 1440, 1440, 1440, 1440, 1440]) {
      sent.push(clock);
      await (await h.send(sent.length % 2 ? "bug" : "feature", `report-${sent.length}`)).flush();
      expect(h.aiCalls()).toHaveLength(sent.length);
      clock += minute;
      await (await h.send("bug", `early-${sent.length}`)).flush();
      expect(h.replies().at(-1)).toContain(`another report in ${formatWait((wait - 1) * minute)}`);
      expect(h.aiCalls()).toHaveLength(sent.length);
      clock += (wait - 1) * minute + 1;
    }
    // Only the latest 12 report times are kept.
    const cooldowns = writes.mock.calls.filter(([key]) => key.includes(":cooldown:"));
    expect(cooldowns.at(-1)?.[2].metadata?.reports).toEqual(sent.slice(-12));
  });

  it("stores each report's streak in KV, so another isolate escalates the next wait", async () => {
    const h = await setup();
    let clock = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    const state = h.bindings.DISCORD_STATE;
    const writes = vi.spyOn(state, "put");
    const lastCooldown = () => writes.mock.calls.filter(([key]) => key.includes(":cooldown:")).at(-1)?.slice(1);
    const first = clock;
    await (await h.send("bug", "first")).flush();
    expect(lastCooldown()).toEqual([
      String(first + 10 * 60_000),
      { expirationTtl: 172_800, metadata: { owner: expect.any(String), reports: [first] } },
    ]);
    clock += 10 * 60_000 + 1;
    const second = clock;
    // Fresh bindings simulate other isolates, which only see what KV stored.
    h.bindings.DISCORD_STATE = { ...state };
    await (await h.send("feature", "second")).flush();
    expect(h.aiCalls()).toHaveLength(2);
    expect(lastCooldown()).toEqual([
      String(second + 20 * 60_000),
      { expirationTtl: 172_800, metadata: { owner: expect.any(String), reports: [first, second] } },
    ]);
    clock += 60_000;
    h.bindings.DISCORD_STATE = { ...state };
    await (await h.send("bug", "early")).flush();
    expect(h.replies().at(-1)).toContain("another report in 19 minutes");
  });

  it("starts over after two days without a report", async () => {
    const h = await setup();
    let clock = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    await (await h.send("bug", "first")).flush();
    clock += 10 * 60_000 + 1;
    await (await h.send("feature", "second")).flush();
    clock += 48 * 60 * 60_000 + 1;
    await (await h.send("bug", "next-day")).flush();
    expect(h.aiCalls()).toHaveLength(3);
    clock += 60_000;
    await (await h.send("bug", "early")).flush();
    expect(h.replies().at(-1)).toContain("another report in 9 minutes");
  });

  it.each([0, 16, 21])("does not count a report rolled back %i minutes before the retry", async (minutes) => {
    const h = await setup();
    let clock = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    await (await h.send("bug", "first")).flush();
    clock += 10 * 60_000 + 1;
    const state = h.bindings.DISCORD_STATE;
    const put = state.put.bind(state);
    const writes = vi.spyOn(state, "put").mockImplementation(async (key, value, options) => {
      if (key.includes(":interaction:")) throw new Error("write failed");
      await put(key, value, options);
    });
    await (await h.send("feature", "failed")).flush();
    expect(h.replies().at(-1)).toContain("unavailable");
    // The failed attempt's cooldown record lives two days, so its cancellation must too.
    const marker = writes.mock.calls.find(([key]) => key.startsWith("fuddy:aborted:"));
    expect(marker?.[2].expirationTtl).toBe(172_800);
    writes.mockRestore();
    // At 16 minutes the failed attempt's record still holds a 20-minute wait; at 21 only its history.
    clock += minutes * 60_000;
    h.bindings.DISCORD_STATE = { ...state };
    await (await h.send("feature", "retry")).flush();
    expect(h.aiCalls()).toHaveLength(2);
    clock += 60_000;
    await (await h.send("bug", "early")).flush();
    // Two real reports, so 20 minutes, not the 40 a counted failure would give.
    expect(h.replies().at(-1)).toContain("another report in 19 minutes");
  });

  it("reserves locally before concurrent KV reads complete", async () => {
    const h = await setup();
    const state = h.bindings.DISCORD_STATE;
    const get = state.get.bind(state);
    let unblock!: () => void;
    const blocked = new Promise<void>((resolve) => { unblock = resolve; });
    const reads = vi.spyOn(state, "get").mockImplementation(async (key) => { await blocked; return get(key); });
    const first = await h.send();
    await vi.waitFor(() => expect(reads).toHaveBeenCalledTimes(1));
    await (await h.send("ask", "second")).flush();
    expect(h.aiCalls()).toHaveLength(0);
    expect(h.replies().at(-1)).toContain("wait a minute");
    unblock();
    await first.flush();
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("tells a concurrent report that the previous one is still being sent", async () => {
    const h = await setup();
    const state = h.bindings.DISCORD_STATE;
    const get = state.get.bind(state);
    let unblock!: () => void;
    const blocked = new Promise<void>((resolve) => { unblock = resolve; });
    const reads = vi.spyOn(state, "get").mockImplementation(async (key) => { await blocked; return get(key); });
    const first = await h.send("bug");
    await vi.waitFor(() => expect(reads).toHaveBeenCalledTimes(1));
    await (await h.send("feature", "second")).flush();
    expect(h.replies().at(-1)).toContain("Your previous report is still being sent.");
    unblock();
    await first.flush();
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("lifts a cooldown it read from KV once that attempt's cancellation lands", async () => {
    const h = await setup();
    let clock = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    const state = h.bindings.DISCORD_STATE;
    const put = state.put.bind(state);
    let unblock!: () => void;
    const blocked = new Promise<void>((resolve) => { unblock = resolve; });
    const writes = vi.spyOn(state, "put").mockImplementation(async (key, value, options) => {
      const marker = key.startsWith("fuddy:aborted:");
      if (marker) await blocked;
      await put(key, value, options);
      if (!marker) throw new Error("acknowledgement lost");
    });
    const first = await h.send("bug", "first");
    await vi.waitFor(() => expect(h.replies().at(-1)).toContain("unavailable"));
    writes.mockRestore();
    // Another isolate reads the failed attempt's record before its cancellation lands.
    h.bindings.DISCORD_STATE = { ...state };
    await (await h.send("feature", "early")).flush();
    expect(h.replies().at(-1)).toContain("another report in 10 minutes");
    unblock();
    await first.flush();
    clock += 60_001;
    await (await h.send("feature", "after-rollback")).flush();
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("keeps a cooldown it read from KV when a later read misses it", async () => {
    const h = await setup();
    let clock = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    await (await h.send("bug", "first")).flush();
    const isolate = { ...h.bindings.DISCORD_STATE };
    h.bindings.DISCORD_STATE = isolate;
    clock += 60_000;
    await (await h.send("feature", "early")).flush();
    expect(h.replies().at(-1)).toContain("another report in 9 minutes");
    // An eventually consistent read that misses the record must not end the wait early.
    isolate.getWithMetadata = async () => ({ value: null, metadata: null });
    clock += 60_001;
    await (await h.send("feature", "stale-read")).flush();
    expect(h.replies().at(-1)).toContain("another report in 8 minutes");
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("tells a report sent while the previous one is still saving that it is still being sent", async () => {
    const h = await setup();
    const state = h.bindings.DISCORD_STATE;
    const put = state.put.bind(state);
    let unblock!: () => void;
    const blocked = new Promise<void>((resolve) => { unblock = resolve; });
    const writes = vi.spyOn(state, "put").mockImplementation(async (...args) => { await blocked; await put(...args); });
    const first = await h.send("bug");
    await vi.waitFor(() => expect(writes).toHaveBeenCalled());
    await (await h.send("feature", "second")).flush();
    expect(h.replies().at(-1)).toContain("Your previous report is still being sent.");
    unblock();
    await first.flush();
    expect(h.aiCalls()).toHaveLength(1);
    await (await h.send("feature", "third")).flush();
    expect(h.replies().at(-1)).toContain("another report in 10 minutes");
  });

  it("retries a cancellation that fails to save", async () => {
    const h = await setup();
    const state = h.bindings.DISCORD_STATE;
    const put = state.put.bind(state);
    let cancellationFailures = 1;
    const writes = vi.spyOn(state, "put").mockImplementation(async (key, value, options) => {
      if (key.includes(":interaction:")) throw new Error("write failed");
      if (key.startsWith("fuddy:aborted:") && cancellationFailures-- > 0) throw new Error("cancellation failed");
      await put(key, value, options);
    });
    await (await h.send("bug", "failed")).flush();
    expect(writes.mock.calls.filter(([key]) => key.startsWith("fuddy:aborted:"))).toHaveLength(2);
    writes.mockRestore();
    h.bindings.DISCORD_STATE = { ...state };
    await (await h.send("bug", "retry")).flush();
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("releases failed reads so both the same interaction and fresh commands can retry", async () => {
    const h = await setup();
    const get = vi.spyOn(h.bindings.DISCORD_STATE, "get");
    get.mockRejectedValueOnce(new Error("secret-bearing error"));
    await (await h.send()).flush();
    expect(h.aiCalls()).toHaveLength(0);
    expect(h.replies().at(-1)).toContain("unavailable");
    expect(h.warnings).toHaveBeenCalledWith("discord_cooldown_state_unavailable", {
      stage: "read", reason: "operation_failed",
    });
    expect(JSON.stringify(h.warnings.mock.calls)).not.toContain("secret-bearing");
    await (await h.send()).flush();
    expect(h.aiCalls()).toHaveLength(1);
    get.mockRejectedValueOnce(new Error("outage"));
    await (await h.send("bug", "failed-report")).flush();
    await (await h.send("feature", "fresh-report")).flush();
    expect(h.aiCalls()).toHaveLength(2);
  });

  it.each(["interaction", "cooldown"])("rolls back a partial %s write failure before retry", async (failedKey) => {
    const h = await setup();
    const state = h.bindings.DISCORD_STATE;
    const put = state.put.bind(state);
    const writes = vi.spyOn(state, "put").mockImplementation(async (key, value, options) => {
      if (key.includes(`:${failedKey}:`)) throw new Error("write failed");
      await put(key, value, options);
    });
    await (await h.send()).flush();
    expect(h.aiCalls()).toHaveLength(0);
    expect(h.replies().at(-1)).toContain("unavailable");
    expect(writes.mock.calls.some(([key]) => key.startsWith("fuddy:aborted:"))).toBe(true);
    expect(h.warnings).toHaveBeenCalledWith("discord_cooldown_state_unavailable", {
      stage: "write", reason: "operation_failed",
    });
    writes.mockRestore();
    // A fresh binding simulates another isolate reading the surviving KV data.
    h.bindings.DISCORD_STATE = { ...state };
    await (await h.send()).flush();
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("cleans writes that commit and then reject", async () => {
    const h = await setup();
    const state = h.bindings.DISCORD_STATE;
    const put = state.put.bind(state);
    const writes = vi.spyOn(state, "put").mockImplementation(async (...args) => {
      await put(...args);
      if (!args[0].startsWith("fuddy:aborted:")) throw new Error("acknowledgement lost");
    });
    await (await h.send()).flush();
    writes.mockRestore();
    h.bindings.DISCORD_STATE = { ...state };
    await (await h.send()).flush();
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("preserves another owner's reservation during failed-write cleanup", async () => {
    const h = await setup();
    const state = h.bindings.DISCORD_STATE;
    const put = state.put.bind(state);
    const writes = vi.spyOn(state, "put").mockImplementation(async (key, value, options) => {
      if (key.includes(":interaction:")) throw new Error("failed");
      if (key.includes(":cooldown:")) {
        await put(key, String(Date.now() + 60_000), { ...options, metadata: { owner: "another-owner" } });
      } else {
        await put(key, value, options);
      }
    });
    await (await h.send()).flush();
    expect(writes.mock.calls.some(([key]) => key.startsWith("fuddy:aborted:"))).toBe(true);
    writes.mockRestore();
    await (await h.send("ask", "fresh")).flush();
    expect(h.replies().at(-1)).toContain("wait a minute");
    expect(h.aiCalls()).toHaveLength(0);
  });

  it("releases local reservations after write cleanup for a fresh command", async () => {
    const h = await setup();
    const put = h.bindings.DISCORD_STATE.put.bind(h.bindings.DISCORD_STATE);
    const writes = vi.spyOn(h.bindings.DISCORD_STATE, "put").mockImplementation(async (...args) => {
      if (args[0].startsWith("fuddy:aborted:")) return put(...args);
      throw new Error("failed");
    });
    await (await h.send("bug")).flush();
    writes.mockRestore();
    await (await h.send("feature", "retry")).flush();
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("releases a read timeout without logging raw errors", async () => {
    const h = await setup();
    vi.spyOn(h.bindings.DISCORD_STATE, "get").mockImplementationOnce(() => new Promise(() => {}));
    await (await h.send()).flush();
    expect(h.warnings).toHaveBeenCalledWith("discord_cooldown_state_unavailable", {
      stage: "read", reason: "timeout",
    });
    await (await h.send()).flush();
    expect(h.aiCalls()).toHaveLength(1);
  });

  it("waits for late writes before rollback so they cannot resurrect failed reservations", async () => {
    const h = await setup();
    const state = h.bindings.DISCORD_STATE;
    const put = state.put.bind(state);
    let unblock!: () => void;
    const blocked = new Promise<void>((resolve) => { unblock = resolve; });
    const writes = vi.spyOn(state, "put").mockImplementation(async (...args) => {
      await blocked;
      await put(...args);
    });
    const first = await h.send();
    await vi.waitFor(() => expect(h.replies().at(-1)).toContain("unavailable"), { timeout: 2500 });
    expect(h.aiCalls()).toHaveLength(0);
    expect(h.warnings).toHaveBeenCalledWith("discord_cooldown_state_unavailable", {
      stage: "write", reason: "timeout",
    });
    const clock = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 31_000);
    await (await h.send("ask", "during-cleanup")).flush();
    clock.mockRestore();
    expect(h.replies().at(-1)).toContain("unavailable");
    unblock();
    await first.flush();
    writes.mockRestore();
    h.bindings.DISCORD_STATE = { ...state };
    await (await h.send()).flush();
    expect(h.aiCalls()).toHaveLength(1);
  });
});

describe("report cooldown helpers", () => {
  it("doubles from 10 minutes and caps at a day", () => {
    expect([1, 2, 3, 4, 8, 9, 20].map(reportCooldownSeconds)).toEqual([600, 1200, 2400, 4800, 76_800, 86_400, 86_400]);
    expect(reportCooldownSeconds(0)).toBe(600);
  });

  it("keeps the current streak of valid report times and drops an aborted attempt's own entry", () => {
    const now = 1_800_000_000_000;
    const day = 86_400_000;
    // Two days between the first two reports ends that streak.
    const metadata = { owner: "o", reports: [now - 3 * day, now - day + 1, "x", Number.NaN, now + 5, now - 1_000] };
    expect(recentReports(metadata, false, now)).toEqual([now - day + 1, now - 1_000]);
    expect(recentReports({ owner: "o", reports: [now - 5 * day, now - 4 * day] }, false, now)).toEqual([]);
    expect(recentReports({ owner: "o", reports: [now - 3 * day, now - 1.5 * day, now - 1_000] }, false, now))
      .toEqual([now - 3 * day, now - 1.5 * day, now - 1_000]);
    expect(recentReports({ owner: "o", reports: [now - 2_000, now - 1_000] }, true, now)).toEqual([now - 2_000]);
    expect(recentReports({ owner: "o" }, false, now)).toEqual([]);
    expect(recentReports(null, false, now)).toEqual([]);
    const long = Array.from({ length: 30 }, (_, i) => now - 30_000 + i * 1_000);
    expect(recentReports({ owner: "o", reports: long }, false, now)).toHaveLength(12);
  });

  it("formats waits in minutes and hours", () => {
    expect(formatWait(1)).toBe("1 minute");
    expect(formatWait(9 * 60_000)).toBe("9 minutes");
    expect(formatWait(60 * 60_000)).toBe("1 hour");
    expect(formatWait(80 * 60_000)).toBe("1 hour 20 minutes");
    expect(formatWait(1_279 * 60_000)).toBe("21 hours 19 minutes");
  });
});

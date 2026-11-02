import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { afterEach, vi, expect } from "vitest";
import { recordNative } from "./bridge.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { randomUUID } from "node:crypto";

const { startOAuthCallbackServer } = await import(pathToFileURL(path.join(
  process.env.PI_CONFORMANCE_UPSTREAM, "packages/ai/src/auth/oauth/callback-server.ts")));

const active = new Set();
import { addNativeClockCall, removeNativeClockCall, nativeClockChanged as changed } from "./native-clock.mjs";

afterEach(() => {
  for (const call of active) call.cancel();
});

export function wrapAuthorization(provider, source, configuration = {}) {
  const observed = operation => {
    const result = operation();
    result.catch(() => {});
    return result;
  };
  return {
    ...source,
    login: (options, loginOptions) => observed(() => authorize(provider, "login", undefined, options, { ...configuration, ...loginOptions })),
    refresh: (credential, signal) => observed(() => authorize(provider, "refresh", credential, { signal }, configuration)),
    toAuth: credential => observed(() => authorize(provider, "toAuth", credential, {}, configuration)),
  };
}

export function wrapPrimaryAuthorization(provider, source, variables) {
  return { ...source,
    resolve: input => authorize(provider, "primary.resolve", input.credential,
      { signal: input.signal }, { context: input.ctx, variables, name: source.name }).then(value => value ?? undefined),
    login: interaction => authorize(provider, "primary.login", undefined, interaction, { name: source.name }),
  };
}

export async function personalizeOpenRouterCatalog(catalog, context) {
  const result = await authorize("openrouter", "catalog.personalize", context.credential,
    { signal: context.signal }, { catalog, baseURL: context.baseUrl });
  return result.personalized ? result.models.map(value => value.updated ? value.model : catalog[value.index]) : catalog;
}

async function authorize(provider, action, credential, options, configuration) {
  const call = { phase: "host", deadline: Infinity, cancel: () => {} };
  active.add(call);
  addNativeClockCall(call);
  let child;
  let timer;
  let stopped = false;
  let finished = false;
  let cancel;
  let callback;
  let callbackOptions;
  let callbackCode;
  try {
    let method;
    let resolveResult;
    let rejectResult;
    const result = new Promise((resolve, reject) => { resolveResult = resolve; rejectResult = reject; });
    result.catch(() => {});
    const prepareCallback = async () => {
      let receiveCode, rejectCode;
      callbackCode = new Promise((resolve, reject) => { receiveCode = resolve; rejectCode = reject; });
      callbackCode.catch(() => {});
      callbackOptions = {
        providerName: provider === "openrouter" ? "OpenRouter" : "Anthropic",
        host: process.env.PI_OAUTH_CALLBACK_HOST || "127.0.0.1",
        port: provider === "openrouter" ? 0 : 53692,
        path: provider === "openrouter" ? `/oauth/callback/${randomUUID()}` : "/callback",
        ...(provider === "anthropic" ? { redirectHost: "localhost" } : { timeoutMs: 5 * 60 * 1000 }),
        signal: options.signal,
        complete: async code => {
          receiveCode({ type: "callback", value: code + (callbackOptions.state ? "#" + callbackOptions.state : "") });
          return provider === "openrouter" ? await result : code;
        },
      };
      try { callback = await startOAuthCallbackServer(callbackOptions); }
      catch (error) {
        if (provider !== "anthropic") throw error;
        callbackOptions.port = 0;
        callback = await startOAuthCallbackServer(callbackOptions);
      }
      callback.wait().catch(rejectCode);
    };
    if (action === "login" && provider === "openrouter" && !options.signal?.aborted) await prepareCallback();
    call.phase = "starting";
    child = spawn(process.env.PI_CONFORMANCE_PROBE, ["--stream"], { stdio: ["pipe", "pipe", "pipe"] });
    let stderr = "";
    child.stderr.on("data", data => { stderr += data; });
    child.stdin.on("error", () => {});
    const send = frame => {
      if (!stopped && !child.stdin.destroyed && !child.stdin.writableEnded) child.stdin.write(JSON.stringify(frame) + "\n");
    };
    const reply = value => { call.phase = "running"; send({ kind: "reply", value: { ...value, now: Date.now() } }); changed(); };
    const fail = error => { call.phase = "running"; send({ kind: "reply", error: error.message }); changed(); };
    call.cancel = () => {
      stopped = true;
      clearTimeout(timer);
      child.kill();
      active.delete(call); removeNativeClockCall(call);
      changed();
      rejectResult(new Error("Authorization test ended before its Native operation completed"));
    };
    cancel = () => { clearTimeout(timer); send({ kind: "cancel" }); };
    options.signal?.addEventListener("abort", cancel, { once: true });
    child.once("error", rejectResult);
    child.once("close", code => {
      if (!finished) rejectResult(new Error(`Native authorization probe exited (${code}): ${stderr}`));
      active.delete(call); removeNativeClockCall(call);
      changed();
    });
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on("line", line => {
      if (stopped) return;
      const { kind, payload } = JSON.parse(line);
      if (kind === "authStarted") {
        recordNative(payload.operation, "*");
        call.phase = "running";
      } else if (kind === "authSleep") {
        call.phase = "sleep";
        call.deadline = Date.now() + payload.milliseconds;
        timer = setTimeout(() => reply({}), payload.milliseconds);
      } else if (kind === "authEnvironment" || kind === "authFileExists") {
        call.phase = "request";
        void (async () => reply({ value: kind === "authEnvironment"
          ? await configuration.context.env(payload.name) : await configuration.context.fileExists(payload.path) }))().catch(fail);
      } else if (kind === "authRequest") {
        call.phase = "request";
        void (async () => {
          const response = await globalThis.fetch(payload.url, {
            method: payload.method, headers: payload.headers,
            ...(payload.body ? { body: Buffer.from(payload.body, "base64").toString("utf8") } : {}),
            signal: options.signal,
          });
          reply({ status: response.status, headers: Object.fromEntries(response.headers),
            body: Buffer.from(await response.arrayBuffer()).toString("base64") });
        })().catch(fail);
      } else if (kind === "authInteraction") {
        call.phase = payload.type === "url" || (payload.type === "prompt"
          && !["radius-gateway", "radius-login-method"].includes(payload.id)) ? "prompt" : "running";
        void (async () => {
          if (payload.type === "device") {
            options.notify({ type: "device_code", userCode: payload.userCode,
              verificationUri: new URL(payload.verificationUri).toString(), intervalSeconds: payload.intervalSeconds,
              expiresInSeconds: payload.expiresInSeconds });
            reply({});
          } else if (payload.type === "url") {
            if (provider === "radius") {
              const authorizeURL = new URL(payload.url);
              const redirect = new URL(authorizeURL.searchParams.get("redirect_uri"));
              let receiveCode, rejectCode;
              callbackCode = new Promise((resolve, reject) => { receiveCode = resolve; rejectCode = reject; });
              callbackCode.catch(() => {});
              callback = await startOAuthCallbackServer({
                providerName: configuration.name ?? "Radius", host: redirect.hostname,
                port: Number(redirect.port), path: redirect.pathname,
                state: authorizeURL.searchParams.get("state"), signal: options.signal,
                complete: async code => {
                  const value = new URL(redirect);
                  value.searchParams.set("code", code);
                  value.searchParams.set("state", authorizeURL.searchParams.get("state"));
                  receiveCode(value.toString());
                  return await result;
                },
              });
              callback.wait().catch(rejectCode);
              options.notify({ type: "auth_url", url: payload.url });
              reply({ value: await callbackCode });
              return;
            }
            if (callbackOptions && provider === "anthropic") callbackOptions.state = new URL(payload.url).searchParams.get("state");
            options.notify({ type: "auth_url", url: payload.url });
            const manual = new AbortController();
            try {
              const answer = options.prompt({ type: "manual_code", message: "Authorization code", signal: manual.signal });
              if (callback) {
                const chosen = await Promise.race([answer.then(value => ({ type: "manual", value })), callbackCode]);
                if (chosen.type === "manual") callback.cancel();
                reply({ value: chosen.value });
              } else reply({ value: await answer });
            } finally { manual.abort(); }
          } else if (payload.type === "select") {
            method = await options.prompt({ type: "select", message: payload.message, options: payload.options });
            if (provider === "anthropic" && method === "browser") await prepareCallback();
            reply({ value: method, callbackURL: callback?.redirectUri });
          } else if (payload.type === "info") {
            options.notify({ type: "info", message: payload.message, links: payload.links });
            reply({});
          } else if (payload.type === "progress") {
            options.notify({ type: "progress", message: payload.message });
            reply({});
          } else if (payload.id === "radius-gateway") reply({ value: configuration.gateway });
          else if (payload.id === "radius-login-method") reply({ value: method });
          else reply({ value: await options.prompt({ type: payload.kind === "secret" ? "secret" : "text", message: payload.message }) });
        })().catch(fail);
      } else if (kind === "authFinished") {
        finished = true;
        clearTimeout(timer);
        active.delete(call); removeNativeClockCall(call);
        child.stdin.end();
        if (payload.failure) {
          recordNative(`authorization.${provider}.${action}`, "*", payload.failure,
            payload.failure.capability ? [payload.failure.capability] : []);
          rejectResult(new Error(payload.failure.code === "cancelled" ? "Login cancelled" : payload.failure.message));
        } else if (Object.hasOwn(payload, "primary")) {
          resolveResult(payload.primary);
        } else if (payload.auth) {
          resolveResult(payload.auth);
        } else {
          const { metadata = {}, ...value } = payload.credential;
          if (metadata.accountID) value.accountId = metadata.accountID;
          if (metadata.enterpriseDomain) value.enterpriseDomain = metadata.enterpriseDomain;
          if (provider === "github-copilot" && metadata.enterpriseDomain) value.enterpriseUrl = metadata.enterpriseUrl ?? metadata.enterpriseDomain;
          if (metadata.availableModelIDs !== undefined) value.availableModelIds = metadata.availableModelIDs ? metadata.availableModelIDs.split(",") : [];
          if (metadata.scope) value.scope = metadata.scope;
          if (metadata.clientID) value.clientId = metadata.clientID;
          if (metadata.scopes) value.scopes = JSON.parse(metadata.scopes);
          if (provider === "openrouter" && action === "refresh") {
            expect(value).toEqual(credential);
            resolveResult(credential);
          } else resolveResult(value);
        }
      } else throw new Error("Unexpected Native authorization frame: " + kind);
      changed();
    });
    send({ operation: "authorization", provider, action, credential, method, agentName: configuration.agentName,
      deviceID: configuration.getDeviceId?.(), now: Date.now(),
      primaryName: configuration.name, variables: configuration.variables, aborted: options.signal?.aborted,
      catalog: configuration.catalog, baseURL: configuration.baseURL,
      gateway: configuration.gateway, oauthHost: process.env.KIMI_CODE_OAUTH_HOST, callbackURL: callback?.redirectUri });
    if (options.signal?.aborted) cancel();
    return await result;
  } finally {
    active.delete(call); removeNativeClockCall(call);
    changed();
    options.signal?.removeEventListener("abort", cancel);
    clearTimeout(timer);
    if (callback) {
      callback.cancel();
      await callback.wait().catch(() => {});
      callback.close();
    }
    if (child && !finished) child.kill();
  }
}

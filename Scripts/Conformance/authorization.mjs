import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { afterEach, vi } from "vitest";
import { recordNative } from "./bridge.mjs";

const active = new Set();
let observers = [];
const yieldIO = globalThis.setImmediate;
const advance = vi.advanceTimersByTimeAsync.bind(vi);
const changed = () => { for (const resolve of observers.splice(0)) resolve(); };
const nextChange = () => new Promise(resolve => observers.push(resolve));

async function idle() {
  await new Promise(yieldIO);
  while ([...active].some(call => ["starting", "running", "host", "request"].includes(call.phase))) await nextChange();
}

// Advance both implementations at the same timer boundaries. Native resumes
// through process I/O, which fake JavaScript timers do not flush themselves.
vi.advanceTimersByTimeAsync = async milliseconds => {
  if (!active.size) return advance(milliseconds);
  const target = Date.now() + milliseconds;
  do {
    await idle();
    const deadline = Math.min(target, ...[...active].filter(call => call.phase === "sleep").map(call => call.deadline));
    await advance(Math.max(0, deadline - Date.now()));
    await idle();
  } while (Date.now() < target);
  return vi;
};

afterEach(() => {
  for (const call of active) call.cancel();
});

export function wrapAuthorization(provider, source, configuration = {}) {
  return {
    ...source,
    login: options => authorize(provider, "login", undefined, options, configuration),
    refresh: (credential, signal) => authorize(provider, "refresh", credential, { signal }, configuration),
  };
}

async function authorize(provider, action, credential, options, configuration) {
  const call = { phase: "host", deadline: Infinity, cancel: () => {} };
  active.add(call);
  let child;
  let timer;
  let stopped = false;
  let finished = false;
  let cancel;
  try {
    let method;
    if (action === "login" && ["anthropic", "openai-codex", "radius"].includes(provider)) {
      method = await options.prompt({ type: "select", message: "Sign in:", options: [
        { id: "browser", label: "Browser" },
        { id: provider === "anthropic" ? "copy_code" : provider === "radius" ? "device-code" : "device_code", label: "Code" },
      ] });
      if ((provider === "anthropic" && method !== "browser") || (provider === "openai-codex" && method !== "device_code")) {
        recordNative(`authorization.${provider}.${action}`, "*", undefined, [`${provider}-${method}-authorization-method`]);
        throw new Error("The requested authorization method is not represented by the Native adapter");
      }
    }
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
    let resolveResult;
    let rejectResult;
    const result = new Promise((resolve, reject) => { resolveResult = resolve; rejectResult = reject; });
    call.cancel = () => {
      stopped = true;
      clearTimeout(timer);
      child.kill();
      active.delete(call);
      changed();
      rejectResult(new Error("Authorization test ended before its Native operation completed"));
    };
    cancel = () => { clearTimeout(timer); send({ kind: "cancel" }); };
    options.signal?.addEventListener("abort", cancel, { once: true });
    child.once("error", rejectResult);
    child.once("close", code => {
      if (!finished) rejectResult(new Error(`Native authorization probe exited (${code}): ${stderr}`));
      active.delete(call);
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
              verificationUri: payload.verificationUri, intervalSeconds: payload.intervalSeconds,
              expiresInSeconds: payload.expiresInSeconds });
            reply({});
          } else if (payload.type === "url") {
            options.notify({ type: "auth_url", url: payload.url });
            reply({ value: await options.prompt({ type: "manual_code", message: "Authorization code", signal: options.signal }) });
          } else if (payload.type === "progress") {
            options.notify({ type: "progress", message: payload.message });
            reply({});
          } else if (payload.id === "radius-gateway") reply({ value: configuration.gateway });
          else if (payload.id === "radius-login-method") reply({ value: method });
          else reply({ value: await options.prompt({ type: "text", message: payload.message }) });
        })().catch(fail);
      } else if (kind === "authFinished") {
        finished = true;
        clearTimeout(timer);
        active.delete(call);
        child.stdin.end();
        if (payload.failure) {
          recordNative(`authorization.${provider}.${action}`, "*", payload.failure,
            payload.failure.capability ? [payload.failure.capability] : []);
          rejectResult(new Error(payload.failure.code === "cancelled" ? "Login cancelled" : payload.failure.message));
        } else {
          const { metadata = {}, ...value } = payload.credential;
          if (metadata.accountID) value.accountId = metadata.accountID;
          if (metadata.enterpriseDomain) value.enterpriseDomain = metadata.enterpriseDomain;
          if (metadata.scope) value.scope = metadata.scope;
          resolveResult(value);
        }
      } else throw new Error("Unexpected Native authorization frame: " + kind);
      changed();
    });
    send({ operation: "authorization", provider, action, credential, now: Date.now(),
      gateway: configuration.gateway, oauthHost: process.env.KIMI_CODE_OAUTH_HOST });
    if (options.signal?.aborted) cancel();
    return await result;
  } finally {
    active.delete(call);
    changed();
    options.signal?.removeEventListener("abort", cancel);
    clearTimeout(timer);
    if (child && !finished) child.kill();
  }
}

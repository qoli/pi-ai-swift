import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Adaptation fixture revision mismatch");
const now = 1700000000000;
const oldNow = Date.now;
Date.now = () => now;
const cases = [];
const api = {};
for (const name of ["typesafe-system-one", "cloudflare-workers-ai-system-one", "openai-decisions", "llama-cpp-classify"]) {
  api[name] = await import(pathToFileURL(path.join(root, "packages/ai/src/api", name + ".ts")));
}
const { metaOAuth } = await import(pathToFileURL(path.join(root, "packages/ai/src/auth/oauth/meta.ts")));
const { openaiChatGPTOAuth } = await import(pathToFileURL(path.join(root, "packages/ai/src/auth/oauth/openai-chatgpt.ts")));
const { kimiCodingOAuth } = await import(pathToFileURL(path.join(root, "packages/ai/src/auth/oauth/kimi-coding.ts")));
delete process.env.KIMI_CODE_OAUTH_HOST;
delete process.env.KIMI_OAUTH_HOST;
const setTimer = globalThis.setTimeout;
let delays;
globalThis.setTimeout = (callback, delay, ...args) => { delays.push(delay); return setTimer(callback, delay, ...args); };
const stable = value => value && typeof value === "object" ? Array.isArray(value) ? value.map(stable)
  : Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])])) : value;
for (const spec of fixture.cases) {
  const requests = [];
  delays = [];
  let completions = 0;
  const fetch = async (url, options) => {
    const headers = new Headers(options.headers);
    const body = headers.get("content-type")?.includes("application/x-www-form-urlencoded")
      ? Object.fromEntries(new URLSearchParams(String(options.body))) : JSON.parse(String(options.body));
    requests.push({ url: String(url), body, headers: Object.fromEntries(
      ["authorization", "content-type", "typesafe-danger-zone-images"].filter(name => headers.has(name)).map(name => [name, headers.get(name)])) });
    if (spec.model?.api === "llama-cpp-classify") {
      const endpoint = new URL(url).pathname;
      if (endpoint.endsWith("/tokenize")) return Response.json({ tokens: [...body.content].map(c => c.codePointAt(0)) });
      if (endpoint.endsWith("/apply-template")) return Response.json({ prompt: body.messages.map(m => `${m.role}\n${m.content}\n`).join("") });
      completions++;
      return Response.json({ completion_probabilities: [{ top_logprobs:
        spec.readoutEscalation && completions === 1 ? [{ id: 65, logprob: -0.1 }] : [{ id: 65, logprob: -0.1 }, { id: 66, logprob: -2.5 }] }] });
    }
    const first = spec.responseSequence?.[requests.length - 1];
    if (first) return Response.json(first.body, { status: first.status });
    return typeof spec.response === "string" ? new Response(spec.response, { status: spec.status ?? 200 })
      : Response.json(spec.response, { status: spec.status ?? 200 });
  };
  let result;
  if (spec.kind === "oauth") {
    globalThis.fetch = fetch;
    try {
      const auth = spec.provider === "meta" ? metaOAuth : spec.provider === "kimi-coding" ? kimiCodingOAuth : openaiChatGPTOAuth;
      const credential = await auth.refresh(spec.credential, new AbortController().signal);
      const { expires, ...rest } = credential;
      result = { ...rest, lifetimeSeconds: (expires - now) / 1000 };
    } catch (error) { result = { errorMessage: error.message }; }
  } else {
    const { timestamp, ...rest } = await api[spec.model.api].classify(spec.model, spec.context, { ...spec.options, fetch });
    result = rest;
  }
  const auxiliary = requests.filter(r => /\/(tokenize|apply-template)$/.test(r.url))
    .sort((a, b) => JSON.stringify(stable(a)).localeCompare(JSON.stringify(stable(b)), "en"));
  cases.push({ id: spec.id, result, requests: requests.filter(r => !/\/(tokenize|apply-template)$/.test(r.url)), auxiliary, delays });
}
Date.now = oldNow;
globalThis.setTimeout = setTimer;
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));

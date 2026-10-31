import { createInterface } from "node:readline";
import { recordNative, invokeNative } from "./bridge.mjs";
import { codexProbeChild } from "./native-session.mjs";

export function helper(name, args) {
  const value = invokeNative({ operation: "classifier.helper", name, args });
  recordNative(`classifier.${name}`, "*");
  return value;
}

export async function classify(selectedAPI, model, context, options = {}) {
  recordNative("classify", selectedAPI, undefined, [], "classify");
  const child = codexProbeChild();
  const requests = new Map();
  let output;
  let stderr = "";
  child.stderr.on("data", value => { stderr += value; });
  const closed = new Promise((resolve, reject) => { child.on("close", resolve); child.on("error", reject); });
  const send = value => child.stdin.write(JSON.stringify(value) + "\n");
  const cancel = () => { for (const controller of requests.values()) controller.abort(); send({ kind: "cancel" }); };
  options.signal?.addEventListener("abort", cancel, { once: true });
  send({ operation: "classifier", selectedAPI, model, context, options, aborted: options.signal?.aborted ?? false,
    identityHost: { platform: process.platform, arch: process.arch, node: process.versions.node, bun: process.versions.bun, version: process.version } });
  try {
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
    for await (const line of lines) {
      const { kind, payload } = JSON.parse(line);
      if (kind === "classifierRequest") {
        const { requestID, stage, value } = payload;
        void (async () => {
          let reply;
          if (stage === "http") {
            const controller = new AbortController();
            requests.set(requestID, controller);
            try {
              child.waiting?.();
              const response = await (options.fetch ?? globalThis.fetch)(value.url, { method: "POST", headers: value.headers,
                body: Buffer.from(value.body, "base64").toString("utf8"), signal: controller.signal });
              reply = { status: response.status, headers: Object.fromEntries(response.headers), body: Buffer.from(await response.arrayBuffer()).toString("base64") };
            } finally { requests.delete(requestID); }
          } else if (stage === "payload") {
            const replacement = await options.onPayload?.(value.payload, model);
            reply = { payload: replacement === undefined ? value.payload : replacement };
          } else if (stage === "response") { await options.onResponse?.(value, model); reply = {}; }
          else throw new Error(`Unknown classifier fixture stage: ${stage}`);
          send({ kind: "classifierReply", requestID, value: reply });
        })().catch(error => {
          if (error.name === "AssertionError") recordNative("assertion", selectedAPI,
            { code: "bridgeAssertion", operation: "conformance.classifier.assertion", message: error.message });
          send({ kind: "classifierReply", requestID, error: error.message });
        });
      } else if (kind === "classifierCancel") {
        requests.get(payload.requestID)?.abort();
      } else if (kind === "classifierFinished") output = payload;
      else if (kind === "finished") throw new Error(payload.message ?? "Native classifier fixture failed");
    }
    const code = await closed;
    if (code || !output) throw new Error(`Native classifier probe exited (${code}): ${stderr}`);
    return output;
  } finally {
    options.signal?.removeEventListener("abort", cancel);
    for (const controller of requests.values()) controller.abort();
  }
}

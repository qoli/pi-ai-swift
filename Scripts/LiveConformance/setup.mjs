import { appendFileSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { beforeEach, expect } from "vitest";
import { getCurrentTest } from "@vitest/runner";

beforeEach(({ task }) => {
  task.meta.piConformanceInstanceID = task.id;
  task.meta.liveAttempts = (task.meta.liveAttempts ?? 0) + 1;
});

const origin = new URL(process.env.PI_LIVE_ORIGIN);
const model = process.env.PI_LIVE_MODEL;
const connect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
  const values = Array.isArray(args[0]) ? args[0] : args;
  const opts = typeof values[0] === "object" ? values[0] : { host: values[1], port: values[0] };
  if (opts.host !== origin.hostname || Number(opts.port) !== 443) throw Error("Unselected network destination");
  return connect.apply(this, args);
};

const send = globalThis.fetch.bind(globalThis);
async function observe(input, init, native) {
  const url = new URL(input instanceof Request ? input.url : input);
  const task = getCurrentTest();
  if (!task || expect.getState().currentTestName !== process.env.PI_LIVE_CASE || url.origin !== origin.origin) throw Error("Unselected live request");
  const request = new Request(input, init);
  const body = await request.clone().arrayBuffer();
  const compressed = request.headers.get("content-encoding") === "zstd";
  const decoded = compressed ? (await import("node:zlib")).zstdDecompressSync(Buffer.from(body)) : Buffer.from(body);
  const target = JSON.parse(decoded.toString("utf8")).model ?? decodeURIComponent(url.pathname).match(/\/models\/([^/:]+):/)?.[1];
  if (target !== model) throw Error("Unselected live model");
  const witness = { instance: task.id, name: expect.getState().currentTestName, model, native };
  const file = path.join(process.env.PI_CONFORMANCE_OUTPUT, "wire.jsonl");
  let response;
  try {
    response = await send(request, { redirect: "error" });
    if (!response.ok) {
      const payload = await response.clone().text();
      // Keep only reviewed categories; error bodies may contain account information.
      for (const [reason, expression] of [
        ["max_tokens", /max[_ ](?:output[_ ])?(?:completion[_ ])?tokens|maxOutputTokens/i],
        ["opencode_session_header", /x-opencode-session/i], ["tool_choice", /tool_choice/i], ["message_role", /unexpected message role/i],
        ["subscription", /subscription/i], ["model_unavailable", /model.{0,40}(?:not found|not supported|unavailable)/i],
        ["authentication", /invalid.{0,16}(?:key|token)|unauthori[sz]ed/i],
        ["rate_limit", /rate.?limit/i],
      ]) {
        if (expression.test(payload)) { witness.reason = reason; break; }
      }
    }
  } finally {
    appendFileSync(file, JSON.stringify({ ...witness, status: response?.status ?? null }) + "\n");
  }
  return response;
}
globalThis.fetch = (input, init) => observe(input, init, false);
globalThis.piLiveWireFetch = (input, init) => observe(input, init, true);

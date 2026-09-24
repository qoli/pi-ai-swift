// Probe-only fetch capture/replay for an isolated, exact upstream checkout.
// Does not change upstream source or production catalog generation.
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";

const mode = process.env.SCHEMA6_MODE;
const directory = process.env.SCHEMA6_RESPONSES;
if (!["capture", "replay"].includes(mode) || !directory) {
  throw new Error("Set SCHEMA6_MODE=capture|replay and SCHEMA6_RESPONSES");
}
const root = resolve(directory);
if (mode === "capture") mkdirSync(root, { recursive: true });
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const originalFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  const file = join(root, `${digest(url)}.json`);
  if (mode === "replay") {
    const saved = JSON.parse(readFileSync(file, "utf8"));
    const bytes = Buffer.from(saved.body, "base64");
    if (saved.url !== url || digest(bytes) !== saved.sha256) {
      throw new Error(`Captured input integrity mismatch: ${url}`);
    }
    return new Response(bytes, { status: saved.status, headers: saved.headers });
  }
  const response = await originalFetch(input, init);
  const bytes = Buffer.from(await response.clone().arrayBuffer());
  writeFileSync(file, JSON.stringify({
    url, status: response.status,
    headers: { "content-type": response.headers.get("content-type") ?? "application/json" },
    sha256: digest(bytes), body: bytes.toString("base64"),
  }));
  return response;
};

import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { isDeepStrictEqual } from "node:util";
import { credentialProbeChild } from "./native-session.mjs";
import { recordNative } from "./native-operations.mjs";

const references = new WeakMap();
const objects = new Map();
function packet(value) {
  if (value === undefined) return null;
  let referenceID = references.get(value);
  if (!referenceID) {
    referenceID = randomUUID(); references.set(value, referenceID); objects.set(referenceID, value);
  }
  return { referenceID, value };
}
function value(packet) {
  if (packet === null) return undefined;
  const original = objects.get(packet.referenceID);
  return original && isDeepStrictEqual(JSON.parse(JSON.stringify(original)), packet.value) ? original : packet.value;
}

export class InMemoryCredentialStore {
  #id = randomUUID();
  read(providerId, options) { return this.#request("read", providerId, undefined, options); }
  list(options) { return this.#request("list", undefined, undefined, options); }
  modify(providerId, transform, options) { return this.#request("modify", providerId, transform, options); }
  delete(providerId, options) { return this.#request("delete", providerId, undefined, options); }

  #request(action, providerId, transform, options) {
    const child = credentialProbeChild();
    const errors = new Map();
    let finished = false;
    const signal = options?.signal;
    const send = frame => child.stdin.write(JSON.stringify(frame) + "\n");
    const cancel = () => send({ kind: "cancel" });
    signal?.addEventListener("abort", cancel, { once: true });
    return new Promise((resolve, reject) => {
      const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
      lines.on("line", line => {
        const { kind, payload } = JSON.parse(line);
        if (kind === "credentialTransform") {
          void (async () => {
            try {
              const result = await transform(value(payload.current));
              send({ kind: "credentialReply", requestID: payload.requestID, credential: packet(result) });
            } catch (error) {
              const id = randomUUID(); errors.set(id, error);
              send({ kind: "credentialReply", requestID: payload.requestID, error: { id, message: error.message } });
            }
          })();
        } else if (kind === "credentialResult") {
          finished = true;
          signal?.removeEventListener("abort", cancel);
          recordNative("credential-store." + action, "*");
          if (payload.error) {
            const error = payload.error.cancelled ? (signal?.reason ?? new DOMException("Aborted", "AbortError"))
              : errors.get(payload.error.id) ?? new Error(payload.error.message);
            reject(error);
          } else resolve(action === "list" ? payload.value : action === "delete" ? undefined : value(payload.value));
        } else if (!["callComplete", "lifetime"].includes(kind)) {
          reject(new Error("Unexpected credential store frame: " + kind));
        }
      });
      child.once("close", code => {
        signal?.removeEventListener("abort", cancel);
        if (!finished) reject(new Error("Native credential store exited before its result: " + code));
      });
      send({ operation: "credential-store", action, storeID: this.#id, provider: providerId, aborted: signal?.aborted });
    });
  }
}

import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { credentialPacket, credentialValue } from "./credential-store.mjs";
import { credentialProbeChild } from "./native-session.mjs";
import { recordNative } from "./native-operations.mjs";

const { ModelsError } = await import(pathToFileURL(path.join(
  process.env.PI_CONFORMANCE_UPSTREAM, "packages/ai/src/utils/models-error.ts")));
export { ModelsError };

export function resolveProviderAuth(provider, credentials, authContext, overrides = {}) {
  return request("authorization.resolve", provider, credentials, authContext, overrides);
}

export function refreshStoredOAuthCredential(credentials, providerId, oauth, needsRefresh, signal) {
  return request("authorization.refresh-stored", { id: providerId, auth: { oauth } }, credentials,
    undefined, { signal }, needsRefresh);
}

function request(operation, provider, credentials, authContext, overrides, needsRefresh) {
  const child = credentialProbeChild();
  const signal = overrides.signal ?? new AbortController().signal;
  const callbacks = new Map(), pending = new Map(), errors = new Map();
  let finished = false;
  const send = frame => child.stdin.write(JSON.stringify(frame) + "\n");
  const cancel = () => send({ kind: "cancel" });
  signal.addEventListener("abort", cancel, { once: true });
  function encodeError(error) {
    const id = randomUUID(); errors.set(id, error);
    return { id, message: error.message, nativeResolutionFailure: error.nativeResolutionFailure };
  }
  function decodeError(value) {
    if (value.cancelled) return signal.reason ?? new DOMException("Aborted", "AbortError");
    if (value.nativeResolutionFailure) {
      const native = value.nativeResolutionFailure;
      const result = new ModelsError(native.kind, native.message,
        native.cause ? { cause: decodeError(native.cause) } : undefined);
      Object.defineProperty(result, "nativeResolutionFailure", { value: native });
      return result;
    }
    return errors.get(value.id) ?? new Error(value.message);
  }
  function exchange(kind, fields) {
    const requestID = randomUUID();
    return new Promise((resolve, reject) => {
      pending.set(requestID, { resolve, reject });
      send({ kind, requestID, ...fields });
    });
  }
  async function callback(stage, value, controller) {
    switch (stage) {
      case "store.read": return credentialPacket(await credentials.read(value.provider, { signal }));
      case "store.list": return credentials.list({ signal });
      case "store.delete": await credentials.delete(value.provider, { signal: controller.signal }); return null;
      case "store.modify": return credentialPacket(await credentials.modify(value.provider,
        async current => credentialValue(await exchange("authorizationTransform", {
          transformID: value.transformID, credential: credentialPacket(current),
        })), { signal: controller.signal }));
      case "context.env": return authContext.env(value.argument);
      case "context.fileExists": return authContext.fileExists(value.argument);
      case "primary": return provider.auth.apiKey.resolve({
        credential: credentialValue(value.credential), signal,
        ctx: {
          env: name => exchange("authorizationContext", { contextID: value.contextID, action: "env", argument: name })
            .then(value => value ?? undefined),
          fileExists: path => exchange("authorizationContext", { contextID: value.contextID, action: "fileExists", argument: path }),
        },
      });
      case "oauth.refresh": return credentialPacket(await provider.auth.oauth.refresh(
        credentialValue(value.credential), controller.signal));
      case "oauth.toAuth": return provider.auth.oauth.toAuth(credentialValue(value.credential));
      case "oauth.needsRefresh": return needsRefresh(credentialValue(value.credential));
      default: throw new Error("Unknown Native authorization callback: " + stage);
    }
  }
  const result = new Promise((resolve, reject) => {
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on("line", line => {
      const { kind, payload } = JSON.parse(line);
      if (kind === "authorizationCallback") {
        const controller = new AbortController(); callbacks.set(payload.requestID, controller);
        void (async () => {
          try {
            const value = await callback(payload.stage, payload.value, controller);
            send({ kind: "authorizationReply", requestID: payload.requestID, value: value ?? null });
          } catch (error) {
            send({ kind: "authorizationReply", requestID: payload.requestID, error: encodeError(error) });
          } finally { callbacks.delete(payload.requestID); }
        })();
      } else if (kind === "authorizationCallbackCancel") {
        callbacks.get(payload.requestID)?.abort();
      } else if (["authorizationTransformResult", "authorizationContextResult"].includes(kind)) {
        const reply = pending.get(payload.requestID); pending.delete(payload.requestID);
        if (payload.error) reply?.reject(decodeError(payload.error)); else reply?.resolve(payload.value);
      } else if (kind === "authorizationResult") {
        finished = true; signal.removeEventListener("abort", cancel);
        recordNative(operation, "*", undefined, payload.unrepresentedCapabilities ?? []);
        if (payload.error) reject(decodeError(payload.error));
        else resolve(operation === "authorization.refresh-stored" ? credentialValue(payload.value) : payload.value ?? undefined);
      } else if (!["callComplete", "lifetime"].includes(kind)) {
        reject(new Error("Unexpected Native authorization frame: " + kind));
      }
    });
    child.once("close", code => {
      signal.removeEventListener("abort", cancel);
      if (!finished) reject(new Error("Native authorization exited before its result: " + code));
    });
    const { signal: ignoredSignal, ...values } = overrides;
    send({ operation, provider: provider.id, primary: !!provider.auth.apiKey,
      oauth: !!provider.auth.oauth, overrides: values, aborted: signal.aborted });
  });
  result.catch(() => {});
  return result;
}

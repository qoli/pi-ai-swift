import { createInterface } from "node:readline";
import { codexProbeChild } from "./native-session.mjs";
import { recordNative } from "./bridge.mjs";

export async function retryProviderRequest(request, options = {}) {
  return nativeCallbackOperation("provider.retry", request, {
    maximumRetries: options.maxRetries, maximumDelay: options.maxRetryDelayMs,
    noRetryStatuses: options.noRetryStatuses,
  }, options.signal);
}

export async function nativeCallbackOperation(operation, request, input, signal) {
  const child = codexProbeChild();
  const errors = new Map();
  let nextError = 0;
  const send = frame => child.stdin.write(JSON.stringify(frame) + "\n");
  const cancel = () => send({ kind: "cancel" });
  signal?.addEventListener("abort", cancel, { once: true });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  send({ operation, ...input });
  if (signal?.aborted) cancel();
  try {
    for await (const line of lines) {
      const frame = JSON.parse(line);
      if (frame.kind === "retryRequest") {
        void Promise.resolve().then(request).then(value => send({ kind: "retryReply", value }), error => {
          const reference = String(++nextError);
          errors.set(reference, error);
          send({ kind: "retryReply", error: { reference,
            providerError: error instanceof Error && "status" in error && "headers" in error
              && (error.status === undefined || typeof error.status === "number")
              && (error.headers === undefined || error.headers instanceof Headers),
            status: error.status, headers: error.headers instanceof Headers ? Object.fromEntries(error.headers) : undefined,
            message: error.message } });
        });
      } else if (frame.kind === "retryResult") {
        recordNative(operation, "*");
        if (frame.payload.errorReference) throw errors.get(frame.payload.errorReference);
        if (frame.payload.error) throw Object.assign(new Error(frame.payload.error), { name: frame.payload.name });
        return frame.payload.value;
      } else if (frame.kind === "finished" && frame.payload.message) throw new Error(frame.payload.message);
    }
    throw new Error("Native provider retry probe ended without a result");
  } finally {
    signal?.removeEventListener("abort", cancel);
    lines.close();
  }
}

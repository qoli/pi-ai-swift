import { invokeNative, recordNative } from "./bridge.mjs";

export function withOpenCodeSessionHeader(streams) {
  const optionsFor = options => {
    const result = invokeNative({ operation: "headers.open-code", sessionID: options?.sessionId, headers: options?.headers });
    recordNative("headers.open-code", "*");
    return result.changed ? { ...options, headers: result.headers } : options;
  };
  return { ...streams,
    stream: (model, context, options) => streams.stream(model, context, optionsFor(options)),
    streamSimple: (model, context, options) => streams.streamSimple(model, context, optionsFor(options)),
  };
}

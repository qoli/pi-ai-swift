export * from "pi-conformance:upstream-identity";
import { invokeNative, recordNative } from "./bridge.mjs";

function invoke(operation, input = {}) {
  const result = invokeNative({ operation, ...input, host: {
    platform: process.platform, arch: process.arch, node: process.versions.node,
    bun: process.versions.bun, version: process.version,
  } });
  recordNative(operation, "*");
  return result === null ? undefined : result;
}

export const getClientVersion = identity => invoke("identity.version", { identity });
export const formatUserAgent = identity => invoke("identity.user-agent", { identity });
export const mergeClientIdentity = (...sources) => invoke("identity.merge", { sources });
export const getAttributionHeaders = (target, identity) => invoke("identity.attribution", { target, identity });
export const getIdentityHeaders = (target, identity) => invoke("identity.headers", { target, identity });
export const getOpenCodeSessionHeaders = (target, sessionID) => invoke("identity.session-headers", { target, sessionID });

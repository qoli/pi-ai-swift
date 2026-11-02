export * from "pi-conformance:upstream-environment";
import { getEnvApiKey as hostCloudKey } from "pi-conformance:upstream-environment";
import { invokeNative, recordNative } from "./native-operations.mjs";

function lookup(operation, provider, env) {
  const values = { ...process.env };
  for (const [name, value] of Object.entries(env ?? {})) if (value) values[name] = value;
  const result = invokeNative({ operation, provider, values });
  recordNative(operation, "*");
  return result === null ? undefined : result;
}

export const findEnvKeys = (provider, env) => lookup("environment.names", provider, env);
export function getEnvApiKey(provider, env) {
  if (provider === "google-vertex") return hostCloudKey(provider, env);
  return lookup("environment.api-key", provider, env);
}

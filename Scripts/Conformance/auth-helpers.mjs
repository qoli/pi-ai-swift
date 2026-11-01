export { lazyOAuth } from "pi-conformance:upstream-auth-helpers";
import { envApiKeyAuth as source } from "pi-conformance:upstream-auth-helpers";
import { wrapPrimaryAuthorization } from "./authorization.mjs";

export function envApiKeyAuth(name, variables) {
  return wrapPrimaryAuthorization("generic", source(name, variables), variables);
}

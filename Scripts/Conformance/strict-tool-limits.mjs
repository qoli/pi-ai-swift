import { registerSessionResourceCleanup } from "pi-conformance:session-resources";
import { invokeNative, recordNative } from "./native-operations.mjs";
export { isStrictToolLimitErrorMessage } from "pi-conformance:upstream-strict-tools";

const operations = [];
export function markStrictToolLimitsExceeded(session) { operations.push({ mark: true, session }); }
registerSessionResourceCleanup(session => operations.push({ cleanup: true, session }));
export function hasExceededStrictToolLimits(session) {
  const result = invokeNative({ operation: "strict.session", operations, session });
  recordNative("strict.session", "*");
  return result;
}

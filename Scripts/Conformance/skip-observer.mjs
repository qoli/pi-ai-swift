import { appendFileSync } from "node:fs";
import path from "node:path";

export function observeSkipIf(api, file, line, declaration) {
  return condition => {
    const collector = api.skipIf(condition);
    return new Proxy(collector, {
      apply(target, receiver, args) {
        appendFileSync(path.join(process.env.PI_CONFORMANCE_OUTPUT,
          `${process.env.PI_CONFORMANCE_IMPLEMENTATION}-skip-conditions.jsonl`), JSON.stringify({
          file, line, declaration, skipped: !!condition, title: args[0],
        }) + "\n");
        return Reflect.apply(target, receiver, args);
      },
    });
  };
}

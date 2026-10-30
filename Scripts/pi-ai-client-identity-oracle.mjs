import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [root, casePath] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(casePath, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Client identity revision mismatch");
const { getIdentityHeaders } = await import(pathToFileURL(path.join(root, "packages/ai/src/utils/identity.ts")));
const original = Object.fromEntries(["platform", "arch", "versions", "version"].map(key => [key, Object.getOwnPropertyDescriptor(process, key)]));
const cases = {};
try {
  for (const spec of fixture.cases) {
    for (const key of ["platform", "arch", "version"]) Object.defineProperty(process, key, { configurable: true, value: spec.host[key] });
    Object.defineProperty(process, "versions", { configurable: true, value: { node: spec.host.node, bun: spec.host.bun } });
    cases[spec.id] = getIdentityHeaders(spec.target, spec.identity);
  }
} finally {
  for (const [key, descriptor] of Object.entries(original)) Object.defineProperty(process, key, descriptor);
}
process.stdout.write(JSON.stringify({ upstreamRevision: revision, cases }, null, 2) + "\n");

import { readFileSync } from "node:fs";
import {execFileSync} from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";
const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision=execFileSync("git",["-C",root,"rev-parse","HEAD"],{encoding:"utf8"}).trim();
if (revision!==fixture.upstreamRevision) throw new Error("tool arguments revision mismatch");
const { parseToolCallArguments } = await import(pathToFileURL(path.join(root,
  "packages/ai/src/utils/json-parse.ts")));
const cases = fixture.cases.map(({id,input})=>{
  const value=parseToolCallArguments(input);
  return {id,arguments:value.arguments,hasError:value.argumentsError!==undefined,
    preservesReceivedInput:value.argumentsError?.includes(`Received arguments:\n${input}`)??false};
});
console.log(JSON.stringify({upstreamRevision:fixture.upstreamRevision,cases},null,2));

#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { providerStreams } from './pi-ai-provider-context.mjs';
const [root, casePath, outputPath] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(casePath, 'utf8'));
const revision = execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], {encoding:'utf8'}).trim();
if (revision !== fixture.upstreamRevision) throw new Error('revision mismatch');
const source = await providerStreams(root, await import(pathToFileURL(path.join(root, 'packages/ai/src/api/anthropic-messages.ts'))));
let userAgent;
const observations = [];
const stream = source.stream(fixture.model, {messages:[{role:'user',content:'hello',timestamp:0}]}, {
  apiKey: 'sk-ant-oat01-synthetic-fixture', maxRetries:0, cacheRetention:'none',
  fetch: async (_url, init) => {
    userAgent = new Headers(init.headers).get('user-agent');
    const body = fixture.frames.map(frame => `event: ${frame.type}\ndata: ${JSON.stringify(frame)}\n\n`).join('');
    return new Response(body, {status:200,headers:{'content-type':'text/event-stream'}});
  }
});
// Snapshot at emission, before the source mutates its shared partial message again.
const push = stream.push.bind(stream);
stream.push = event => {
  if (event.type === 'text_delta' || event.type === 'done') {
    observations.push({type:event.type, usage:structuredClone((event.partial ?? event.message).usage)});
  }
  if (event.type === 'error') throw new Error(event.error.errorMessage);
  push(event);
};
for await (const _event of stream) {}
const rendered = JSON.stringify({schemaVersion:1,upstreamRevision:revision,userAgent,observations},null,2)+'\n';
if (outputPath) await writeFile(outputPath, rendered);
else process.stdout.write(rendered);

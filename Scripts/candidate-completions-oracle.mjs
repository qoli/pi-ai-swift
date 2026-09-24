import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { providerStreams } from './pi-ai-provider-context.mjs';
const [root] = process.argv.slice(2);
const sourcePath = 'packages/ai/src/api/openai-completions.ts';
const sourceSHA256 = createHash('sha256').update(readFileSync(path.join(root,sourcePath))).digest('hex');
if (sourceSHA256 !== 'd778b641ddd8006e5ec57c314f7b2d2b6d5c0c04723ef3f257659e99f7804d55') throw Error('candidate source hash mismatch');
const implementation = await providerStreams(root, await import(pathToFileURL(path.resolve(root, sourcePath)).href));
const cases = [];
for (const strict of [null, false, true]) {
  for (const content of [[], [{type:'text',text:''}], [{type:'text',text:''},{type:'text',text:''}], [{type:'text',text:''},{type:'text',text:' '}], [{type:'text',text:''},{type:'image',data:'AA==',mimeType:'image/png'}]]) {
    cases.push({strict, content});
  }
}
for (const test of cases) {
  const model = {id:'fixture-model',name:'Fixture',api:'openai-completions',provider:'fixture',baseUrl:'https://fixture.invalid/v1',input:['text','image'],reasoning:false,contextWindow:32768,maxTokens:4096,cost:{input:0,output:0,cacheRead:0,cacheWrite:0},compat:test.strict===null?{}:{supportsStrictMode:test.strict}};
  let payload;
  const result = await implementation.stream(model, {messages:[{role:'user',content:test.content,timestamp:0}],tools:[{name:'lookup',description:'Lookup',parameters:{type:'object',properties:{}}}]}, {apiKey:'fixture',maxRetries:0,onPayload(p){payload=p;throw Error('capture complete');},fetch(){throw Error('network forbidden');}}).result();
  if (!payload) throw Error(result.errorMessage);
  test.expected = {messages:payload.messages,tools:payload.tools};
}
console.log(JSON.stringify({revision:'d5629e20489ccf770ed90b5a33941cb3b7ef24d0',sourcePath,sourceSHA256:createHash('sha256').update(readFileSync(path.join(root,sourcePath))).digest('hex'),cases},null,2));

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { providerStreams } from './pi-ai-provider-context.mjs';
const [root] = process.argv.slice(2);
const sourcePath = 'packages/ai/src/api/openai-completions.ts';
const sourceSHA256 = createHash('sha256').update(readFileSync(path.join(root,sourcePath))).digest('hex');
if (sourceSHA256 !== 'e765179e356b4828a38954cda4cec762a851bb1d3a8fa28cdaf05edd12ca5c8a') throw Error('candidate source hash mismatch');
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
console.log(JSON.stringify({revision:'86dc686cf2fd795b2b24af3d614bb0e1307bcd76',sourcePath,sourceSHA256:createHash('sha256').update(readFileSync(path.join(root,sourcePath))).digest('hex'),cases},null,2));

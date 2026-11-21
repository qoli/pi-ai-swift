import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { providerStreams } from './pi-ai-provider-context.mjs';
const [root] = process.argv.slice(2);
const sourcePath = 'packages/ai/src/api/openai-completions.ts';
const sourceSHA256 = createHash('sha256').update(readFileSync(path.join(root,sourcePath))).digest('hex');
if (sourceSHA256 !== '0a45961174b9be7018bb013f674c24209ee16860d65aa60aad8909c2433b35da') throw Error('candidate source hash mismatch');
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
const thinkingDefaults = [];
const thinkingFields = ['thinking', 'reasoning_effort', 'reasoning', 'enable_thinking', 'chat_template_kwargs', 'chat_template_args'];
for (const format of ['openai', 'zai', 'deepseek', 'qwen', 'qwen-chat-template', 'chat-template', 'baseten', 'openrouter', 'together', 'string-thinking', 'ant-ling']) {
  for (const mapping of [{}, {off: null}, {off: 'none'}]) {
    const compat = { thinkingFormat: format,
      chatTemplateKwargs: { enabled: {$var: 'thinking.enabled'}, level: {$var: 'thinking.level'} },
      chatTemplateArgs: { enabled: {$var: 'thinking.enabled'}, level: {$var: 'thinking.level'} } };
    thinkingDefaults.push({metadata: {compat, thinkingLevelMap: mapping}});
  }
}
thinkingDefaults.push({metadata: {compat: {thinkingFormat: 'openai', supportsReasoningEffort: false}}});
thinkingDefaults.push({metadata: {compat: {thinkingFormat: 'chat-template', chatTemplateKwargs: {
  level: {$var: 'thinking.level', omitWhenOff: true}
}}}});
for (const test of thinkingDefaults) {
  const model = {id:'fixture-model',name:'Fixture',api:'openai-completions',provider:'fixture',baseUrl:'https://fixture.invalid/v1',input:['text'],reasoning:true,contextWindow:32768,maxTokens:4096,cost:{input:0,output:0,cacheRead:0,cacheWrite:0},...test.metadata};
  let payload;
  const result = await implementation.stream(model, {messages:[{role:'user',content:'hello',timestamp:0}]}, {
    apiKey:'fixture', maxRetries:0, onPayload(p){payload=p;throw Error('capture complete');},
    fetch(){throw Error('network forbidden');}
  }).result();
  if (!payload) throw Error(result.errorMessage);
  test.expected = Object.fromEntries(Object.entries(payload).filter(([key]) => thinkingFields.includes(key)));
}
console.log(JSON.stringify({revision:execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),sourcePath,sourceSHA256:createHash('sha256').update(readFileSync(path.join(root,sourcePath))).digest('hex'),cases,thinkingDefaults},null,2));

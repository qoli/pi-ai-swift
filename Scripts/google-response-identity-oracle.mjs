import { registerHooks } from 'node:module';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { providerStreams } from './pi-ai-provider-context.mjs';
import { installEmissionSnapshots, emissionSnapshot } from './pi-ai-emission-snapshots.mjs';
registerHooks({
  resolve(specifier, context, next) { return specifier === '@google/genai' ? {url:'oracle:google-identity',shortCircuit:true} : next(specifier,context); },
  load(url, context, next) {
    if (url !== 'oracle:google-identity') return next(url,context);
    return {format:'module',shortCircuit:true,source:`
      export const FinishReason = {STOP:'STOP',MAX_TOKENS:'MAX_TOKENS'};
      export const FunctionCallingConfigMode = {AUTO:'AUTO',NONE:'NONE',ANY:'ANY',VALIDATED:'VALIDATED'};
      export const ResourceScope = {COLLECTION:'COLLECTION'};
      export const ThinkingLevel = {MINIMAL:'MINIMAL',LOW:'LOW',MEDIUM:'MEDIUM',HIGH:'HIGH'};
      export class GoogleGenAI { models = { generateContentStream: async function* () { for (const chunk of globalThis.__GOOGLE_IDENTITY_CHUNKS__) yield chunk; } }; }
    `};
  }
});
const [root] = process.argv.slice(2);
await installEmissionSnapshots(root);
const cases=[];
for (const protocolID of ['google-generative-ai','google-vertex']) {
  for (const ids of [['first'],[null,'late'],[null,null],['first','replacement']]) {
    const chunks=ids.map((id,index)=>({...(id?{responseId:id}:{}),candidates:[{content:{role:'model',parts:[{text:'answer'}]},...(index===ids.length-1?{finishReason:'STOP'}:{})}]}));
    globalThis.__GOOGLE_IDENTITY_CHUNKS__=chunks;
    const source=await providerStreams(root,await import(pathToFileURL(path.join(root,`packages/ai/src/api/${protocolID}.ts`)).href));
    const model={id:'gemini-fixture',name:'Fixture',api:protocolID,provider:protocolID==='google-vertex'?'google-vertex':'google',baseUrl:'https://fixture.invalid',input:['text'],reasoning:false,contextWindow:32768,maxTokens:4096,cost:{input:0,output:0,cacheRead:0,cacheWrite:0}};
    let start,terminal;
    for await (const raw of source.stream(model,{messages:[{role:'user',content:'hello',timestamp:0}]},{apiKey:'fixture',maxRetries:0,project:'fixture',location:'us-east1'})) {
      const event=emissionSnapshot(raw);
      if(event.type==='start') start={responseID:event.partial.responseId??null,modelID:event.partial.model};
      if(event.type==='done') terminal={responseID:event.message.responseId??null,modelID:event.message.model};
      if(event.type==='error') throw Error(event.error.errorMessage);
    }
    cases.push({protocolID,chunks,start,terminal});
  }
}
console.log(JSON.stringify({revision:execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),cases},null,2));

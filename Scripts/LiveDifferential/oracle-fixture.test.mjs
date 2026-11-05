import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {runOracle} from "./oracle.mjs";
import {judge} from "./assertions.mjs";

const upstream=process.env.PI_AI_SWIFT_UPSTREAM_CACHE??fileURLToPath(new URL('../../.build/upstreams/pi/',import.meta.url));
const manifest=JSON.parse(readFileSync(new URL('scenarios.json',import.meta.url)));
const spec=manifest.cases.find(c=>c.id==='text_multi_turn');

test('custom declarations reach the exact upstream model and both real protocol turns offline',async()=>{
  let calls=0;
  const result=await runOracle({upstream,providerID:'custom-fixture',modelID:'fixture',
    credential:{type:'api_key',key:'synthetic-fixture'},manifest,spec,
    custom:{api:'openai-completions',baseURL:'https://fixture.invalid/v1',models:[{
      id:'fixture',name:'Fixture',capabilities:{reasoning:false,imageInput:false},contextWindow:4096,maximumOutputTokens:1024}]}},
    {fetch:async(url,options)=>{
      assert.equal(String(url),'https://fixture.invalid/v1/chat/completions');
      const body=JSON.parse(options.body);
      assert.equal(body.model,'fixture');
      calls++;
      const text=calls===1?'Hello test successful':'Goodbye test successful';
      return new Response('data: '+JSON.stringify({id:'synthetic',object:'chat.completion.chunk',
        choices:[{index:0,delta:{role:'assistant',content:text},finish_reason:null}]})+'\n\ndata: '+JSON.stringify({
        id:'synthetic',choices:[{index:0,delta:{},finish_reason:'stop'}],
        usage:{prompt_tokens:10,completion_tokens:4,total_tokens:14}})+'\n\ndata: [DONE]\n\n',
        {status:200,headers:{'Content-Type':'text/event-stream'}});
    }});
  assert.equal(calls,2);
  assert.equal(judge({...spec,expectedProtocolID:'openai-completions'},result).passed,true);
});

test('Google raw requests honor the shared output cap without injecting disabled thinking',async()=>{
  const original=globalThis.fetch;
  let calls=0;
  globalThis.fetch=async(url,options)=>{
    const body=JSON.parse(options.body);
    assert.equal(body.generationConfig?.thinkingConfig,undefined);
    assert.equal(body.generationConfig?.maxOutputTokens,4096);
    calls++;
    if(calls===2) assert.ok(body.contents.some(c=>c.role==='model'));
    return new Response('data: '+JSON.stringify({candidates:[{content:{role:'model',parts:[{
      text:calls===1?'Hello test successful':'Goodbye test successful'}]},finishReason:'STOP'}],
      usageMetadata:{promptTokenCount:10,candidatesTokenCount:4,totalTokenCount:14}})+'\n\n',
      {status:200,headers:{'Content-Type':'text/event-stream'}});
  };
  try {
    const result=await runOracle({upstream,providerID:'google',modelID:'gemini-3.8-flash',
      credential:{type:'api_key',key:'synthetic-fixture'},manifest,spec,maximumOutputTokens:4096});
    assert.equal(calls,2);
    assert.equal(judge({...spec,expectedProtocolID:'google-generative-ai'},result).passed,true);
  } finally {globalThis.fetch=original;}
});

test('expired OAuth cannot rotate a real refresh token outside the native Host store',async()=>{
  const original=globalThis.fetch;
  let calls=0;
  globalThis.fetch=async()=>{calls++;throw new Error('unexpected synthetic network request');};
  try {
    const result=await runOracle({upstream,providerID:'openai',modelID:'gpt-6-luna',manifest,spec,
      credential:{type:'oauth',access:'synthetic-access',refresh:'synthetic-refresh',expires:0,
        clientID:'synthetic-client',scopes:'["chatgpt.tokens.use.direct"]'}});
    assert.equal(result.hostRefreshRequired,true);
    assert.equal(calls,0);
  } finally {globalThis.fetch=original;}
});

for(const capability of ['image_input','structured_output']) {
  test(`shared ${capability} reaches the original Google request projection offline`,async()=>{
    const original=globalThis.fetch;
    let calls=0;
    globalThis.fetch=async(url,options)=>{
      calls++;
      const body=JSON.parse(options.body);
      let text;
      if(capability==='image_input') {
        const image=body.contents[0].parts.find(p=>p.inlineData)?.inlineData;
        assert.equal(image?.mimeType,'image/png');
        assert.equal(image?.data,readFileSync(`${upstream}/${manifest.imageFixture}`).toString('base64'));
        text='A red circle';
      } else {
        assert.equal(body.generationConfig.responseMimeType,'application/json');
        assert.deepEqual(body.generationConfig.responseJsonSchema,manifest.structuredSchema);
        text='{"result":42}';
      }
      return new Response('data: '+JSON.stringify({candidates:[{content:{role:'model',parts:[{text}]},finishReason:'STOP'}],
        usageMetadata:{promptTokenCount:10,candidatesTokenCount:4,totalTokenCount:14}})+'\n\n',
        {status:200,headers:{'Content-Type':'text/event-stream'}});
    };
    try {
      const selected=manifest.cases.find(c=>c.id===capability);
      const result=await runOracle({upstream,providerID:'google',modelID:'gemini-3.8-flash',
        credential:{type:'api_key',key:'synthetic-fixture'},manifest,spec:selected});
      assert.equal(calls,1);
      assert.equal(judge(selected,result).passed,true);
    } finally {globalThis.fetch=original;}
  });
}

test('final assistant content is measured even when the server emits no text delta',async()=>{
  const selected={...spec,turns:spec.turns.slice(0,1)};
  const frames=[
    {type:'response.created',response:{id:'synthetic'}},
    {type:'response.output_item.added',output_index:0,item:{type:'message',id:'msg_synthetic',role:'assistant',content:[]}},
    {type:'response.output_item.done',output_index:0,item:{type:'message',id:'msg_synthetic',role:'assistant',content:[{type:'output_text',text:'Hello test successful'}]}},
    {type:'response.completed',response:{id:'synthetic',status:'completed',usage:{input_tokens:10,output_tokens:4,total_tokens:14}}},
  ];
  const result=await runOracle({upstream,providerID:'openai',modelID:'gpt-6-luna',
    credential:{type:'api_key',key:'synthetic-fixture'},manifest,spec:selected},
    {fetch:async()=>new Response(frames.map(f=>'data: '+JSON.stringify(f)+'\n\n').join(''),
      {status:200,headers:{'Content-Type':'text/event-stream'}})});
  assert.equal(result.turns[0].textDeltas,0);
  assert.equal(judge(selected,result).passed,true);
});

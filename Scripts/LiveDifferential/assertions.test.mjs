import test from "node:test";
import assert from "node:assert/strict";
import {compare,judge,safeObservation} from "./assertions.mjs";
import {translateCredential} from "./oracle.mjs";

const spec={turns:[{expectText:"Hello test successful"}]};
const valid=()=>({turns:[{started:true,completed:true,snapshot:true,text:"Hello test successful",
  textDeltas:1,reasoningDeltas:0,toolStarts:0,toolEnds:0,inputTokens:3,outputTokens:2,orderValid:true,calls:[]}]});

test("both implementations must independently satisfy the shared assertions",()=>{
  const swift=valid(),reference=valid();
  assert.equal(compare(spec,swift,reference).status,"passed");
  swift.turns[0].snapshot=false;
  assert.equal(compare(spec,swift,reference).status,"swift_failure");
  reference.turns[0].outputTokens=0;
  assert.equal(compare(spec,swift,reference).status,"both_failed");
});
test("missing execution, wrong text, missing usage and wrong order fail",()=>{
  assert.equal(judge(spec,{turns:[]}).passed,false);
  for(const [key,value] of [["text","wrong"],["inputTokens",0],["orderValid",false]]) {
    const result=valid();result.turns[0][key]=value;
    assert.equal(judge(spec,result).passed,false,key);
  }
});
test("tool argument and block lifecycle mutations are discriminating",()=>{
  const tool={turns:[{expectTool:true}]};
  const result=valid();Object.assign(result.turns[0],{toolStarts:1,toolEnds:1,stopReason:"toolUse",
    calls:[{id:"synthetic-call",name:"math_operation",arguments:{a:15,b:27,operation:"add"}}]});
  assert.equal(judge(tool,result).passed,true);
  result.turns[0].calls[0].arguments.a=16;
  assert.equal(judge(tool,result).passed,false);
  result.turns[0].calls[0].arguments.a=15;result.turns[0].stopReason="stop";
  assert.equal(judge(tool,result).passed,false);
  result.turns[0].stopReason="toolUse";result.turns[0].toolStarts=0;
  assert.equal(judge(tool,result).passed,false);
});
test("cancellation requires observed cancellation and rejects successful completion",()=>{
  const cancel={cancelAfterFirstDelta:true,turns:[{}]};
  const result=valid();result.turns[0].completed=false;result.cancelled=true;
  assert.equal(judge(cancel,result).passed,true);
  result.cancelled=false;assert.equal(judge(cancel,result).passed,false);
  result.cancelled=true;result.turns[0].completed=true;
  assert.equal(judge(cancel,result).passed,false);
});
test("artifacts exclude generated text and tool argument values",()=>{
  const result=valid();result.turns[0].calls=[{arguments:{privateValue:"secret"}}];
  const safe=JSON.stringify(safeObservation(result));
  assert.ok(!safe.includes("Hello test successful"));
  assert.ok(!safe.includes("secret"));
});
test("native OAuth metadata is translated without losing its issued client or scope array",()=>{
  const raw={type:"oauth",clientID:"fixture-client",accountID:"fixture-account",scopes:'["fixture-scope"]',access:"fixture-access"};
  assert.deepEqual(translateCredential(raw),{type:"oauth",clientId:"fixture-client",accountId:"fixture-account",scopes:["fixture-scope"],access:"fixture-access"});
  assert.equal(raw.clientID,"fixture-client");
});
test("a measurement timeout cannot turn into a Swift or provider correctness verdict",()=>{
  const result=valid();result.observationTimeout=true;
  assert.equal(compare(spec,result,valid()).status,"observation_timeout");
});
test("a passing reply through the wrong protocol fails dispatch verification",()=>{
  const selected={...spec,expectedProtocolID:"openai-responses"};
  const result=valid();result.protocolID="openai-completions";
  assert.equal(judge(selected,result).passed,false);
});
test("explicit off detects reasoning returned despite the request",()=>{
  const selected={...spec,expectReasoning:false};
  const result=valid();
  assert.equal(judge(selected,result).passed,true);
  result.turns[0].reasoningTokens=1;
  assert.equal(judge(selected,result).passed,false);
  assert.equal(judge({...selected,expectReasoning:true},result).passed,true);
});

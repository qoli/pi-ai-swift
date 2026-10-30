import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [root, casePath] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(casePath, "utf8"));
// Same SDK seam as the exact upstream bedrock-strict-tool-fallback.test.ts.
// Only the transport/client is injected; projection and retry decisions execute
// the unmodified pinned provider implementation.
const awsMock = `
export class BedrockRuntimeServiceException extends Error {
  constructor(o) { super(o.message); this.name = o.name; }
}
export class BedrockRuntimeClient {
  send(command) { return globalThis.__piBedrockResponse(command.input); }
}
export class ConverseStreamCommand { constructor(input) { this.input = input; } }
export const StopReason = {END_TURN:'end_turn'};
export const CachePointType = {DEFAULT:'default'};
export const CacheTTL = {ONE_HOUR:'ONE_HOUR'};
export const ConversationRole = {ASSISTANT:'assistant',USER:'user'};
export const ImageFormat = {JPEG:'jpeg',PNG:'png',GIF:'gif',WEBP:'webp'};
export const ToolResultStatus = {ERROR:'error',SUCCESS:'success'};
`;
const awsURL = `data:text/javascript,${encodeURIComponent(awsMock)}`;
registerHooks({resolve(specifier, context, nextResolve) {
  return specifier === "@aws-sdk/client-bedrock-runtime"
    ? {url:awsURL,shortCircuit:true} : nextResolve(specifier,context);
}});
const { BedrockRuntimeServiceException } = await import("@aws-sdk/client-bedrock-runtime");
const cases = {};
for (const test of fixture.cases) {
  const implementation = await providerStreams(root, await import(pathToFileURL(
    path.join(root, "packages/ai/src/api", `${test.protocolID}.ts`))));
  const controller = new AbortController();
  const requests = [];
  const bedrock = test.protocolID === "bedrock-converse-stream";
  const model = {
    id:"fixture-claude",name:"Claude Fixture",api:test.protocolID,
    provider:bedrock?"amazon-bedrock":"anthropic",
    baseUrl:bedrock?"https://bedrock-runtime.us-east-1.amazonaws.com":"https://fixture.invalid",
    reasoning:false,input:["text"],contextWindow:200000,maxTokens:100,
    cost:{input:0,output:0,cacheRead:0,cacheWrite:0},
    compat:bedrock?{supportsStrictMode:true}:{supportsStrictTools:true},
  };
  const tools = test.preferences.map((preference, i)=>({
    name:`tool_${i}`,description:"Fixture lookup",parameters:fixture.schema,
    ...(preference?{constrainedSampling:{type:"json_schema",strict:preference}}:{}),
  }));
  const responseFor = (input)=> {
    requests.push(structuredClone(input));
    const failure = test.failures[requests.length-1];
    if (test.cancelAfterFirst && requests.length===1) controller.abort();
    return failure;
  };
  globalThis.__piBedrockResponse = async (input)=> {
    // modelId is encoded in the AWS request URL, not its JSON body.
    const {modelId, ...wireBody} = input;
    if(modelId !== model.id) throw Error("Bedrock route changed");
    const failure=responseFor(wireBody);
    if(failure) throw new BedrockRuntimeServiceException({name:failure.type,message:failure.message});
    return {$metadata:{httpStatusCode:200},stream:(async function*(){
      yield {messageStart:{role:"assistant"}};
      yield {messageStop:{stopReason:"end_turn"}};
    })()};
  };
  const outcomes=[];
  for(let call=0;call<(test.calls??1);call++) {
    const stream=implementation.stream(model, {
      messages:[{role:"user",content:"Hello",timestamp:0}],tools,
    },{
      apiKey:"synthetic-fixture-key",maxTokens:100,maxRetries:0,cacheRetention:"none",
      signal:controller.signal,env:{AWS_BEDROCK_SKIP_AUTH:"1",AWS_REGION:"us-east-1"},
      fetch:async (_url,init)=> {
        const failure=responseFor(JSON.parse(init.body));
        if(failure) return new Response(failure.body, {status:failure.status,headers:{"content-type":"application/json"}});
        const frames=test.streamError
          ? [{type:"error",error:{type:"invalid_request_error",message:fixture.limitMessages[0]}}]
          : [{type:"message_start",message:{id:"msg_fixture",model:model.id,usage:{input_tokens:0,output_tokens:0}}},
             {type:"message_delta",delta:{stop_reason:"end_turn"},usage:{output_tokens:0}}, {type:"message_stop"}];
        return new Response(frames.map(f=>`event: ${f.type}\ndata: ${JSON.stringify(f)}\n\n`).join(""),{headers:{"content-type":"text/event-stream"}});
      },
    });
    const events=[];
    for await(const event of stream) events.push(event.type);
    const result=await stream.result();
    outcomes.push({stopReason:result.stopReason,events,
      ...(fixture.observeStrictFallbackDiagnostics ? { strictFallbackDiagnostics: (result.diagnostics ?? []).filter(value => value.type.endsWith("_strict_tools_fallback")).map(({ timestamp, ...value }) => value) } : {}),
      ...(result.stopReason==="error"?{errorMessage:result.errorMessage}:{})});
  }
  cases[test.id]={requests,outcomes};
}
console.log(JSON.stringify({upstreamRevision:fixture.upstreamRevision,cases},null,2));

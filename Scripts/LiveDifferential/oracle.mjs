import { readFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import { compare } from "./assertions.mjs";

export function translateCredential(credential) {
  const value = {...credential};
  if (value.type === "oauth") {
    if (value.clientID !== undefined) { value.clientId = value.clientID; delete value.clientID; }
    if (value.accountID !== undefined) { value.accountId = value.accountID; delete value.accountID; }
    if (typeof value.scopes === "string") value.scopes = JSON.parse(value.scopes);
  }
  return value;
}

export function failure(error) {
  const message = String(error?.message ?? error?.errorMessage ?? "");
  const status = /\b(400|401|403|404|408|409|422|429|5\d\d)\b/.exec(message)?.[1];
  const fields = ["tool_choice", "reasoning_effort", "max_tokens", "max_output_tokens", "thinking",
    "response_format", "responsejsonschema", "maxoutputtokens", "json_schema", "json_object", "instructions", "messages"]
    .filter(key => message.toLowerCase().includes(key));
  const errorCues = ["billing","balance","quota","permission","unauthorized","forbidden","model_not_found",
    "overloaded","capacity","region","unsupported","expired","rate_limit"]
    .filter(key => message.toLowerCase().includes(key));
  const harnessCodes=['upstream_revision_mismatch','upstream_source_modified','provider_absent','model_absent','image_fixture_hash_mismatch','structured_projection_unrepresented','tool_choice_projection_unrepresented'];
  const errorCode=typeof error?.code==='string'&&/^[A-Z][A-Z0-9_]+$/.test(error.code)?error.code:undefined;
  return { code: harnessCodes.includes(message)?message:error?.name === "AbortError" ? "cancelled" : "provider_failure", httpStatus: status ? +status : null, fields, errorCues,errorCode };
}

export async function runOracle(input, testing = {}) {
  const { upstream, providerID, modelID, credential, custom, spec, manifest, effort } = input;
  const revision = execFileSync("git", ["-C", upstream, "rev-parse", "HEAD"], {encoding:"utf8"}).trim();
  if (revision !== manifest.upstreamRevision) throw new Error("upstream_revision_mismatch");
  try {
    execFileSync("git", ["-C", upstream, "diff", "--quiet", "HEAD", "--", "packages/ai/src"]);
  } catch { throw new Error("upstream_source_modified"); }
  const load = relative => import(pathToFileURL(`${upstream}/packages/ai/src/${relative}`).href);
  const { createModels, createProvider } = await load("models.ts");
  const snapshot=translateCredential(credential);
  let hostRefreshRequired=false;
  const credentials={
    read:async id=>id===providerID?snapshot:undefined,
    list:async()=>[{providerId:providerID,type:snapshot.type}],
    modify:async()=>{hostRefreshRequired=true;throw new Error('host_refresh_required');},
    delete:async()=>{throw new Error('host_credential_store_is_read_only');},
  };
  const models = createModels({credentials, authContext:{env:async()=>undefined,fileExists:async()=>false}});
  if (custom) {
    const { envApiKeyAuth } = await load("auth/helpers.ts");
    const module = await load(`api/${custom.api}.lazy.ts`);
    const factory = Object.values(module).find(value => typeof value === "function");
    models.setProvider(createProvider({id:providerID, baseUrl:custom.baseURL, headers:custom.headers,
      auth:{apiKey:envApiKeyAuth("Live test key",[])},
      models:custom.models.map(m=>({id:m.id,name:m.name,provider:providerID,baseUrl:m.baseURL??custom.baseURL,
        headers:m.headers,api:m.api??custom.api,reasoning:m.capabilities.reasoning,
        input:m.capabilities.imageInput?["text","image"]:["text"], contextWindow:m.contextWindow??131072,
        maxTokens:m.maximumOutputTokens??8192,cost:{input:0,output:0,cacheRead:0,cacheWrite:0},
        ...(m.metadata?.thinkingLevelMap?{thinkingLevelMap:m.metadata.thinkingLevelMap}:{})})),api:factory()}));
  } else {
    const { builtinProviders } = await load("providers/all.ts");
    const provider = builtinProviders().find(p => p.id === providerID);
    if (!provider) throw new Error("provider_absent");
    models.setProvider(provider);
  }
  const model = models.getModel(providerID,modelID);
  if (!model) throw new Error("model_absent");
  const result = {turns:[],cancelled:false,protocolID:model.api};
  const originalFetch=globalThis.fetch;
  result.network={httpStatuses:[],failures:[]};
  globalThis.fetch=async (...args)=>{
    try {
      const response=await originalFetch(...args);
      result.network.httpStatuses.push(response.status);
      return response;
    } catch(error) {
      const code=error?.cause?.code??error?.code;
      result.network.failures.push({code:typeof code==='string'&&/^[A-Z][A-Z0-9_]+$/.test(code)?code:'fetch_failed'});
      throw error;
    }
  };
  const controller = new AbortController();
  const supervisor = input.caseDeadlineSeconds ? setTimeout(() => {
    result.observationTimeout=true;
    controller.abort();
  },input.caseDeadlineSeconds*1000) : undefined;
  const context = {systemPrompt:manifest.system,messages:[],tools:spec.tools?[{
    name:manifest.tool.name,description:manifest.tool.description,parameters:manifest.tool.schema}]:undefined};
  let previous;
  try {
    for (const turn of spec.turns) {
      if (previous) {
        context.messages.push(previous);
        for (const call of previous.content.filter(c=>c.type==="toolCall")) {
          context.messages.push({role:"toolResult",toolCallId:call.id,toolName:call.name,
            content:[{type:"text",text:turn.toolResult??"42"}],isError:false,timestamp:Date.now()});
        }
      }
      let content=turn.prompt;
      if(spec.imageInput) {
        const image=readFileSync(`${upstream}/${manifest.imageFixture}`);
        if(createHash('sha256').update(image).digest('hex')!==manifest.imageSHA256) throw new Error('image_fixture_hash_mismatch');
        content=[{type:'text',text:turn.prompt},{type:'image',data:image.toString('base64'),mimeType:'image/png'}];
      }
      context.messages.push({role:"user",content,timestamp:Date.now()});
      const observation={started:false,completed:false,snapshot:false,text:"",textDeltas:0,
        reasoningDeltas:0,reasoningTokens:0,toolStarts:0,toolEnds:0,calls:[],inputTokens:0,outputTokens:0,orderValid:true};
      result.turns.push(observation);
      const options={signal:controller.signal, ...(effort?{reasoning:effort}:{}),
        ...(input.transport?{transport:input.transport}:{}), ...(input.maximumOutputTokens?{maxTokens:input.maximumOutputTokens}: {}),
        ...(testing.fetch?{fetch:testing.fetch}:{})};
      if(spec.toolChoiceByProtocol) {
        if(spec.toolChoiceByProtocol[model.api]===undefined) throw new Error('tool_choice_projection_unrepresented');
        options.toolChoice=spec.toolChoiceByProtocol[model.api];
      }
      if(spec.structuredOutput) options.onPayload=payload=>{
        const schema=manifest.structuredSchema;
        if(model.api==='openai-completions') payload.response_format={type:'json_schema',json_schema:{name:'response',strict:true,schema}};
        else if(model.api==='openai-responses') payload.text={format:{type:'json_schema',name:'response',strict:true,schema}};
        else if(model.api==='google-generative-ai') Object.assign(payload.config,{responseMimeType:'application/json',responseJsonSchema:schema});
        else throw new Error('structured_projection_unrepresented');
      };
      const stream=effort === undefined ? models.stream(model,context,options) : models.streamSimple(model,context,options);
      for await (const event of stream) {
        if(event.type==="start") observation.started=true;
        if(event.type==="text_delta") {
          observation.orderValid &&= observation.started && !observation.completed;
          observation.textDeltas++;
          if(spec.cancelAfterFirstDelta && !controller.signal.aborted) controller.abort();
        }
        if(event.type==="thinking_delta") observation.reasoningDeltas++;
        if(event.type==="toolcall_start") observation.toolStarts++;
        if(event.type==="toolcall_end") {observation.toolEnds++;observation.calls.push(event.toolCall);}
        if(event.type==="error") {
          if(!result.observationTimeout && controller.signal.aborted && event.error?.stopReason === "aborted") result.cancelled=true;
          throw event.error;
        }
        if(event.type==="done") {
          previous=event.message; observation.snapshot=true; observation.completed=true;
          observation.stopReason=previous.stopReason;
          observation.text=previous.content.filter(block=>block.type==="text").map(block=>block.text).join("");
          observation.inputTokens=(previous.usage.input??0)+(previous.usage.cacheRead??0);
          observation.outputTokens=previous.usage.output??0;
          observation.reasoningTokens=previous.usage.reasoning??0;
        }
      }
    }
  } catch(error) {testing.onFailure?.(error);result.failure=failure(error);}
  finally {clearTimeout(supervisor);globalThis.fetch=originalFetch;result.hostRefreshRequired=hostRefreshRequired;}
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const input=JSON.parse(readFileSync(0,"utf8"));
    const ts=await runOracle(input);
    const result=compare(input.spec,input.swift,ts);
    const hash=createHash("sha256");
    const sourceRoot=`${input.swiftSourceRoot}/Sources/PiAIProviderRuntime`;
    for(const file of readdirSync(sourceRoot,{recursive:true}).filter(f=>f.endsWith('.swift')).sort()) {
      hash.update(file);hash.update(readFileSync(`${sourceRoot}/${file}`));
    }
    result.identity={upstreamRevision:input.manifest.upstreamRevision,swiftCheckoutSourceSHA256:hash.digest('hex'),
      nodeVersion:process.version,architecture:process.arch,
      oracleSHA256:createHash('sha256').update(readFileSync(new URL(import.meta.url))).digest('hex')};
    process.stdout.write(JSON.stringify(result));
  } catch(error) {
    process.stdout.write(JSON.stringify({status:"harness_failure",failure:failure(error)}));
    process.exitCode=1;
  }
}

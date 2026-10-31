import Anthropic from "@anthropic-ai/sdk";
import { GoogleGenAI } from "@google/genai";
import { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";
import { afterEach } from "vitest";

export class FixtureAnthropic extends Anthropic {
  _shouldResolveDefaultCredentials() { return false; }
}

const sources = new Map();
let nextSource = 0;
afterEach(() => sources.clear());

export async function resolveFixtureCloud(stage, value, options, connection) {
  if (stage === "credential") {
    const source = sources.get(value.source);
    if (!source) throw new Error("Unknown Native cloud source handle");
    if (source.kind === "vertex") {
      connection.client = source.client;
      return { credential: { bearerToken: { _0: "synthetic-cloud-fixture-token" } } };
    }
    if (source.kind === "aws") {
      connection.client = source.client;
      return { credential: { aws: { _0: { accessKeyID: "synthetic-cloud-access", secretAccessKey: "synthetic-cloud-secret",
        region: source.region ?? "us-east-1" } } } };
    }
    const client = source.client;
    const auth = typeof client.authHeaders === "function" ? await client.authHeaders({}) : undefined;
    const authorization = auth?.values.get("authorization") ?? "Bearer synthetic-cloud-fixture-token";
    connection.federationClient = client;
    connection.federationAuthorization = authorization;
    return { credential: { bearerToken: { _0: authorization.slice("Bearer ".length) } } };
  }
  if (stage !== "source") throw new Error("Unknown Native cloud source operation");
  const request = value.request;
  const config = value.configuration;
  const id = String(++nextSource);
  if (request.googleApplicationDefaultCredentials) {
    sources.set(id, { kind: "vertex", client: new GoogleGenAI(config) });
  } else if (request.awsCredentials) {
    sources.set(id, { kind: "aws", region: request.awsCredentials.region, client: new BedrockRuntimeClient(config) });
  } else if (request.anthropicFederation) {
    sources.set(id, { kind: "federation", client: new FixtureAnthropic({ ...config,
      baseURL: request.anthropicFederation._0.baseURL, dangerouslyAllowBrowser: true, fetch: options.fetch }) });
  } else {
    throw new Error("Unknown Native cloud credential request");
  }
  return { source: id };
}

import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const upstream = process.env.PI_CONFORMANCE_UPSTREAM;
const output = process.env.PI_CONFORMANCE_OUTPUT;
const require = createRequire(path.join(upstream, "packages/ai/package.json"));
const { defineConfig } = await import(pathToFileURL(require.resolve("vitest/config")));
const directory = path.dirname(fileURLToPath(import.meta.url));
const bridge = path.join(directory, "bridge.mjs");
const implementation = process.env.PI_CONFORMANCE_IMPLEMENTATION ?? "swift";
const builtinFactories = new Map([...readFileSync(path.join(upstream, "packages/ai/src/providers/all.ts"), "utf8")
  .matchAll(/import \{ (\w+Provider) \} from "\.\/([^"]+)";/g)]
  .map(([, name, relative]) => [path.join(upstream, "packages/ai/src/providers", relative), name]));
const oauthExports = {
  anthropic: "anthropicOAuth", "openai-codex": "openaiCodexOAuth", openrouter: "openRouterOAuth",
  "github-copilot": "githubCopilotOAuth", "kimi-coding": "kimiCodingOAuth", xai: "xaiOAuth",
  meta: "metaOAuth", "openai-chatgpt": "openaiChatGPTOAuth",
};

export default defineConfig({
  root: path.join(upstream, "packages/ai"),
  test: {
    globals: true,
    environment: "node",
    testTimeout: 30000,
    setupFiles: [path.join(directory, "setup.mjs")],
    reporters: ["default", "json"],
    outputFile: { json: path.join(output, `${implementation}.json`) },
  },
  resolve: {
    alias: [
      { find: /^@earendil-works\/pi-telemetry$/, replacement: path.join(upstream, "packages/telemetry/src/index.ts") },
      { find: /^vitest$/, replacement: path.join(path.dirname(require.resolve("vitest/package.json")), "dist/index.js") },
      ...["openai", "@anthropic-ai/sdk", "@google/genai", "@aws-sdk/client-bedrock-runtime", "@smithy/core/event-streams", "@smithy/node-http-handler"].map(name => ({
        find: name, replacement: require.resolve(name),
      })),
    ],
  },
  plugins: [{
    name: "swift-provider-implementation",
    enforce: "pre",
    transform(code, id) {
      if (implementation === "swift" && id === path.join(upstream, "packages/ai/src/api/bedrock-converse-stream.lazy.ts")) {
        return { code: `import {stream as __piStream, streamSimple as __piStreamSimple} from ${JSON.stringify(bridge)};\n`
          + code + `\nsetBedrockProviderModule({stream: __piStream, streamSimple: __piStreamSimple});`, map: null };
      }
      const factory = builtinFactories.get(id);
      if (factory) {
        const module = implementation === "upstream" ? "upstream-trace.mjs" : "providers.mjs";
        const wrapper = implementation === "upstream" ? "traceBuiltinProvider" : "projectBuiltinProvider";
        return { code: `import {${wrapper} as __piProvider} from ${JSON.stringify(path.join(directory, module))};\n`
          + code.replace(`export function ${factory}`, `function __piOriginal_${factory}`)
          + `\nexport function ${factory}(...args) { return __piProvider(__piOriginal_${factory}(...args), args); }`, map: null };
      }
      if (implementation !== "upstream" || !id.startsWith(path.join(upstream, "packages/ai/src/"))) return;
      if (id.endsWith("/auth/helpers.ts")) {
        return { code: `import {tracePrimaryAuthorization as __piPrimary} from ${JSON.stringify(path.join(directory, "upstream-trace.mjs"))};\n`
          + code.replace("export function envApiKeyAuth", "function __piOriginal_envApiKeyAuth")
          + `\nexport function envApiKeyAuth(...args) { return __piPrimary(__piOriginal_envApiKeyAuth(...args)); }`, map: null };
      }
      if (id.endsWith("/models.ts")) {
        code = `import {traceCallerModels as __piCallerModels} from ${JSON.stringify(path.join(directory, "upstream-trace.mjs"))};\n`
          + code.replace("export function createModels", "function __piOriginal_createModels")
          + `\nexport function createModels(...args) { return __piCallerModels(__piOriginal_createModels(...args)); }`;
      }
      if (id.endsWith("/utils/streaming-json.ts")) {
        const wrappers = [];
        for (const [name, prefix, methods] of [
          ["StreamingJsonParser", "tool.json-parser", ["append", "snapshot"]],
          ["ToolCallArgumentsStream", "tool.arguments-stream", ["append", "replace", "finish"]],
        ]) {
          code = code.replace(`export class ${name}`, `class __piOriginal_${name}`);
          wrappers.push(`export class ${name} extends __piOriginal_${name} {\n`
            + `constructor(...args) { __piParserTrace(${JSON.stringify(prefix + ".create")}, () => super(...args)); }\n`
            + methods.map(method => `${method}(...args) { return __piParserTrace(${JSON.stringify(prefix + "." + method)}, () => super.${method}(...args)); }`).join("\n")
            + (name === "ToolCallArgumentsStream" ? `\nget text() { return __piParserTrace("tool.arguments-stream.text", () => super.text); }` : "")
            + "\n}");
        }
        return { code: `import {traceParser as __piParserTrace} from ${JSON.stringify(path.join(directory, "upstream-trace.mjs"))};\n` + code + "\n" + wrappers.join("\n"), map: null };
      }
      if (id.endsWith("/providers/opencode-headers.ts")) {
        return { code: `import {trace as __piTrace} from ${JSON.stringify(path.join(directory, "upstream-trace.mjs"))};\n`
          + code.replace("export function withOpenCodeSessionHeader", "function __piOriginal_withOpenCodeSessionHeader")
          + `\nexport function withOpenCodeSessionHeader(streams) { const wrapped = __piOriginal_withOpenCodeSessionHeader(streams); return { ...wrapped,
            stream: (...args) => __piTrace("headers.open-code", undefined, () => wrapped.stream(...args)),
            streamSimple: (...args) => __piTrace("headers.open-code", undefined, () => wrapped.streamSimple(...args)) }; }`, map: null };
      }
      if (id.startsWith(path.join(upstream, "packages/ai/src/auth/oauth/"))) {
        const provider = path.basename(id, ".ts");
        const name = oauthExports[provider];
        const traceModule = JSON.stringify(path.join(directory, "upstream-trace.mjs"));
        if (name) return {
          code: `import {authorization as __piAuth} from ${traceModule};\n`
            + code.replace(new RegExp(`export const ${name}\\b`), `const __piOriginal_${name}`)
            + `\nexport const ${name} = __piAuth(${JSON.stringify(provider)}, __piOriginal_${name});`, map: null,
        };
        if (provider === "device-code") {
          const operation = "oauth.device-poll";
          return { code: `import {trace as __piTrace} from ${traceModule};\n`
            + code.replace("export async function pollOAuthDeviceCodeFlow", "async function __piOriginal_pollOAuthDeviceCodeFlow")
            + `\nexport function pollOAuthDeviceCodeFlow(...args) { return __piTrace(${JSON.stringify(operation)}, undefined, () => __piOriginal_pollOAuthDeviceCodeFlow(...args)); }`, map: null };
        }
        if (provider === "radius") return {
          code: `import {authorization as __piAuth} from ${traceModule};\n`
            + code.replace("export function createRadiusOAuth", "function __piOriginal_createRadiusOAuth")
            + `\nexport function createRadiusOAuth(...args) { return __piAuth("radius", __piOriginal_createRadiusOAuth(...args)); }`, map: null,
        };
      }
      const operations = id.endsWith("/providers/all.ts") ? {
        getBuiltinModel: "catalog", getBuiltinModels: "catalog", getBuiltinProviders: "catalog",
        getBuiltinImageModel: "catalog.images", getBuiltinImageModels: "catalog.images",
        getBuiltinClassifierModel: "catalog.classifiers", getBuiltinClassifierModels: "catalog.classifiers",
        getAllBuiltinModels: "catalog.all-models",
      } : id.endsWith("/providers/cloudflare-stream.ts") ? {
        resolveCloudflareModel: "endpoint.cloudflare",
      } : id.endsWith("/providers/opencode-headers.ts") ? {
        withOpenCodeSessionHeader: "headers.open-code",
      } : id.endsWith("/utils/identity.ts") ? {
        getClientVersion: "identity.version", formatUserAgent: "identity.user-agent",
        mergeClientIdentity: "identity.merge", getAttributionHeaders: "identity.attribution",
        getIdentityHeaders: "identity.headers", getOpenCodeSessionHeaders: "identity.session-headers",
      } : id.endsWith("/models.ts") ? {
        getSupportedThinkingLevels: "catalog.reasoning",
        calculateCost: "usage.calculate",
      } : id.endsWith("/utils/provider-retry.ts") ? {
        retryProviderRequest: "provider.retry",
      } : id.endsWith("/utils/error-body.ts") ? {
        normalizeProviderError: "error.normalize-sdk-object",
        formatProviderError: "error.format",
        truncateErrorText: "error.truncate",
      } : id.endsWith("/utils/json-parse.ts") ? {
        parseToolCallArguments: "tool.arguments.complete", parseStreamingJson: "tool.arguments.preview",
      } : id.endsWith("/utils/openrouter-cost.ts") ? {
        applyOpenRouterReportedCost: "usage.openrouter-cost", isOpenRouterModel: "usage.is-openrouter",
      } : id.endsWith("/images.ts") ? {
        generateImages: "stream",
      } : id.includes("/api/") ? {
        stream: "stream", streamSimple: "stream", generateImages: "stream", convertMessages: "stream", classify: "classify",
        resolveGoogleThinkingLevel: "stream", processResponsesStream: "stream", convertResponsesMessages: "stream",
        ...(id.endsWith("/google-shared.ts") ? {
          convertTools: "google.tools", requiresToolCallId: "google.tool-call-id",
          supportsGoogleStrictToolSampling: "google.strict-tools", resolveGoogleFunctionCallingMode: "google.tool-choice",
          isThinkingPart: "google.thinking-part", retainThoughtSignature: "google.thought-signature",
        } : {}),
        ...(id.endsWith("/constrained-sampling.ts") ? {
          makeStrictJsonSchema: "sampling.strict", resolveJsonSchemaStrictSampling: "sampling.strict",
          appendGrammarToolInputJsonDelta: "sampling.grammar-buffer", closeGrammarToolInputJson: "sampling.grammar-buffer",
        } : {}),
        ...(id.endsWith("/openai-responses-shared.ts") ? { convertResponsesTools: "sampling.tools" } : {}),
        ...(id.endsWith("/llama-cpp-classify.ts") ? Object.fromEntries(
          ["renderQuestion", "labelProbabilities", "peakConfidence", "answerFromProbabilities", "llamaServerRoot"].map(name => [name, "classifier." + name])) : {}),
      } : {};
      const wrappers = [];
      for (const [name, operation] of Object.entries(operations)) {
        const declaration = new RegExp(`^export (const|(?:async )?function) ${name}\\b`, "gm");
        let matched = false;
        code = code.replace(declaration, (_match, kind) => {
          matched = true;
          return `${kind} __piOriginal_${name}`;
        });
        const protocol = ["stream", "streamSimple", "generateImages", "classify"].includes(name) && id.includes("/api/")
          ? path.basename(id, ".ts") : undefined;
        if (matched) wrappers.push(`export function ${name}(...args) { return __piConformanceTrace(${JSON.stringify(operation)}, ${JSON.stringify(protocol)}, () => __piOriginal_${name}(...args)); }`);
      }
      if (!wrappers.length) return;
      return {
        code: `import {trace as __piConformanceTrace} from ${JSON.stringify(path.join(directory, "upstream-trace.mjs"))};\n` + code + "\n" + wrappers.join("\n"),
        map: null,
      };
    },
    resolveId(source, importer) {
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/test/oauth.ts")) {
        return path.join(directory, "offline-credentials.mjs");
      }
      if (implementation !== "swift") return;
      if (source === "pi-conformance:upstream-auth-helpers") return path.join(upstream, "packages/ai/src/auth/helpers.ts");
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/providers/cloudflare-stream.ts")) return path.join(directory, "cloudflare-stream.mjs");
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/auth/helpers.ts")) return path.join(directory, "auth-helpers.mjs");
      if (source.startsWith("pi-conformance:upstream-oauth/")) {
        return path.join(upstream, "packages/ai/src/auth/oauth", source.split("/").at(-1) + ".ts");
      }
      if (source === "pi-conformance:upstream-compat") return path.join(upstream, "packages/ai/src/compat.ts");
      if (source === "pi-conformance:upstream-codex") return path.join(upstream, "packages/ai/src/api/openai-codex-responses.ts");
      if (source === "pi-conformance:upstream-streaming-json") return path.join(upstream, "packages/ai/src/utils/streaming-json.ts");
      if (source === "pi-conformance:upstream-models") return path.join(upstream, "packages/ai/src/models.ts");
      if (source === "pi-conformance:upstream-identity") return path.join(upstream, "packages/ai/src/utils/identity.ts");
      if (source === "pi-conformance:upstream-device-code") return path.join(upstream, "packages/ai/src/auth/oauth/device-code.ts");
      if (source.startsWith("pi-conformance:native-oauth/")) return "\0pi-native-oauth/" + source.split("/").at(-1);
      if (source === "pi-conformance:upstream-oauth-load") return path.join(upstream, "packages/ai/src/auth/oauth/load.ts");
      if (source === "pi-conformance:upstream-providers") return path.join(upstream, "packages/ai/src/providers/all.ts");
      if (source === "pi-conformance:upstream-google-shared") return path.join(upstream, "packages/ai/src/api/google-shared.ts");
      if (source === "pi-conformance:upstream-responses-shared") return path.join(upstream, "packages/ai/src/api/openai-responses-shared.ts");
      if (source === "pi-conformance:upstream-memory-observer") return path.join(upstream, "packages/ai/test/memory-helpers.ts");
      if (source === "pi-conformance:upstream-error-body") return path.join(upstream, "packages/ai/src/utils/error-body.ts");
      if (source === "pi-conformance:upstream-constrained-sampling") return path.join(upstream, "packages/ai/src/api/constrained-sampling.ts");
      if (source === "pi-conformance:upstream-openrouter-cost") return path.join(upstream, "packages/ai/src/utils/openrouter-cost.ts");
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/utils/openrouter-cost.ts")) {
        return path.join(directory, "openrouter-cost.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/utils/json-parse.ts")) {
        return path.join(directory, "json-parse.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/api/constrained-sampling.ts")) {
        return path.join(directory, "constrained-sampling.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/images.ts")) {
        return path.join(directory, "images.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/utils/error-body.ts")) {
        return path.join(directory, "error-body.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/test/memory-helpers.ts")) {
        return path.join(directory, "memory-observer.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/api/openai-responses-shared.ts")) {
        return path.join(directory, "responses-shared.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/api/google-shared.ts")) {
        return path.join(directory, "google-shared.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/providers/all.ts")) {
        return path.join(directory, "providers.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/models.ts")) {
        return path.join(directory, "models.mjs");
      }
      if (importer && path.resolve(path.dirname(importer), source) === path.join(upstream, "packages/ai/src/compat.ts")) {
        return path.join(directory, "compat.mjs");
      }
      if (!importer) return;
      const absolute = path.resolve(path.dirname(importer), source);
      if (absolute.startsWith(path.join(upstream, "packages/ai/src/api/")) &&
        ["typesafe-system-one.ts", "cloudflare-workers-ai-system-one.ts", "openai-decisions.ts", "llama-cpp-classify.ts"].includes(path.basename(absolute))) {
        return "\0pi-native-classifier/" + path.basename(absolute, ".ts");
      }
      if (absolute === path.join(upstream, "packages/ai/src/providers/opencode-headers.ts")) return path.join(directory, "opencode-headers.mjs");
      if (absolute === path.join(upstream, "packages/ai/src/auth/oauth/load.ts")) return "\0pi-native-oauth-load";
      if (absolute === path.join(upstream, "packages/ai/src/utils/provider-retry.ts")) {
        return path.join(directory, "provider-retry.mjs");
      }
      if (absolute === path.join(upstream, "packages/ai/src/auth/oauth/device-code.ts")) {
        return path.join(directory, "device-code.mjs");
      }
      if (absolute === path.join(upstream, "packages/ai/src/utils/identity.ts")) {
        return path.join(directory, "identity.mjs");
      }
      if (absolute === path.join(upstream, "packages/ai/src/utils/streaming-json.ts")) {
        return path.join(directory, "streaming-json.mjs");
      }
      if (absolute === path.join(upstream, "packages/ai/src/api/openai-codex-responses.ts")) {
        return path.join(directory, "codex.mjs");
      }
      if (absolute.startsWith(path.join(upstream, "packages/ai/src/auth/oauth/"))) {
        const provider = path.basename(absolute, ".ts");
        if (oauthExports[provider] || provider === "radius") return "\0pi-native-oauth/" + provider;
      }
      if (absolute.startsWith(path.join(upstream, "packages/ai/src/api/")) &&
          ["anthropic-messages.ts", "openai-completions.ts", "openai-responses.ts",
           "azure-openai-responses.ts", "google-generative-ai.ts", "google-vertex.ts",
           "mistral-conversations.ts", "pi-messages.ts", "bedrock-converse-stream.ts",
           "openai-codex-responses.ts", "openrouter-images.ts"].includes(path.basename(absolute))) {
        return bridge;
      }
    },
    load(id) {
      if (id.startsWith("\0pi-native-classifier/")) {
        const api = id.split("/").at(-1);
        return `import {classify as native, helper} from ${JSON.stringify(path.join(directory, "classifier.mjs"))};\n`
          + `export const classify = (model, context, options) => native(${JSON.stringify(api)}, model, context, options);\n`
          + (api === "llama-cpp-classify" ? ["renderQuestion", "labelProbabilities", "peakConfidence", "answerFromProbabilities", "llamaServerRoot"]
            .map(name => `export const ${name} = (...args) => helper(${JSON.stringify(name)}, args);`).join("\n") : "");
      }
      if (id === "\0pi-native-oauth-load") {
        const names = { anthropic: "Anthropic", "openai-codex": "OpenAICodex", "openai-chatgpt": "OpenAIChatGPT",
          "github-copilot": "GitHubCopilot", openrouter: "OpenRouter", "kimi-coding": "KimiCoding", meta: "Meta", xai: "Xai" };
        return `export * from "pi-conformance:upstream-oauth-load";\n`
          + Object.entries(names).map(([provider, suffix]) => `import {${oauthExports[provider]} as ${suffix}} from ${JSON.stringify("pi-conformance:native-oauth/" + provider)}; export const load${suffix}OAuth = async () => ${suffix};`).join("\n")
          + `\nimport {createRadiusOAuth} from "pi-conformance:native-oauth/radius"; export const loadRadiusOAuth = async options => createRadiusOAuth(options);`;
      }
      if (!id.startsWith("\0pi-native-oauth/")) return;
      const provider = id.split("/").at(-1);
      const source = JSON.stringify("pi-conformance:upstream-oauth/" + provider);
      const common = JSON.stringify(path.join(directory, "authorization.mjs"));
      if (provider === "radius") return `import {createRadiusOAuth as original} from ${source};
        import {wrapAuthorization} from ${common};
        export function createRadiusOAuth(options) { return wrapAuthorization("radius", original(options), options); }`;
      const name = oauthExports[provider];
      return `export * from ${source}; import {${name} as original} from ${source};
        import {wrapAuthorization} from ${common};
        export const ${name} = wrapAuthorization(${JSON.stringify(provider)}, original);`;
    },
  }],
});

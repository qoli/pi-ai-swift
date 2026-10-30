import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const upstream = process.env.PI_CONFORMANCE_UPSTREAM;
const output = process.env.PI_CONFORMANCE_OUTPUT;
const require = createRequire(path.join(upstream, "packages/ai/package.json"));
const { defineConfig } = await import(pathToFileURL(require.resolve("vitest/config")));
const directory = path.dirname(fileURLToPath(import.meta.url));
const bridge = path.join(directory, "bridge.mjs");
const implementation = process.env.PI_CONFORMANCE_IMPLEMENTATION ?? "swift";

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
      ...["openai", "@anthropic-ai/sdk", "@google/genai", "@aws-sdk/client-bedrock-runtime", "@smithy/core/event-streams"].map(name => ({
        find: name, replacement: require.resolve(name),
      })),
    ],
  },
  plugins: [{
    name: "swift-provider-implementation",
    enforce: "pre",
    transform(code, id) {
      if (implementation !== "upstream" || !id.startsWith(path.join(upstream, "packages/ai/src/"))) return;
      const operations = id.endsWith("/providers/all.ts") ? {
        getBuiltinModel: "catalog", getBuiltinModels: "catalog", getBuiltinProviders: "catalog",
      } : id.includes("/api/") ? {
        stream: "stream", streamSimple: "stream", convertMessages: "stream",
        resolveGoogleThinkingLevel: "stream", processResponsesStream: "stream", convertResponsesMessages: "stream",
      } : {};
      const wrappers = [];
      for (const [name, operation] of Object.entries(operations)) {
        const declaration = new RegExp(`^export (const|(?:async )?function) ${name}\\b`, "gm");
        let matched = false;
        code = code.replace(declaration, (_match, kind) => {
          matched = true;
          return `${kind} __piOriginal_${name}`;
        });
        if (matched) wrappers.push(`export function ${name}(...args) { __piConformanceTrace(${JSON.stringify(operation)}); return __piOriginal_${name}(...args); }`);
      }
      if (!wrappers.length) return;
      return {
        code: `import {trace as __piConformanceTrace} from ${JSON.stringify(path.join(directory, "upstream-trace.mjs"))};\n` + code + "\n" + wrappers.join("\n"),
        map: null,
      };
    },
    resolveId(source, importer) {
      if (implementation !== "swift") return;
      if (source === "pi-conformance:upstream-compat") return path.join(upstream, "packages/ai/src/compat.ts");
      if (source === "pi-conformance:upstream-models") return path.join(upstream, "packages/ai/src/models.ts");
      if (source === "pi-conformance:upstream-providers") return path.join(upstream, "packages/ai/src/providers/all.ts");
      if (source === "pi-conformance:upstream-google-shared") return path.join(upstream, "packages/ai/src/api/google-shared.ts");
      if (source === "pi-conformance:upstream-responses-shared") return path.join(upstream, "packages/ai/src/api/openai-responses-shared.ts");
      if (source === "pi-conformance:upstream-memory-observer") return path.join(upstream, "packages/ai/test/memory-helpers.ts");
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
          ["anthropic-messages.ts", "openai-completions.ts", "openai-responses.ts",
           "azure-openai-responses.ts", "google-generative-ai.ts", "google-vertex.ts",
           "mistral-conversations.ts", "pi-messages.ts", "bedrock-converse-stream.ts"].includes(path.basename(absolute))) {
        return bridge;
      }
    },
  }],
});

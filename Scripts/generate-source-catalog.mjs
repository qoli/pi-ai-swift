#!/usr/bin/env node
// Explicit schema-6 source projection. Lock provenance selects this source path
// or the separate published-package generator; neither is an error fallback.
import { readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import path from "node:path";
import "./pi-ai-source-runtime.mjs";

const [sourceRoot, evidencePath, outputPath] = process.argv.slice(2);
if (!sourceRoot || !evidencePath || !outputPath) {
  throw new Error("usage: generate-source-catalog.mjs SOURCE_ROOT EVIDENCE OUTPUT");
}
const evidenceBytes = await readFile(evidencePath);
const evidence = JSON.parse(evidenceBytes);
const release = evidence.publishedPackage;
const packageIdentity = release ? { path: "packages/ai", name: "@earendil-works/pi-ai", version: evidence.version } : evidence.package;
const packageRoot = path.join(sourceRoot, packageIdentity.path);
const packageInfo = JSON.parse(await readFile(path.join(packageRoot, "package.json")));
if (packageInfo.name !== packageIdentity.name || packageInfo.version !== packageIdentity.version) {
  throw new Error("Source package identity does not match evidence");
}
const modelDataManifest = JSON.parse(await readFile(path.join(packageRoot, "src/providers/data/.manifest.json")));
if (modelDataManifest.schemaVersion !== 6 || (!release && modelDataManifest.structureHash !== evidence.structureHash)) {
  throw new Error("Source model-data schema/structure does not match evidence");
}
if (release) {
  const { generatedAt, ...manifest } = modelDataManifest;
  const sorted = (_, value) => value && typeof value === "object" && !Array.isArray(value)
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, value[key]])) : value;
  const digest = createHash("sha256").update(JSON.stringify(manifest, sorted)).digest("hex");
  if (digest !== evidence.catalogSHA256) throw new Error("Published catalog manifest differs from review");
}
const { builtinProviders } = await import(pathToFileURL(path.join(packageRoot, "src/providers/all.ts")));
const providers = builtinProviders().map(provider => ({
  id: provider.id,
  name: provider.name,
  baseURL: provider.baseUrl ?? null,
  headers: provider.headers ?? {},
  authorizationMethods: Object.keys(provider.auth ?? {}).sort(),
  // Exact models.ts contract: chat-only providers (Radius) may omit the
  // optional all-models operation. This is declared selection, not error recovery.
  models: provider.getAllModels?.() ?? provider.getModels(),
})).sort((a, b) => a.id.localeCompare(b.id));

const imageProviderIDs = providers.filter(p => p.models.some(m => m.type === "image")).map(p => p.id);
const classifierProviderIDs = providers.filter(p => p.models.some(m => m.type === "classifier")).map(p => p.id);
const document = {
  schemaVersion: 1,
  upstreamRepository: evidence.repository,
  upstreamRevision: release ? evidence.revision : evidence.candidate,
  upstreamPackage: packageIdentity,
  sourceArtifact: release ? { kind: "published-provider-data", ...release } : {
    kind: "frozen-public-catalog-inputs",
    evidenceSHA256: createHash("sha256").update(evidenceBytes).digest("hex"),
    responseArchiveSHA256: evidence.responseArchive.sha256,
  },
  // Generation time varies during replay; the input capture metadata lives in
  // evidence. Preserve all structural and value hashes without inventing a time.
  modelDataManifest: {
    schemaVersion: modelDataManifest.schemaVersion,
    structureHash: modelDataManifest.structureHash,
    files: modelDataManifest.files,
  },
  imageProviderIDs,
  classifierProviderIDs,
  providers,
};
await writeFile(outputPath, `${JSON.stringify(document)}\n`);

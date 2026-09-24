#!/usr/bin/env node
// Explicit schema-6 source projection. Lock provenance selects this source path
// or the separate published-package generator; neither is an error fallback.
import { readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [sourceRoot, evidencePath, outputPath] = process.argv.slice(2);
if (!sourceRoot || !evidencePath || !outputPath) {
  throw new Error("usage: generate-source-catalog.mjs SOURCE_ROOT EVIDENCE OUTPUT");
}
const evidenceBytes = await readFile(evidencePath);
const evidence = JSON.parse(evidenceBytes);
const packageRoot = path.join(sourceRoot, evidence.package.path);
const packageInfo = JSON.parse(await readFile(path.join(packageRoot, "package.json")));
if (packageInfo.name !== evidence.package.name || packageInfo.version !== evidence.package.version) {
  throw new Error("Source package identity does not match evidence");
}
const modelDataManifest = JSON.parse(await readFile(path.join(packageRoot, "src/providers/data/.manifest.json")));
if (modelDataManifest.schemaVersion !== 6 || modelDataManifest.structureHash !== evidence.structureHash) {
  throw new Error("Source model-data schema/structure does not match evidence");
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
  upstreamRevision: evidence.candidate,
  upstreamPackage: evidence.package,
  sourceArtifact: {
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

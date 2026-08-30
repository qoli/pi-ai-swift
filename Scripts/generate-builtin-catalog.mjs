#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [packageRoot, lockPath, outputPath] = process.argv.slice(2);
if (!packageRoot || !lockPath || !outputPath) {
  throw new Error(
    "usage: generate-builtin-catalog.mjs PACKAGE_ROOT UPSTREAM_LOCK OUTPUT"
  );
}

const lock = JSON.parse(await readFile(lockPath, "utf8"));
const manifest = JSON.parse(
  await readFile(path.join(packageRoot, "package.json"), "utf8")
);
if (manifest.name !== lock.package.name || manifest.version !== lock.package.version) {
  throw new Error(
    `package mismatch: expected ${lock.package.name}@${lock.package.version}, ` +
      `found ${manifest.name}@${manifest.version}`
  );
}

const moduleURL = pathToFileURL(
  path.join(packageRoot, "dist/providers/all.js")
).href;
const { builtinProviders } = await import(moduleURL);
const modelDataManifest = JSON.parse(
  await readFile(
    path.join(packageRoot, "dist/providers/data/.manifest.json"),
    "utf8"
  )
);
if (
  modelDataManifest.structureHash !==
  lock.publishedArtifact.modelDataManifestStructureHash
) {
  throw new Error(
    `model data structure hash mismatch: expected ` +
      `${lock.publishedArtifact.modelDataManifestStructureHash}, found ` +
      `${modelDataManifest.structureHash}`
  );
}

const providers = builtinProviders().map((provider) => ({
  id: provider.id,
  name: provider.name,
  baseURL: provider.baseUrl ?? null,
  headers: provider.headers ?? {},
  authorizationMethods: Object.keys(provider.auth ?? {}).sort(),
  models: provider.getModels().map((model) => model),
}));
providers.sort((lhs, rhs) => lhs.id.localeCompare(rhs.id));

const expectedProviders = [...lock.trackedBuiltinProviders].sort();
const actualProviders = providers.map((provider) => provider.id);
if (JSON.stringify(actualProviders) !== JSON.stringify(expectedProviders)) {
  throw new Error(
    `provider inventory mismatch: expected=${JSON.stringify(expectedProviders)} ` +
      `actual=${JSON.stringify(actualProviders)}`
  );
}

const document = {
  schemaVersion: 1,
  upstreamRepository: lock.repository,
  upstreamRevision: lock.revision,
  upstreamPackage: lock.package,
  publishedArtifact: lock.publishedArtifact,
  modelDataManifest,
  providers,
};
await writeFile(outputPath, `${JSON.stringify(document)}\n`, "utf8");

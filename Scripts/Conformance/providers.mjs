export * from "pi-conformance:upstream-providers";
export {
  getModel as getBuiltinModel,
  getModels as getBuiltinModels,
  getProviders as getBuiltinProviders,
} from "./bridge.mjs";
import { getModels, invokeNative, recordNative } from "./bridge.mjs";
import { wrapPrimaryAuthorization, withNativeOAuthMetadata } from "./authorization.mjs";
import { nativeRadiusProvider } from "./radius-provider.mjs";

export function projectBuiltinProvider(provider, args, factory) {
  if (factory === "radiusProvider") return nativeRadiusProvider(provider, args[0]);
  const result = { ...provider };
  if (!args.length && provider.id !== "radius") {
    result.getModels = () => getModels(provider.id);
    if (provider.getAllModels) result.getAllModels = () => getAllBuiltinModels(provider.id);
  }
  if (provider.auth?.apiKey && ["anthropic", "amazon-bedrock", "google-vertex", "cloudflare-workers-ai", "cloudflare-ai-gateway"].includes(provider.id)) {
    result.auth = { ...provider.auth, apiKey: wrapPrimaryAuthorization(provider.id, provider.auth.apiKey) };
  }
  if (provider.auth?.oauth) result.auth = { ...(result.auth ?? provider.auth),
    oauth: withNativeOAuthMetadata(provider.id, provider.auth.oauth) };
  for (const name of ["filterModels", "filterAllModels"]) {
    if (!provider[name]) continue;
    result[name] = (models, credential) => {
      const selected = invokeNative({ operation: "authorization.availability", provider: provider.id, models, credential });
      recordNative("provider." + name, provider.id);
      return selected.map(index => models[index]);
    };
  }
  return result;
}

let images;
export function getBuiltinImageModels(provider) {
  images ??= invokeNative({ operation: "catalog.images" });
  recordNative("catalog.images", provider);
  return Object.values(images).filter(model => model.provider === provider).map(model => structuredClone(model));
}
export function getBuiltinImageModel(provider, id) {
  images ??= invokeNative({ operation: "catalog.images" });
  recordNative("catalog.images", provider);
  return structuredClone(images[`${provider}/${id}`]);
}

let classifiers;
let allModels;
export function getAllBuiltinModels(provider) {
  allModels ??= invokeNative({ operation: "catalog.all-models" });
  recordNative("catalog.all-models", provider);
  return structuredClone(allModels[provider] ?? []);
}
export function getBuiltinClassifierModels(provider) {
  classifiers ??= invokeNative({ operation: "catalog.classifiers" });
  recordNative("catalog.classifiers", provider);
  return Object.values(classifiers).filter(model => model.provider === provider).map(model => structuredClone(model));
}
export function getBuiltinClassifierModel(provider, id) {
  classifiers ??= invokeNative({ operation: "catalog.classifiers" });
  recordNative("catalog.classifiers", provider);
  return structuredClone(classifiers[`${provider}/${id}`]);
}

export * from "pi-conformance:upstream-providers";
export {
  getModel as getBuiltinModel,
  getModels as getBuiltinModels,
  getProviders as getBuiltinProviders,
} from "./bridge.mjs";
import { invokeNative, recordNative } from "./bridge.mjs";

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

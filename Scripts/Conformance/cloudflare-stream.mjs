import { invokeNative, recordNative } from "./bridge.mjs";

export function resolveCloudflareModel(model, env) {
  const baseUrl = invokeNative({ operation: "endpoint.cloudflare", template: model.baseUrl, environment: env });
  recordNative("endpoint.cloudflare", model.api);
  return baseUrl === model.baseUrl ? model : { ...model, baseUrl };
}

export function cloudflareStreams(streams) {
  return Object.fromEntries(["stream", "streamSimple"].map(name => [name,
    (model, context, options) => streams[name](resolveCloudflareModel(model, options?.env), context, options)]));
}

export function cloudflareClassifier(classifier) {
  return { classify: (model, context, options) => classifier.classify(resolveCloudflareModel(model, options?.env), context, options) };
}

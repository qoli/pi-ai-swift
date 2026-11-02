import { invokeNative, recordNative } from "./native-operations.mjs";
import { resolveRadiusCatalog } from "./authorization.mjs";

export function nativeRadiusProvider(provider, options = {}) {
  let state;
  const configuration = () => ({ gateway: options.gateway, catalogProvider: provider.id, catalogState: state });
  return {
    ...provider,
    getModels() {
      const result = invokeNative({ operation: "catalog.radius", ...configuration() });
      recordNative("catalog.radius", "*");
      return result.models;
    },
    async refreshModels(context) {
      if (context.stored) {
        const result = await resolveRadiusCatalog({ ...configuration(), cachedModels: context.stored.models }, context.signal);
        if (!await context.publish({ update: () => { state = result.state; } })) return;
      }
      if (!context.allowNetwork || context.signal.aborted) return;
      const result = await resolveRadiusCatalog({ ...configuration(), credential: context.credential }, context.signal);
      await context.publish({ persist: { models: result.models, checkedAt: Date.now() }, update: () => { state = result.state; } });
    },
  };
}

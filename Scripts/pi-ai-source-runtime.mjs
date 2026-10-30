import { registerHooks } from "node:module";

// Execute the pinned workspace's declared source export, including its
// telemetry dependency. No generated dist tree or substitute implementation.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@earendil-works/pi-telemetry") {
      return nextResolve(specifier, {
        ...context,
        conditions: [...context.conditions, "source"],
      });
    }
    return nextResolve(specifier, context);
  },
});

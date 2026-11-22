import path from "node:path";
import offlineConfig from "../Conformance/vitest.config.mjs";

const config = { ...offlineConfig, test: {
  ...offlineConfig.test,
  setupFiles: [path.join(import.meta.dirname, "setup.mjs")],
  reporters: ["json"],
} };
config.plugins = [{
  name: "selected-live-account",
  enforce: "pre",
  resolveId(source, importer) {
    // Keep compat's provider lookup and dispatch. The shared plugin replaces
    // its catalog and provider adapters with Native implementations on the Swift side.
    const compat = path.join(process.env.PI_CONFORMANCE_UPSTREAM, "packages/ai/src/compat.ts");
    if (importer && path.resolve(path.dirname(importer), source) === compat) return compat;
    const helper = path.join(process.env.PI_CONFORMANCE_UPSTREAM, "packages/ai/test/oauth.ts");
    if (importer && path.resolve(path.dirname(importer), source) === helper) {
      return path.join(import.meta.dirname, "credential.mjs");
    }
  },
}, ...offlineConfig.plugins];
export default config;

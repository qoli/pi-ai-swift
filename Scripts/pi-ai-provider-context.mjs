import path from "node:path";
import { pathToFileURL } from "node:url";

/**
 * Adapt the repository's provider-neutral fixture input to the exact
 * provider-facing context expected by the candidate upstream revision.
 *
 * This is deliberately an oracle-only caller bridge. The Swift runtime keeps
 * accepting a fully assembled ProviderRequest and does not acquire transcript
 * replay or tool-lifecycle ownership.
 */
export async function providerContextAdapter(upstreamRoot) {
  const transcript = await import(
    pathToFileURL(path.join(upstreamRoot, "packages/ai/src/utils/transcript.ts")).href
  );
  if (typeof transcript.normalizeContext !== "function") {
    throw new Error("candidate upstream does not expose normalizeContext");
  }
  return transcript.normalizeContext;
}

export async function providerStreams(upstreamRoot, implementation) {
  const normalizeContext = await providerContextAdapter(upstreamRoot);
  return {
    ...implementation,
    stream(model, context, options) {
      return implementation.stream(model, normalizeContext(context), options);
    },
    streamSimple(model, context, options) {
      return implementation.streamSimple(model, normalizeContext(context), options);
    },
  };
}

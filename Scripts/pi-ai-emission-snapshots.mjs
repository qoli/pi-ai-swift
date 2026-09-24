import path from 'node:path';
import { pathToFileURL } from 'node:url';

const snapshots = new WeakMap();
const installed = new WeakSet();

// Observe synchronously before EventStream queues mutable partial-message references.
// Forward the original event untouched so the source runtime retains its own semantics.
export async function installEmissionSnapshots(upstreamRoot) {
  const { EventStream } = await import(pathToFileURL(path.join(upstreamRoot, 'packages/ai/src/utils/event-stream.ts')).href);
  const prototype = EventStream.prototype;
  if (installed.has(prototype)) return;
  installed.add(prototype);
  const push = prototype.push;
  prototype.push = function(event) {
    const queue = snapshots.get(event) ?? [];
    queue.push(structuredClone(event));
    snapshots.set(event, queue);
    return push.call(this, event);
  };
}

export function emissionSnapshot(event) {
  const queue = snapshots.get(event);
  if (!queue?.length) throw new Error('oracle event was not observed at emission');
  return queue.shift();
}

import { vi } from "vitest";
const active = new Set();
let observers = [];
const yieldIO = globalThis.setImmediate;
const advance = vi.advanceTimersByTimeAsync.bind(vi);
const nextTimer = vi.advanceTimersToNextTimerAsync.bind(vi);
let clockWork = Promise.resolve();
let draining = false;
const enqueue = operation => {
  const result = clockWork.then(operation);
  clockWork = result.catch(() => {});
  return result;
};
const due = () => [...active].some(call =>
  (call.phase === "sleep" || call.timers?.size) && call.deadline <= Date.now());

export function nativeTimerScheduled() {
  if (draining || !vi.isFakeTimers() || !due()) return;
  draining = true;
  void enqueue(async () => {
    if (vi.isFakeTimers() && due()) await advance(0);
  }).finally(() => { draining = false; nativeClockChanged(); nativeTimerScheduled(); });
}
export const nativeClockChanged = () => { for (const resolve of observers.splice(0)) resolve(); };
const nextChange = () => new Promise(resolve => observers.push(resolve));

export function addNativeClockCall(call) { active.add(call); nativeClockChanged(); }
export function removeNativeClockCall(call) { active.delete(call); nativeClockChanged(); }

async function idle() {
  while (true) {
    await new Promise(yieldIO);
    while ([...active].some(call => ["starting", "running", "host", "request"].includes(call.phase))) {
      await nextChange();
    }
    if (due()) {
      await enqueue(() => advance(0));
    } else {
      return;
    }
  }
}

vi.advanceTimersByTimeAsync = async milliseconds => {
  const target = Date.now() + milliseconds;
  do {
    await idle();
    const deadline = Math.min(target, ...[...active].filter(call => call.phase === "sleep").map(call => call.deadline));
    await enqueue(() => advance(Math.max(0, deadline - Date.now())));
    await idle();
  } while (Date.now() < target);
  return vi;
};

vi.advanceTimersToNextTimerAsync = async (...args) => {
  if (active.size) await idle();
  const result = await enqueue(() => nextTimer(...args));
  if (active.size) await idle();
  return result;
};

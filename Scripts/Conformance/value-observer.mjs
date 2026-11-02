import { getCurrentTest } from "@vitest/runner";

export function observeValue(value, onRead) {
  const observed = new Set();
  function read() {
    const id = getCurrentTest()?.id;
    if (!id || observed.has(id)) return;
    observed.add(id);
    onRead();
  }
  return new Proxy(value, {
    get(target, key, receiver) { read(); return Reflect.get(target, key, receiver); },
    ownKeys(target) { read(); return Reflect.ownKeys(target); },
  });
}

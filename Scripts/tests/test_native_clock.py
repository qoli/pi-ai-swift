import pathlib
import subprocess
import unittest


class NativeClockTests(unittest.TestCase):
    def test_immediate_host_prompt_settles_before_advancing_native_time(self):
        module = pathlib.Path(__file__).resolve().parents[1] / "Conformance/native-clock.mjs"
        script = r"""
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
let now = 0;
let completed = false;
const call = { phase: "starting", deadline: Infinity };
const vi = {
  isFakeTimers: () => true,
  advanceTimersByTimeAsync: async milliseconds => {
    now += milliseconds;
    if (call.phase === "sleep" && call.deadline <= now) {
      completed = true;
      native.removeNativeClockCall(call);
    }
  },
  advanceTimersToNextTimerAsync: async () => {},
};
const context = vm.createContext({ setImmediate, Date: { now: () => now } });
const stub = new vm.SyntheticModule(["vi"], function () { this.setExport("vi", vi); }, { context });
const source = new vm.SourceTextModule(readFileSync(process.argv[1], "utf8"), { context });
await source.link(() => stub);
await source.evaluate();
const native = source.namespace;
native.addNativeClockCall(call);
setImmediate(() => setImmediate(() => {
  call.phase = "prompt";
  native.nativeClockChanged();
  let hostReply = Promise.resolve();
  for (let layer = 0; layer < 8; layer++) hostReply = hostReply.then(() => {});
  hostReply.then(() => {
    call.phase = "sleep";
    call.deadline = now + 1000;
    native.nativeClockChanged();
  });
}));
await vi.advanceTimersByTimeAsync(1000);
assert.equal(now, 1000);
assert.equal(completed, true, "The host prompt reply must settle before advancing fake time");
"""
        result = subprocess.run(
            ["node", "--experimental-vm-modules", "--input-type=module", "-e", script, str(module)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

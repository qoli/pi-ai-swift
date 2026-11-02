import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { createInterface } from "node:readline";
import { afterAll, afterEach, beforeEach, expect } from "vitest";
import { addNativeClockCall, removeNativeClockCall, nativeClockChanged, nativeTimerScheduled } from "./native-clock.mjs";

let session;
let credentialSession;
let nextID = 0;
const stats = new Map();

beforeEach(async () => {
  if (expect.getState().testPath.endsWith("/openai-codex-stream.test.ts")) {
    session ??= createSession();
    await session.ready;
  }
});

export function codexStats(id) { const value = stats.get(id); return value && { ...value }; }
export function resetCodexStats(id) {
  if (id) stats.delete(id); else stats.clear();
  session?.send({ kind: "resetStats", session: id });
}
export function closeCodexSessions(id) { session?.send({ kind: "closeSessions", session: id }); }

afterEach(() => {
  session?.close();
  session = undefined;
  stats.clear();
});
afterAll(() => { credentialSession?.close(); credentialSession = undefined; });

function createSession() {
  const process = spawn(globalThis.process.env.PI_CONFORMANCE_PROBE, ["--server"], { stdio: ["pipe", "pipe", "pipe"] });
  const calls = new Map();
  const sockets = new Map();
  const timers = new Map();
  let stderr = "";
  let closing = false;
  let resolveReady, rejectReady;
  let readyReceived = false;
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  process.stderr.on("data", value => { stderr += value; });
  process.stdin.on("error", () => {});
  const send = frame => {
    if (!process.stdin.destroyed && !process.stdin.writableEnded) process.stdin.write(JSON.stringify({ ...frame, now: Date.now() }) + "\n");
  };
  const phase = (id, value) => {
    const call = calls.get(id);
    if (call) call.phase = value;
    nativeClockChanged();
  };
  const socketEvent = (socket, event, fields = {}) => {
    const record = sockets.get(socket);
    const sequence = record ? ++record.sequence : 0;
    send({ kind: "socketEvent", socket, event, sequence, ...fields });
  };
  const lines = createInterface({ input: process.stdout, crlfDelay: Infinity });
  lines.on("line", line => {
    if (closing) return;
    const frame = JSON.parse(line);
    if (frame.kind === "serverReady") { readyReceived = true; resolveReady(); return; }
    const call = calls.get(frame.id);
    const value = frame.payload;
    if (frame.kind === "socketOpen") {
      phase(frame.id, "running");
      try {
        const socket = new globalThis.WebSocket(value.url, { headers: Object.fromEntries(
          Object.entries(value.headers).map(([key, value]) => [key.toLowerCase(), value])) });
        const listeners = {
          open: () => { phase(frame.id, "running"); socketEvent(value.socket, "open"); },
          message: async event => {
            const data = typeof event.data === "string" ? event.data : Buffer.from(
              event.data instanceof ArrayBuffer ? event.data : ArrayBuffer.isView(event.data)
                ? new Uint8Array(event.data.buffer, event.data.byteOffset, event.data.byteLength)
                : await event.data.arrayBuffer()).toString("utf8");
            phase(sockets.get(value.socket)?.callID, "running");
            socketEvent(value.socket, "message", { text: data });
          },
          error: event => {
            phase(sockets.get(value.socket)?.callID, "running");
            socketEvent(value.socket, "error", { message: event.message || event.error?.message || "WebSocket error" });
          },
          close: event => {
            phase(sockets.get(value.socket)?.callID, "running");
            const detail = event.reason || (event.code === 1009 ? "message too big" : "");
            socketEvent(value.socket, "close", { message: `WebSocket closed${typeof event.code === "number" ? " " + event.code : ""}${detail ? " " + detail : ""}` });
          },
        };
        sockets.set(value.socket, { socket, listeners, callID: frame.id, sequence: 0 });
        for (const [name, listener] of Object.entries(listeners)) socket.addEventListener(name, listener);
        phase(frame.id, "waiting");
      } catch (error) { socketEvent(value.socket, "error", { message: error.message }); }
    } else if (frame.kind === "socketSend") {
      phase(frame.id, "running");
      const record = sockets.get(value.socket);
      if (record) record.callID = frame.id;
      try { record.socket.send(value.text); }
      catch (error) { socketEvent(value.socket, "error", { message: error.message }); }
    } else if (frame.kind === "socketReceive") {
      if (value.sequence === sockets.get(value.socket)?.sequence) phase(frame.id, "waiting");
    } else if (frame.kind === "socketClose") {
      const record = sockets.get(value.socket);
      if (record) {
        for (const [name, listener] of Object.entries(record.listeners)) record.socket.removeEventListener(name, listener);
        record.socket.close(value.code, value.reason);
        sockets.delete(value.socket);
      }
    } else if (frame.kind === "clockSleep") {
      const deadline = value.deadline;
      if (value.purpose !== "background") call?.timers.set(value.timer, deadline);
      if (call) call.deadline = Math.min(...call.timers.values());
      const timer = setTimeout(() => {
        timers.delete(value.timer);
        call?.timers.delete(value.timer);
        if (call) call.deadline = Math.min(...call.timers.values());
        phase(frame.id, "running");
        send({ kind: "clockReply", timer: value.timer });
      }, Math.max(0, deadline - Date.now()));
      timers.set(value.timer, { timer, callID: frame.id, purpose: value.purpose });
      if (call && value.purpose === "sleep") phase(frame.id, "sleep");
      else if (call?.pendingHTTP && value.purpose === "timeout") phase(frame.id, "waiting");
      nativeTimerScheduled();
    } else if (frame.kind === "clockCancel") {
      const timer = timers.get(value.timer);
      const owner = calls.get(timer?.callID);
      clearTimeout(timer?.timer);
      timers.delete(value.timer);
      owner?.timers.delete(value.timer);
      if (owner) owner.deadline = Math.min(...owner.timers.values());
    } else if (frame.kind === "codexStats") {
      for (const [id, value_] of Object.entries(value)) stats.set(id, value_);
    } else if (call) {
      if (frame.kind === "callComplete") {
        calls.delete(frame.id);
        removeNativeClockCall(call);
        call.stdout.end();
        call.emit("close", 0);
        return;
      }
      if (["retryRequest", "cloud"].includes(frame.kind)) phase(frame.id, "host");
      if (frame.kind === "credentialTransform") phase(frame.id, "waiting");
      if (frame.kind === "credentialResult") phase(frame.id, "finishing");
      if (["request", "observer"].includes(frame.kind)) phase(frame.id, "running");
      call.stdout.write(line + "\n");
      if (frame.kind === "finished") {
        phase(frame.id, "finishing");
      }
    }
  });
  process.on("close", code => {
    if (!readyReceived) rejectReady(new Error(`Native wire server exited before readiness (${code}): ${stderr}`));
    for (const call of calls.values()) {
      removeNativeClockCall(call);
      call.stderr.emit("data", Buffer.from(stderr));
      call.stdout.end();
      call.emit("close", code);
    }
    calls.clear();
  });
  return {
    ready,
    send,
    child() {
      const id = String(++nextID);
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      child.stderr = new EventEmitter();
      child.phase = "starting";
      child.deadline = Infinity;
      child.timers = new Map();
      let started = false;
      child.stdin = new EventEmitter();
      child.stdin.write = line => {
        const frame = JSON.parse(line);
        if (!started) { started = true; send({ kind: "start", id, input: frame }); }
        else { child.pendingHTTP = false; phase(id, "running"); send({ ...frame, id }); }
      };
      child.stdin.end = () => {};
      child.waiting = () => {
        child.pendingHTTP = true;
        if ([...timers.values()].some(timer => timer.callID === id)) child.phase = "waiting";
        nativeClockChanged();
      };
      child.kill = () => { send({ kind: "cancel", id }); calls.delete(id); removeNativeClockCall(child); child.stdout.end(); };
      calls.set(id, child);
      addNativeClockCall(child);
      return child;
    },
    close() {
      closing = true;
      for (const { timer } of timers.values()) clearTimeout(timer);
      timers.clear();
      for (const call of calls.values()) {
        removeNativeClockCall(call);
        call.stdout.end();
        call.emit("close", 0);
      }
      calls.clear();
      for (const { socket, listeners } of sockets.values()) {
        for (const [name, listener] of Object.entries(listeners)) socket.removeEventListener(name, listener);
        socket.close(1000, "debug_close");
      }
      process.stdin.end();
      process.kill();
    },
  };
}

export function codexProbeChild() {
  session ??= createSession();
  return session.child();
}

export function credentialProbeChild() {
  credentialSession ??= createSession();
  return credentialSession.child();
}

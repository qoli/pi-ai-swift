import net from "node:net";

const fetch = globalThis.fetch;
globalThis.fetch = function (input, options) {
  const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
  if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) {
    throw new Error("Upstream conformance requires a replay fixture for external HTTP requests");
  }
  return fetch(input, options);
};

const connect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...arguments_) {
  const values = Array.isArray(arguments_[0]) ? arguments_[0] : arguments_;
  const options = typeof values[0] === "object" ? values[0] :
    typeof values[0] === "string" ? { path: values[0] } : { host: values[1] };
  const host = options.host ?? options.hostname ?? "localhost";
  const unixSocket = options.path && options.port === undefined && options.host === undefined;
  if (unixSocket || ["localhost", "127.0.0.1", "::1"].includes(host)) {
    return connect.apply(this, arguments_);
  }
  throw new Error("Upstream conformance permits only mocked transports and loopback fixture servers");
};

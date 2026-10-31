import Foundation

@testable import PiAIProviderRuntime

private final class WeakJSONPool {
  weak var value: ProviderJSONNodePool?
  init(_ value: ProviderJSONNodePool) { self.value = value }
}

// This C ABI is synchronously invoked on the Node test worker's thread.
nonisolated(unsafe) private var jsonPools: [WeakJSONPool] = []

private final class StreamingJSONHandle {
  let pool = ProviderJSONNodePool()
  var parser: ProviderStreamingJSONParser
  let isTool: Bool
  var text: ProviderJSONNode?
  var result: ProviderJSONNode?
  var toolSnapshot: ProviderJSONNode?
  var arguments: ProviderJSONNode
  var changes: [ProviderStreamingJSONParser.Change] = []

  init(isTool: Bool) {
    self.isTool = isTool
    parser = ProviderStreamingJSONParser(pool: pool)
    arguments = pool.node(.object(.init()))
    pool.tracksReleases = true
    jsonPools.append(WeakJSONPool(pool))
  }

  func append(_ units: [UInt16]) {
    if isTool { text = pool.node(.text(previous: text, units: units)) }
    changes = parser.append(units)
    if isTool { result = partial() }
  }

  func partial() -> ProviderJSONNode {
    let snapshot = parser.snapshot()
    if snapshot !== toolSnapshot {
      toolSnapshot = snapshot
      if let snapshot, case .object = snapshot.value {
        arguments = snapshot
      } else {
        arguments = pool.node(.object(.init()))
      }
    }
    return arguments
  }

  func object(_ members: [(String, ProviderJSONNode?)]) -> ProviderJSONNode {
    var object = ProviderJSONNode.Object()
    for (key, value) in members { if let value { object.set(Array(key.utf16), value) } }
    return pool.node(.object(object))
  }

  func node(_ value: JSONValue) -> ProviderJSONNode {
    switch value {
    case .null: return pool.node(.null)
    case .bool(let value): return pool.node(.boolean(value))
    case .number(let value): return pool.node(.number(value))
    case .integer(let value): return pool.node(.number(Double(value)))
    case .string(let value): return pool.node(.text(previous: nil, units: Array(value.utf16)))
    case .array(let values):
      var array = ProviderJSONNode.Array()
      array.elements = values.map(node)
      return pool.node(.array(array))
    case .object(let values): return object(values.map { ($0.key, node($0.value)) })
    case .orderedObject(let values): return object(values.map { ($0.key, node($0.value)) })
    }
  }
}

private func handle(_ pointer: UnsafeMutableRawPointer) -> StreamingJSONHandle {
  Unmanaged<StreamingJSONHandle>.fromOpaque(pointer).takeUnretainedValue()
}

private func node(_ pointer: UnsafeMutableRawPointer) -> ProviderJSONNode {
  Unmanaged<ProviderJSONNode>.fromOpaque(pointer).takeUnretainedValue()
}

private func pointer(_ node: ProviderJSONNode?) -> UnsafeMutableRawPointer? {
  node.map { Unmanaged.passUnretained($0).toOpaque() }
}

@_cdecl("pi_streaming_json_create")
func streamingJSONCreate(_ tool: Int32) -> UnsafeMutableRawPointer {
  Unmanaged.passRetained(StreamingJSONHandle(isTool: tool != 0)).toOpaque()
}

@_cdecl("pi_streaming_json_release")
func streamingJSONRelease(_ raw: UnsafeMutableRawPointer) {
  Unmanaged<StreamingJSONHandle>.fromOpaque(raw).release()
}

@_cdecl("pi_streaming_json_append")
func streamingJSONAppend(
  _ raw: UnsafeMutableRawPointer, _ units: UnsafePointer<UInt16>?, _ count: Int
) {
  handle(raw).append(Array(UnsafeBufferPointer(start: units, count: count)))
}

@_cdecl("pi_streaming_json_snapshot")
func streamingJSONSnapshot(_ raw: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  let value = handle(raw)
  value.result = value.isTool ? value.partial() : value.parser.snapshot()
  return pointer(value.result)
}

@_cdecl("pi_streaming_json_result")
func streamingJSONResult(_ raw: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  pointer(handle(raw).result)
}

@_cdecl("pi_streaming_json_text")
func streamingJSONText(_ raw: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  pointer(handle(raw).text)
}

@_cdecl("pi_streaming_json_replace")
func streamingJSONReplace(
  _ raw: UnsafeMutableRawPointer, _ units: UnsafePointer<UInt16>?, _ count: Int
) {
  let value = handle(raw)
  let text = Array(UnsafeBufferPointer(start: units, count: count))
  let previous = value.text?.utf16 ?? []
  var delta: ProviderJSONNode?
  if text.starts(with: previous) {
    let suffix = Array(text.dropFirst(previous.count))
    if !suffix.isEmpty { value.append(suffix) }
    delta = value.pool.node(.text(previous: nil, units: suffix))
  } else {
    value.text = nil
    value.parser = ProviderStreamingJSONParser(pool: value.pool)
    value.append(text)
  }
  value.result = value.object([("delta", delta), ("arguments", value.partial())])
}

@_cdecl("pi_streaming_json_finish")
func streamingJSONFinish(_ raw: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  let value = handle(raw)
  let text = String(decoding: value.text?.utf16 ?? [], as: UTF16.self)
  let call = ProviderToolCall.parsing(id: "fixture", name: "fixture", input: text)
  value.result = value.object([
    ("arguments", value.node(call.arguments)),
    ("argumentsError", call.argumentsError.map { value.node(.string($0)) }),
  ])
  return pointer(value.result)
}

@_cdecl("pi_streaming_json_change_count")
func streamingJSONChangeCount(_ raw: UnsafeMutableRawPointer) -> Int { handle(raw).changes.count }

@_cdecl("pi_streaming_json_change_value")
func streamingJSONChangeValue(_ raw: UnsafeMutableRawPointer, _ index: Int)
  -> UnsafeMutableRawPointer?
{
  pointer(handle(raw).changes[index].value)
}

@_cdecl("pi_streaming_json_change_append")
func streamingJSONChangeAppend(_ raw: UnsafeMutableRawPointer, _ index: Int) -> Int32 {
  handle(raw).changes[index].isAppend ? 1 : 0
}

@_cdecl("pi_streaming_json_change_path_count")
func streamingJSONChangePathCount(_ raw: UnsafeMutableRawPointer, _ index: Int) -> Int {
  handle(raw).changes[index].path.count
}

@_cdecl("pi_streaming_json_change_path_index")
func streamingJSONChangePathIndex(_ raw: UnsafeMutableRawPointer, _ index: Int, _ component: Int)
  -> Int
{
  if case .index(let value) = handle(raw).changes[index].path[component] { return value }
  return -1
}

@_cdecl("pi_streaming_json_change_path_key")
func streamingJSONChangePathKey(
  _ raw: UnsafeMutableRawPointer, _ index: Int, _ component: Int,
  _ output: UnsafeMutablePointer<UInt16>?
) -> Int {
  guard case .key(let units) = handle(raw).changes[index].path[component] else { return 0 }
  if let output {
    units.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
  }
  return units.count
}

@_cdecl("pi_streaming_json_released")
func streamingJSONReleased(_ raw: UnsafeMutableRawPointer, _ output: UnsafeMutablePointer<UInt64>?)
  -> Int
{
  let value = handle(raw)
  let count = value.pool.releasedIDs.count
  if let output {
    value.pool.releasedIDs.withUnsafeBufferPointer {
      if let base = $0.baseAddress { output.update(from: base, count: count) }
    }
    value.pool.releasedIDs.removeAll(keepingCapacity: true)
  }
  return count
}

@_cdecl("pi_json_node_id")
func jsonNodeID(_ raw: UnsafeMutableRawPointer) -> UInt64 { node(raw).id }

@_cdecl("pi_json_node_kind")
func jsonNodeKind(_ raw: UnsafeMutableRawPointer) -> Int32 {
  let value = node(raw)
  let kind: Int32
  switch value.value {
  case .null: kind = 0
  case .boolean: kind = 1
  case .number: kind = 2
  case .text: kind = 3
  case .object: kind = 4
  case .array: kind = 5
  }
  return kind | (value.isSnapshotContainer ? 256 : 0)
}

@_cdecl("pi_json_node_track_cache")
func jsonNodeTrackCache(_ raw: UnsafeMutableRawPointer) { node(raw).tracksBridgeCache = true }

@_cdecl("pi_streaming_json_live_nodes")
func streamingJSONLiveNodes() -> Int {
  jsonPools.removeAll { $0.value == nil }
  return jsonPools.reduce(0) { $0 + ($1.value?.liveNodes ?? 0) }
}

@_cdecl("pi_json_node_number")
func jsonNodeNumber(_ raw: UnsafeMutableRawPointer) -> Double {
  switch node(raw).value {
  case .number(let value): value
  case .boolean(let value): value ? 1 : 0
  default: 0
  }
}

@_cdecl("pi_json_node_prefix")
func jsonNodePrefix(_ raw: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  if case .text(let previous, _) = node(raw).value { return pointer(previous) }
  return nil
}

@_cdecl("pi_json_node_units")
func jsonNodeUnits(_ raw: UnsafeMutableRawPointer, _ output: UnsafeMutablePointer<UInt16>?) -> Int {
  guard case .text(_, let units) = node(raw).value else { return 0 }
  if let output {
    units.withUnsafeBufferPointer {
      if let base = $0.baseAddress { output.update(from: base, count: $0.count) }
    }
  }
  return units.count
}

@_cdecl("pi_json_node_count")
func jsonNodeCount(_ raw: UnsafeMutableRawPointer) -> Int {
  switch node(raw).value {
  case .object(let object): object.keys.count
  case .array(let array): array.elements.count
  default: 0
  }
}

@_cdecl("pi_json_node_child")
func jsonNodeChild(_ raw: UnsafeMutableRawPointer, _ index: Int) -> UnsafeMutableRawPointer? {
  switch node(raw).value {
  case .object(let object): pointer(object.members[object.keys[index]])
  case .array(let array): pointer(array.elements[index])
  default: nil
  }
}

@_cdecl("pi_json_node_key")
func jsonNodeKey(
  _ raw: UnsafeMutableRawPointer, _ index: Int, _ output: UnsafeMutablePointer<UInt16>?
) -> Int {
  guard case .object(let object) = node(raw).value else { return 0 }
  let key = object.keys[index]
  if let output {
    key.withUnsafeBufferPointer {
      if let base = $0.baseAddress { output.update(from: base, count: $0.count) }
    }
  }
  return key.count
}

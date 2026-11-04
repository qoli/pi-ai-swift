import Foundation

// The constants and incomplete-token rules follow the accepted streaming-json.ts.
// Text is a persistent UTF-16 rope so old previews neither change nor copy the
// accumulated string on every incoming piece.
final class ProviderJSONNodePool {
  var nextID: UInt64 = 0
  var tracksReleases = false
  var releasedIDs: [UInt64] = []
  var liveNodes = 0

  func node(_ value: ProviderJSONNode.Value) -> ProviderJSONNode {
    nextID += 1
    liveNodes += 1
    return ProviderJSONNode(id: nextID, pool: self, value: value)
  }
}

final class ProviderJSONNode {
  struct Object {
    var keys: [[UInt16]] = []
    var members: [[UInt16]: ProviderJSONNode] = [:]

    func copy() -> Object {
      self
    }

    mutating func set(_ key: [UInt16], _ value: ProviderJSONNode) {
      if members[key] == nil { keys.append(key) }
      members[key] = value
    }
  }

  struct Array {
    // Open paths are commonly chains of one-element arrays. Keeping their
    // first child inline avoids a separate array allocation in every copy.
    private var first: ProviderJSONNode?
    private var remaining: [ProviderJSONNode] = []

    var count: Int { first == nil ? 0 : 1 + remaining.count }

    var elements: [ProviderJSONNode] {
      get { first.map { [$0] + remaining } ?? [] }
      set {
        first = newValue.first
        remaining = Swift.Array(newValue.dropFirst())
      }
    }

    subscript(index: Int) -> ProviderJSONNode {
      get { index == 0 ? first! : remaining[index - 1] }
      set {
        if index == 0 { first = newValue } else { remaining[index - 1] = newValue }
      }
    }

    mutating func append(_ child: ProviderJSONNode) {
      if first == nil { first = child } else { remaining.append(child) }
    }

    func appendChildren(to pending: inout [ProviderJSONNode]) {
      if let first { pending.append(first) }
      pending.append(contentsOf: remaining)
    }

    func copy() -> Array {
      self
    }
  }

  enum Value {
    case null
    case boolean(Bool)
    case number(Double)
    case text(previous: ProviderJSONNode?, units: [UInt16])
    case object(Object)
    case array(Array)
  }

  let id: UInt64
  let pool: ProviderJSONNodePool
  var value: Value
  var isSnapshotContainer = false
  var tracksBridgeCache = false

  init(id: UInt64, pool: ProviderJSONNodePool, value: Value) {
    self.id = id
    self.pool = pool
    self.value = value
  }

  var utf16: [UInt16] {
    var parts: [[UInt16]] = []
    var current: ProviderJSONNode? = self
    while let node = current, case .text(let previous, let units) = node.value {
      parts.append(units)
      current = previous
    }
    var result: [UInt16] = []
    result.reserveCapacity(parts.reduce(0) { $0 + $1.count })
    for part in parts.reversed() { result.append(contentsOf: part) }
    return result
  }

  func copiedContainer() -> ProviderJSONNode {
    let copy: ProviderJSONNode
    switch value {
    case .object(let object): copy = pool.node(.object(object.copy()))
    case .array(let array): copy = pool.node(.array(array.copy()))
    default: return self
    }
    copy.isSnapshotContainer = true
    return copy
  }

  var jsonValue: JSONValue {
    switch value {
    case .null: .null
    case .boolean(let value): .bool(value)
    case .number(let value): .number(value)
    case .text: .string(String(decoding: utf16, as: UTF16.self))
    case .object(let object):
      .orderedObject(
        object.keys.map {
          .init(String(decoding: $0, as: UTF16.self), object.members[$0]!.jsonValue)
        })
    case .array(let array): .array(array.elements.map(\.jsonValue))
    }
  }

  @discardableResult
  func setMember(_ key: [UInt16], _ child: ProviderJSONNode) -> Bool {
    guard case .object(var object) = value else { return false }
    value = .null
    let added = object.members[key] == nil
    object.set(key, child)
    value = .object(object)
    return added
  }

  @discardableResult
  func setElement(_ index: Int, _ child: ProviderJSONNode) -> Bool {
    guard case .array(var array) = value else { return false }
    value = .null
    let added = index == array.count
    if added {
      array.append(child)
    } else {
      array[index] = child
    }
    value = .array(array)
    return added
  }

  private func detachChildren(into pending: inout [ProviderJSONNode]) {
    switch value {
    case .object(let object):
      pending.append(contentsOf: object.members.values)
    case .array(let array):
      array.appendChildren(to: &pending)
    case .text(let previous, _): if let previous { pending.append(previous) }
    default: break
    }
    value = .null
  }

  deinit {
    pool.liveNodes -= 1
    if pool.tracksReleases && tracksBridgeCache { pool.releasedIDs.append(id) }
    // Closing a deeply nested document must not recurse through ARC destruction.
    var pending: [ProviderJSONNode] = []
    detachChildren(into: &pending)
    while !pending.isEmpty {
      var child = pending.removeLast()
      if isKnownUniquelyReferenced(&child) {
        child.detachChildren(into: &pending)
      }
    }
  }
}

final class ProviderStreamingJSONParser {
  enum Slot {
    case root
    case member([UInt16])
    case element(Int)
  }

  enum PathComponent {
    case key([UInt16])
    case index(Int)
  }

  final class Change {
    let path: [PathComponent]
    var value: ProviderJSONNode
    let isAppend: Bool

    init(path: [PathComponent], value: ProviderJSONNode, isAppend: Bool = false) {
      self.path = path
      self.value = value
      self.isAppend = isAppend
    }
  }

  private final class Frame {
    enum Phase { case key, colon, value, comma }
    let container: ProviderJSONNode
    let slot: Slot?
    let path: [PathComponent]?
    let reportsInside: Bool
    var size = 0
    var key: [UInt16]?
    var phase: Phase

    init(container: ProviderJSONNode, slot: Slot?, path: [PathComponent]?) {
      self.container = container
      self.slot = slot
      self.path = path
      reportsInside = path.map { $0.count < 32 } ?? false
      if case .array = container.value { phase = .value } else { phase = .key }
    }
  }

  private final class OpenString {
    let isKey: Bool
    let slot: Slot?
    let path: [PathComponent]?
    var text: ProviderJSONNode
    var escape: [UInt16] = []
    var change: Change?

    init(isKey: Bool, slot: Slot?, path: [PathComponent]?, text: ProviderJSONNode) {
      self.isKey = isKey
      self.slot = slot
      self.path = path
      self.text = text
    }
  }

  let pool: ProviderJSONNodePool
  private var root: ProviderJSONNode?
  private var done = false
  private var stack: [Frame] = []
  private var string: OpenString?
  private var scalar: [UInt16] = []
  private var scalarSlot: Slot?
  private var pathCost = 0
  private var credit = 0
  private var dirty = false
  private var lastSnapshot: ProviderJSONNode?
  private(set) var changes: [Change] = []

  init(pool: ProviderJSONNodePool = ProviderJSONNodePool()) { self.pool = pool }

  @discardableResult
  func append(_ text: String) -> [Change] { append(Swift.Array(text.utf16)) }

  @discardableResult
  func append(_ text: [UInt16]) -> [Change] {
    credit += 256 + 8 * text.count
    changes = []
    string?.change = nil
    var index = 0
    while index < text.count && !done {
      if let string {
        index = readString(string, text, index)
      } else if !scalar.isEmpty {
        var end = index
        while end < text.count && !Self.isDelimiter(text[end]) { end += 1 }
        if end > index {
          scalar.append(contentsOf: text[index..<end])
          if scalarSlot != nil { dirty = true }
        }
        if end < text.count { endScalar() }
        index = end
      } else {
        structural(text[index])
        index += 1
      }
    }
    return changes
  }

  func snapshot() -> ProviderJSONNode? {
    guard dirty else { return lastSnapshot }
    let pending = pendingScalar()
    let cost = pathCost + (pending == nil ? 0 : 1)
    guard cost <= credit else { return lastSnapshot }
    credit -= cost
    dirty = false
    if stack.isEmpty {
      if let pending, case .root = pending.0 {
        lastSnapshot = pending.1
      } else {
        lastSnapshot = root
      }
      return lastSnapshot
    }
    var child: ProviderJSONNode?
    var childSlot: Slot?
    for depth in stack.indices.reversed() {
      let frame = stack[depth]
      let copy = frame.container.copiedContainer()
      if depth == stack.count - 1, let pending { set(copy, pending.0, pending.1) }
      if let child, let childSlot { set(copy, childSlot, child) }
      child = copy
      childSlot = frame.slot
    }
    if case .root = childSlot { lastSnapshot = child } else { lastSnapshot = root }
    return lastSnapshot
  }

  private func readString(_ open: OpenString, _ text: [UInt16], _ start: Int) -> Int {
    var runStart = start
    var index = start
    while index < text.count {
      let unit = text[index]
      if !open.escape.isEmpty {
        if continueEscape(open, unit) {
          runStart = index + 1
          index += 1
          continue
        }
        runStart = index
      }
      if unit == 0x22 {
        if index > runStart { appendString(open, Swift.Array(text[runStart..<index])) }
        string = nil
        if open.isKey, let frame = stack.last {
          frame.key = open.text.utf16
          frame.phase = .colon
        } else {
          valueEnded(stack.last)
        }
        return index + 1
      }
      if unit == 0x5c {
        if index > runStart { appendString(open, Swift.Array(text[runStart..<index])) }
        open.escape = [0x5c]
        runStart = index + 1
      }
      index += 1
    }
    if text.count > runStart { appendString(open, Swift.Array(text[runStart...])) }
    return text.count
  }

  private func continueEscape(_ open: OpenString, _ unit: UInt16) -> Bool {
    if open.escape == [0x5c] {
      let decoded: UInt16?
      switch unit {
      case 0x22, 0x5c, 0x2f: decoded = unit
      case 0x62: decoded = 8
      case 0x66: decoded = 12
      case 0x6e: decoded = 10
      case 0x72: decoded = 13
      case 0x74: decoded = 9
      default: decoded = nil
      }
      if let decoded {
        open.escape = []
        appendString(open, [decoded])
        return true
      }
      if unit == 0x75 {
        open.escape = [0x5c, 0x75]
        return true
      }
      open.escape = []
      appendString(open, [0x5c])
      return false
    }
    if let digit = Self.hexDigit(unit) {
      open.escape.append(unit)
      if open.escape.count < 6 { return true }
      var value: UInt16 = 0
      for unit in open.escape.dropFirst(2) { value = value * 16 + Self.hexDigit(unit)! }
      open.escape = []
      appendString(open, [value])
      _ = digit
      return true
    }
    let literal = open.escape
    open.escape = []
    appendString(open, literal)
    return false
  }

  private func appendString(_ open: OpenString, _ text: [UInt16]) {
    open.text = pool.node(.text(previous: open.text, units: text))
    guard !open.isKey else { return }
    place(open.slot, open.text)
    guard let path = open.path else { return }
    if let change = open.change, changes.last === change {
      change.value = pool.node(.text(previous: change.value, units: text))
    } else {
      let change = Change(
        path: path, value: pool.node(.text(previous: nil, units: text)), isAppend: true)
      changes.append(change)
      open.change = change
    }
  }

  private func structural(_ unit: UInt16) {
    switch unit {
    case 0x20, 9, 10, 13: return
    case 0x22:
      let frame = stack.last
      let isKey: Bool
      if let frame, case .object = frame.container.value,
        frame.phase == .key || frame.phase == .comma
      {
        isKey = true
      } else {
        isKey = false
      }
      let slot = isKey ? nil : valueSlot()
      let path = reportedPath(slot)
      let empty = pool.node(.text(previous: nil, units: []))
      let open = OpenString(isKey: isKey, slot: slot, path: path, text: empty)
      string = open
      if !isKey {
        place(slot, empty)
        if let path {
          let change = Change(path: path, value: empty)
          changes.append(change)
          open.change = change
        }
      }
    case 0x7b, 0x5b:
      let slot = valueSlot()
      let path = reportedPath(slot)
      let container = pool.node(unit == 0x7b ? .object(.init()) : .array(.init()))
      place(slot, container)
      stack.append(Frame(container: container, slot: slot, path: path))
      pathCost += 1
      dirty = true
      if let path {
        changes.append(
          Change(path: path, value: pool.node(unit == 0x7b ? .object(.init()) : .array(.init()))))
      }
    case 0x7d, 0x5d:
      guard let frame = stack.popLast() else { return }
      pathCost -= frame.size + 1
      dirty = true
      if let path = frame.path, !frame.reportsInside {
        changes.append(Change(path: path, value: frame.container))
      }
      valueEnded(stack.last)
    case 0x3a:
      if let frame = stack.last, case .object = frame.container.value, frame.phase == .colon {
        frame.phase = .value
      }
    case 0x2c:
      if let frame = stack.last {
        if case .array = frame.container.value { frame.phase = .value } else { frame.phase = .key }
      }
    default:
      scalar = [unit]
      scalarSlot = valueSlot()
      if scalarSlot != nil { dirty = true }
    }
  }

  private func valueSlot() -> Slot? {
    guard let frame = stack.last else { return root == nil ? .root : nil }
    if case .array(let array) = frame.container.value { return .element(array.count) }
    if frame.phase == .value || frame.phase == .colon, let key = frame.key { return .member(key) }
    return nil
  }

  private func reportedPath(_ slot: Slot?) -> [PathComponent]? {
    guard let slot else { return nil }
    if case .root = slot { return [] }
    guard let frame = stack.last, frame.reportsInside, var path = frame.path else { return nil }
    switch slot {
    case .member(let key): path.append(.key(key))
    case .element(let index): path.append(.index(index))
    case .root: break
    }
    return path
  }

  private func place(_ slot: Slot?, _ value: ProviderJSONNode) {
    guard let slot else { return }
    dirty = true
    if case .root = slot {
      root = value
      return
    }
    guard let frame = stack.last else { return }
    let added: Bool
    switch slot {
    case .element(let index): added = frame.container.setElement(index, value)
    case .member(let key): added = frame.container.setMember(key, value)
    case .root: added = false
    }
    if added {
      frame.size += 1
      pathCost += 1
    }
  }

  private func set(_ container: ProviderJSONNode, _ slot: Slot, _ value: ProviderJSONNode) {
    switch slot {
    case .element(let index): container.setElement(index, value)
    case .member(let key): container.setMember(key, value)
    case .root: break
    }
  }

  private func valueEnded(_ frame: Frame?) {
    if let frame { frame.phase = .comma } else if root != nil { done = true }
  }

  private func endScalar() {
    let token = scalar
    let slot = scalarSlot
    scalar = []
    scalarSlot = nil
    if let value = scalarValue(token, pending: false) {
      place(slot, value)
      if let path = reportedPath(slot) { changes.append(Change(path: path, value: value)) }
    }
    valueEnded(stack.last)
  }

  private func pendingScalar() -> (Slot, ProviderJSONNode)? {
    guard let slot = scalarSlot, !scalar.isEmpty, scalar.count <= 64,
      let value = scalarValue(scalar, pending: true)
    else { return nil }
    return (slot, value)
  }

  private func scalarValue(_ token: [UInt16], pending: Bool) -> ProviderJSONNode? {
    for (literal, value): (String, ProviderJSONNode.Value) in [
      ("true", .boolean(true)), ("false", .boolean(false)), ("null", .null),
    ] {
      let units = Swift.Array(literal.utf16)
      if token == units || (pending && units.starts(with: token)) { return pool.node(value) }
    }
    guard let number = Self.number(token, pending: pending) else { return nil }
    return pool.node(.number(number))
  }

  private static func number(_ token: [UInt16], pending: Bool) -> Double? {
    var index = 0
    if token.first == 0x2d { index += 1 }
    guard index < token.count else { return nil }
    if token[index] == 0x30 {
      index += 1
    } else {
      guard (0x31...0x39).contains(token[index]) else { return nil }
      repeat { index += 1 } while index < token.count && (0x30...0x39).contains(token[index])
    }
    if index < token.count, token[index] == 0x2e {
      index += 1
      let start = index
      while index < token.count && (0x30...0x39).contains(token[index]) { index += 1 }
      guard index > start else { return nil }
    }
    let mantissaEnd = index
    if index < token.count, token[index] == 0x65 || token[index] == 0x45 {
      index += 1
      if index < token.count, token[index] == 0x2b || token[index] == 0x2d { index += 1 }
      let start = index
      while index < token.count && (0x30...0x39).contains(token[index]) { index += 1 }
      if index == start {
        guard pending, index == token.count else { return nil }
        return Double(String(decoding: token[..<mantissaEnd], as: UTF16.self))
      }
    }
    guard index == token.count else { return nil }
    return Double(String(decoding: token, as: UTF16.self))
  }

  private static func isDelimiter(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x20, 9, 10, 13, 0x2c, 0x3a, 0x7b, 0x7d, 0x5b, 0x5d, 0x22: true
    default: false
    }
  }

  private static func hexDigit(_ unit: UInt16) -> UInt16? {
    switch unit {
    case 0x30...0x39: unit - 0x30
    case 0x61...0x66: unit - 0x61 + 10
    case 0x41...0x46: unit - 0x41 + 10
    default: nil
    }
  }
}

import Foundation

public enum ProviderJSONPathComponent: Sendable, Equatable, Codable {
  case key(String)
  case keyUTF16([UInt16])
  case index(Int)
}

/// Changes carry decoded string pieces without copying accumulated arguments.
public enum ProviderJSONChange: Sendable, Equatable, Codable {
  case set(path: [ProviderJSONPathComponent], value: JSONValue)
  case append(path: [ProviderJSONPathComponent], textUTF16: [UInt16])
}

public struct ProviderToolArgumentsUpdate: Sendable, Equatable, Codable {
  public enum Phase: String, Sendable, Equatable, Codable {
    case started
    case updated
  }

  public let id: String
  public let phase: Phase
  public let changes: [ProviderJSONChange]

  public init(id: String, phase: Phase, changes: [ProviderJSONChange]) {
    self.id = id
    self.phase = phase
    self.changes = changes
  }
}

actor ProviderToolArgumentObservation {
  private final class State {
    let parser = ProviderStreamingJSONParser()
    var previous: ProviderJSONNode?

    init(seedText: String?) {
      if let seedText, !seedText.isEmpty {
        parser.append(seedText)
        previous = parser.snapshot()
      }
    }
  }

  private var calls: [String: State] = [:]

  func start(id: String, initial: JSONValue, seedText: String?) -> ProviderToolArgumentsUpdate? {
    guard calls[id] == nil else { return nil }
    let state = State(seedText: seedText)
    calls[id] = state
    let value = state.previous?.jsonValue.objectValue == nil ? initial : state.previous!.jsonValue
    return .init(id: id, phase: .started, changes: [.set(path: [], value: value)])
  }

  func append(id: String, text: String) -> ProviderToolArgumentsUpdate? {
    guard let state = calls[id] else { return nil }
    state.parser.append(text)
    let snapshot = state.parser.snapshot()
    guard snapshot !== state.previous else { return .init(id: id, phase: .updated, changes: []) }
    let previous = state.previous
    state.previous = snapshot
    var changes: [ProviderJSONChange] = []
    if let snapshot, case .object = snapshot.value {
      Self.diff(previous, snapshot, path: [], into: &changes)
    } else {
      changes = [.set(path: [], value: .object([:]))]
    }
    return .init(id: id, phase: .updated, changes: changes)
  }

  func finish(id: String) { calls.removeValue(forKey: id) }

  private static func key(_ units: [UInt16]) -> ProviderJSONPathComponent {
    let text = String(decoding: units, as: UTF16.self)
    return Array(text.utf16) == units ? .key(text) : .keyUTF16(units)
  }

  private static func diff(
    _ previous: ProviderJSONNode?, _ current: ProviderJSONNode,
    path: [ProviderJSONPathComponent], into changes: inout [ProviderJSONChange]
  ) {
    guard previous !== current else { return }
    switch current.value {
    case .text:
      var parts: [[UInt16]] = []
      var cursor: ProviderJSONNode? = current
      while let node = cursor, node !== previous, case .text(let prefix, let units) = node.value {
        parts.append(units)
        cursor = prefix
      }
      if cursor == nil || cursor !== previous {
        changes.append(.set(path: path, value: .string("")))
      }
      let units = parts.reversed().flatMap { $0 }
      if !units.isEmpty { changes.append(.append(path: path, textUTF16: units)) }
    case .object(let object) where path.count < 32:
      let old: ProviderJSONNode.Object?
      if let previous, case .object(let value) = previous.value {
        old = value
      } else {
        old = nil
        changes.append(.set(path: path, value: .object([:])))
      }
      for member in object.keys {
        diff(
          old?.members[member], object.members[member]!, path: path + [key(member)], into: &changes)
      }
    case .array(let array) where path.count < 32:
      let old: [ProviderJSONNode]
      if let previous, case .array(let value) = previous.value {
        old = value.elements
      } else {
        old = []
        changes.append(.set(path: path, value: .array([])))
      }
      for (index, value) in array.elements.enumerated() {
        diff(
          index < old.count ? old[index] : nil, value, path: path + [.index(index)], into: &changes)
      }
    default:
      changes.append(.set(path: path, value: current.jsonValue))
    }
  }
}

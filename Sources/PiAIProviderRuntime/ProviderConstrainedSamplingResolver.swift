import Foundation

enum ProviderConstrainedSamplingResolver {
  struct Grammar: Sendable, Equatable {
    let syntax: String
    let definition: String
    let inputProperty: String
  }

  static func jsonSchema(
    for tool: ProviderToolDefinition,
    supportsStrictMode: Bool,
    providerID: String,
    operation: String
  ) throws -> (schema: JSONValue, strict: Bool?) {
    guard case .jsonSchema(let preference)? = tool.constrainedSampling else {
      return (tool.inputSchema, nil)
    }
    guard supportsStrictMode else {
      if preference == .require {
        throw invalid(
          providerID: providerID,
          operation: operation,
          message:
            "Tool \"\(tool.name)\" requires JSON-schema constrained sampling, but strict tools are unsupported."
        )
      }
      return (tool.inputSchema, nil)
    }
    do {
      return (try strictSchema(tool.inputSchema), true)
    } catch let error as StrictSchemaError {
      if preference == .require {
        throw invalid(
          providerID: providerID,
          operation: operation,
          message:
            "Tool \"\(tool.name)\" requires JSON-schema constrained sampling, but \(error.message)."
        )
      }
      return (tool.inputSchema, nil)
    }
  }

  static func grammar(
    for tool: ProviderToolDefinition,
    supportsGrammarTools: Bool,
    providerID: String,
    operation: String
  ) throws -> Grammar? {
    guard case .grammar(let variants)? = tool.constrainedSampling,
      supportsGrammarTools
    else { return nil }
    let lark = variants["openai_lark"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let regex = variants["openai_regex"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let syntax: String
    let definition: String
    if let lark, !lark.isEmpty {
      syntax = "lark"
      definition = lark
    } else if let regex, !regex.isEmpty {
      syntax = "regex"
      definition = regex
    } else {
      throw invalid(
        providerID: providerID,
        operation: operation,
        message:
          "Tool \"\(tool.name)\" cannot use grammar constrained sampling: no supported grammar variant was provided."
      )
    }
    guard case .object(let schema) = tool.inputSchema,
      schema.string("type") == "object",
      case .array(let required)? = schema["required"], required.count == 1,
      case .string(let inputProperty) = required[0],
      case .object(let properties)? = schema["properties"],
      case .object(let property)? = properties[inputProperty],
      property.string("type") == "string"
    else {
      throw invalid(
        providerID: providerID,
        operation: operation,
        message:
          "Tool \"\(tool.name)\" grammar constrained sampling requires exactly one required string property."
      )
    }
    return Grammar(syntax: syntax, definition: definition, inputProperty: inputProperty)
  }

  private static func strictSchema(_ value: JSONValue) throws -> JSONValue {
    guard case .object(var schema) = value else {
      throw StrictSchemaError("root schema must have type object")
    }
    try makeStrict(&schema)
    guard schema.string("type") == "object" else {
      throw StrictSchemaError("root schema must have type object")
    }
    return .object(schema)
  }

  private static func makeStrict(_ schema: inout [String: JSONValue]) throws {
    let unsupported = [
      "$ref", "$defs", "definitions", "allOf", "oneOf", "patternProperties",
      "dependentSchemas", "dependencies", "unevaluatedProperties", "propertyNames",
      "contains", "prefixItems", "not", "if", "then", "else",
    ]
    if let key = unsupported.first(where: { schema[$0] != nil }) {
      throw StrictSchemaError("\(key) schemas are unsupported")
    }
    if case .array(var variants)? = schema["anyOf"] {
      guard !variants.isEmpty else {
        throw StrictSchemaError("anyOf must contain at least one schema")
      }
      for index in variants.indices {
        guard case .object(var variant) = variants[index] else {
          throw StrictSchemaError("boolean schemas are unsupported")
        }
        if isStructured(variant) {
          throw StrictSchemaError("object and array unions are unsupported")
        }
        try makeStrict(&variant)
        variants[index] = .object(variant)
      }
      schema["anyOf"] = .array(variants)
    } else if schema["anyOf"] != nil {
      throw StrictSchemaError("anyOf must contain at least one schema")
    }
    if let items = schema["items"] {
      guard case .object(var item) = items else {
        throw StrictSchemaError("tuple and boolean schemas are unsupported")
      }
      try makeStrict(&item)
      schema["items"] = .object(item)
    }
    if schema["properties"] != nil, schema.string("type") != "object" {
      throw StrictSchemaError("properties require type object")
    }
    guard schema.string("type") == "object" else { return }
    if let additional = schema["additionalProperties"], additional != .bool(false) {
      throw StrictSchemaError("schema-valued or true additionalProperties is unsupported")
    }
    let properties: [String: JSONValue]
    if let value = schema["properties"] {
      guard case .object(let object) = value else {
        throw StrictSchemaError("object properties must be a schema map")
      }
      properties = object
    } else {
      properties = [:]
    }
    let required: Set<String>
    if let value = schema["required"] {
      guard case .array(let values) = value,
        values.allSatisfy({ if case .string = $0 { true } else { false } })
      else { throw StrictSchemaError("object required must be a string array") }
      required = Set(values.compactMap(\.stringValue))
    } else {
      required = []
    }
    guard required.isSubset(of: Set(properties.keys)) else {
      throw StrictSchemaError("required contains an unknown property")
    }
    var strictProperties: [String: JSONValue] = [:]
    for (name, value) in properties {
      guard case .object(var property) = value else {
        throw StrictSchemaError("boolean schemas are unsupported")
      }
      try makeStrict(&property)
      let strictValue = JSONValue.object(property)
      strictProperties[name] =
        required.contains(name) || allowsNull(strictValue)
        ? strictValue
        : .object(["anyOf": .array([strictValue, .object(["type": .string("null")])])])
    }
    schema["properties"] = .object(strictProperties)
    schema["required"] = .array(properties.keys.sorted().map(JSONValue.string))
    schema["additionalProperties"] = .bool(false)
  }

  private static func isStructured(_ schema: [String: JSONValue]) -> Bool {
    schema.string("type") == "object" || schema.string("type") == "array"
      || schema["properties"] != nil || schema["items"] != nil
  }

  private static func allowsNull(_ value: JSONValue) -> Bool {
    guard case .object(let schema) = value else { return false }
    if schema.string("type") == "null" || schema["const"] == .null { return true }
    if case .array(let types)? = schema["type"], types.contains(.string("null")) { return true }
    if case .array(let values)? = schema["enum"], values.contains(.null) { return true }
    if case .array(let variants)? = schema["anyOf"] { return variants.contains(where: allowsNull) }
    return false
  }

  private static func invalid(
    providerID: String,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidRequest,
      message: message,
      providerID: providerID,
      operation: operation,
      causeDescription: nil
    )
  }
}

private struct StrictSchemaError: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OrderedJSONTests {
  @Test
  func explicitJSONParsingPreservesNestedMemberOrder() throws {
    let value = try JSONValue(
      jsonData: Data(#"{"zeta":{"zulu":1,"beta":2},"alpha":3}"#.utf8))
    #expect(value.objectPropertyNames == ["zeta", "alpha"])
    #expect(value.objectValue?["zeta"]?.objectPropertyNames == ["zulu", "beta"])
    let unordered = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(value))
    #expect(value == unordered)
    #expect(unordered == value)
    #expect(
      value
        == .orderedObject([
          .init("alpha", .integer(3)),
          .init(
            "zeta",
            .object([
              "beta": .integer(2), "zulu": .integer(1),
            ])),
        ]))
  }

  @Test
  func memberEnumerationMatchesSourceIntegerKeysAndDuplicateReplacement() throws {
    let value = try JSONValue(
      jsonData: Data(
        #"{"zeta":0,"10":10,"2":2,"01":1,"4294967295":5,"zeta":9,"alpha":3}"#.utf8))
    #expect(value.objectPropertyNames == ["2", "10", "zeta", "01", "4294967295", "alpha"])
    #expect(value.objectValue?["zeta"] == .integer(9))
    let constructed = JSONValue.orderedObject([
      .init("zeta", .integer(0)), .init("alpha", .integer(3)), .init("zeta", .integer(9)),
    ])
    #expect(constructed.objectPropertyNames == ["zeta", "alpha"])
    #expect(constructed.objectValue == ["zeta": .integer(9), "alpha": .integer(3)])
  }
}

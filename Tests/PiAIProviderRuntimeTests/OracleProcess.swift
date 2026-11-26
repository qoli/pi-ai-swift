import Foundation
import Testing

/// File-backed capture lets the oracle finish even when its output exceeds a pipe's capacity.
func runOracle(_ process: Process) throws -> Data {
  let files = FileManager.default
  let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try files.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? files.removeItem(at: directory) }

  let outputURL = directory.appendingPathComponent("stdout")
  let errorsURL = directory.appendingPathComponent("stderr")
  try Data().write(to: outputURL)
  try Data().write(to: errorsURL)
  let output = try FileHandle(forWritingTo: outputURL)
  defer { try? output.close() }
  let errors = try FileHandle(forWritingTo: errorsURL)
  defer { try? errors.close() }
  process.standardOutput = output
  process.standardError = errors
  try process.run()
  process.waitUntilExit()
  let diagnostic = try String(contentsOf: errorsURL, encoding: .utf8)
  try #require(process.terminationStatus == 0, Comment(rawValue: diagnostic))
  return try Data(contentsOf: outputURL)
}

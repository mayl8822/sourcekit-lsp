//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftParser
import SwiftSyntax

/// The main entry point for generating a JSON schema and Markdown documentation
/// for the SourceKit-LSP configuration file format
/// (`.sourcekit-lsp/config.json`) from the Swift type definitions in
/// `SKOptions` Swift module.
package struct ConfigSchemaGen {
  private struct WritePlan {
    fileprivate let category: String
    fileprivate let path: URL
    fileprivate let contents: () throws -> Data

    fileprivate func write() throws {
      try contents().write(to: path)
    }
  }

  private static let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  private static let sourceDir =
    projectRoot
    .appendingPathComponent("Sources")
    .appendingPathComponent("SKOptions")
  private static let configSchemaJSONPath =
    projectRoot
    .appendingPathComponent("config.schema.json")
  private static let configSchemaDocPath =
    projectRoot
    .appendingPathComponent("Documentation")
    .appendingPathComponent("Configuration File.md")

  /// Generates and writes the JSON schema and documentation for the SourceKit-LSP configuration file format.
  package static func generate() throws {
    let plans = try plan()
    for plan in plans {
      print("Writing \(plan.category) to \"\(plan.path.path)\"")
      try plan.write()
    }
  }

  /// Verifies that the generated JSON schema and documentation in the current source tree
  /// are up-to-date with the Swift type definitions in `SKOptions`.
  /// - Returns: `true` if the generated files are up-to-date, `false` otherwise.
  package static func verify() throws -> Bool {
    let plans = try plan()
    for plan in plans {
      print("Verifying \(plan.category) at \"\(plan.path.path)\"")
      let expectedContents = try plan.contents()
      let actualContents = try Data(contentsOf: plan.path)
      guard expectedContents == actualContents else {
        print("error: \(plan.category) is out-of-date!")
        print("Please run `./sourcekit-lsp-dev-utils generate-config-schema` to update it.")
        return false
      }
    }
    return true
  }

  private static func plan() throws -> [WritePlan] {
    let sourceFiles = FileManager.default.enumerator(at: sourceDir, includingPropertiesForKeys: nil)!
    let typeNameResolver = TypeDeclResolver()

    for case let fileURL as URL in sourceFiles {
      guard fileURL.pathExtension == "swift" else {
        continue
      }
      let sourceText = try String(contentsOf: fileURL)
      let sourceFile = Parser.parse(source: sourceText)
      typeNameResolver.collect(from: sourceFile)
    }
    let rootTypeDecl = try typeNameResolver.lookupType(fullyQualified: ["SourceKitLSPOptions"])
    let context = OptionSchemaContext(typeNameResolver: typeNameResolver)
    var schema = try context.buildSchema(from: rootTypeDecl)

    // Manually annotate the logging level enum since LogLevel type exists
    // outside of the SKOptions module
    schema["logging"]?["level"]?.kind = .enum(
      OptionTypeSchama.Enum(
        name: "LogLevel",
        cases: ["debug", "info", "default", "error", "fault"].map {
          OptionTypeSchama.Case(name: $0)
        }
      )
    )
    schema["logging"]?["privacyLevel"]?.kind = .enum(
      OptionTypeSchama.Enum(
        name: "PrivacyLevel",
        cases: ["public", "private", "sensitive"].map {
          OptionTypeSchama.Case(name: $0)
        }
      )
    )

    return [
      WritePlan(
        category: "JSON Schema",
        path: configSchemaJSONPath,
        contents: { try generateJSONSchema(from: schema, context: context) }
      ),
      WritePlan(
        category: "Schema Documentation",
        path: configSchemaDocPath,
        contents: { try generateDocumentation(from: schema, context: context) }
      ),
    ]
  }

  private static func generateJSONSchema(from schema: OptionTypeSchama, context: OptionSchemaContext) throws -> Data {
    let schemaBuilder = JSONSchemaBuilder(context: context)
    var jsonSchema = try schemaBuilder.build(from: schema)
    jsonSchema.title = "SourceKit-LSP Configuration"
    jsonSchema.comment = "DO NOT EDIT THIS FILE. This file is generated by \(#fileID)."
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(jsonSchema)
  }

  private static func generateDocumentation(from schema: OptionTypeSchama, context: OptionSchemaContext) throws -> Data
  {
    let docBuilder = OptionDocumentBuilder(context: context)
    guard let data = try docBuilder.build(from: schema).data(using: .utf8) else {
      throw ConfigSchemaGenError("Failed to encode documentation as UTF-8")
    }
    return data
  }
}

struct ConfigSchemaGenError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

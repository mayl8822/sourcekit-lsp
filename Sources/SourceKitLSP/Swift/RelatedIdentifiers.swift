//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LSPLogging
import LanguageServerProtocol
import SourceKitD

struct RelatedIdentifier {
  let range: Range<Position>
  let usage: RenameLocation.Usage
}

extension RenameLocation.Usage {
  fileprivate init?(_ uid: sourcekitd_api_uid_t?, _ values: sourcekitd_api_values) {
    switch uid {
    case values.definition:
      self = .definition
    case values.reference:
      self = .reference
    case values.call:
      self = .call
    case values.unknown:
      self = .unknown
    default:
      return nil
    }
  }

  func uid(values: sourcekitd_api_values) -> sourcekitd_api_uid_t {
    switch self {
    case .definition:
      return values.definition
    case .reference:
      return values.reference
    case .call:
      return values.call
    case .unknown:
      return values.unknown
    }
  }
}

struct RelatedIdentifiersResponse {
  let relatedIdentifiers: [RelatedIdentifier]
  /// The compound decl name at the requested location. This can be used as `name` parameter to a
  /// `find-syntactic-rename-ranges` request.
  ///
  /// `nil` if `sourcekitd` is too old and doesn't return the `name` as part of the related identifiers request or
  /// `relatedIdentifiers` is empty (eg. when performing a related identifiers request on `self`).
  let name: String?
}

extension SwiftLanguageServer {
  func relatedIdentifiers(
    at position: Position,
    in snapshot: DocumentSnapshot,
    includeNonEditableBaseNames: Bool
  ) async throws -> RelatedIdentifiersResponse {
    guard let offset = snapshot.utf8Offset(of: position) else {
      throw ResponseError.unknown("invalid position \(position)")
    }

    let skreq = sourcekitd.dictionary([
      keys.request: requests.relatedIdents,
      keys.cancelOnSubsequentRequest: 0,
      keys.offset: offset,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.includeNonEditableBaseNames: includeNonEditableBaseNames ? 1 : 0,
      keys.compilerArgs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDRequestValue]?,
    ])

    let dict = try await self.sourcekitd.send(skreq, fileContents: snapshot.text)

    guard let results: SKDResponseArray = dict[self.keys.results] else {
      throw ResponseError.internalError("sourcekitd response did not contain results")
    }
    let name: String? = dict[self.keys.name]

    try Task.checkCancellation()

    var relatedIdentifiers: [RelatedIdentifier] = []

    results.forEach { _, value in
      if let offset: Int = value[keys.offset],
        let start: Position = snapshot.positionOf(utf8Offset: offset),
        let length: Int = value[keys.length],
        let end: Position = snapshot.positionOf(utf8Offset: offset + length)
      {
        let usage = RenameLocation.Usage(value[keys.nameType], values) ?? .unknown
        relatedIdentifiers.append(
          RelatedIdentifier(range: start..<end, usage: usage)
        )
      }
      return true
    }
    return RelatedIdentifiersResponse(relatedIdentifiers: relatedIdentifiers, name: name)
  }
}

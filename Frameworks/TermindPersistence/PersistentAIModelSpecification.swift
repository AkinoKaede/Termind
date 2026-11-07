// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData

/// Native models.dev JSON is separate from the historical configuration columns.
/// Keeping those columns intact preserves every previously shipped schema.
@Model
public final class PersistentAIModelSpecification {
    @Attribute(.unique) public var modelRecordID: UUID = UUID()
    public var specificationData = Data()

    public init(modelRecordID: UUID, specification: ModelsDevModel) throws {
        self.modelRecordID = modelRecordID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        specificationData = try encoder.encode(specification)
    }

    public func apply(to model: inout AIModel) {
        guard let specification = try? JSONDecoder().decode(ModelsDevModel.self, from: specificationData),
            specification.id == model.id
        else { return }
        model.specification = specification
    }
}

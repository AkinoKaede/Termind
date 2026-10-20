// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import Observation
import TermindApplication
import TermindPresentation

@MainActor @Observable
final class MobileSkillEditorModel {
    let original: AgentSkill
    var draft: AgentSkill
    private let library: SkillLibraryModel
    private let wasPersisted: Bool
    init(library: SkillLibraryModel, skill: AgentSkill) {
        self.library = library
        original = skill
        draft = skill
        wasPersisted = library.skill(skill.id) != nil
    }
    var isDirty: Bool { draft != original }
    var canSave: Bool {
        draft.summary.count <= AgentSkill.maximumSummaryCharacters
            && draft.body.utf8.count <= AgentSkill.maximumBodyBytes
    }
    func save() throws {
        guard canSave else { return }
        var value = draft
        if wasPersisted {
            guard let current = library.skill(original.id) else {
                throw MobileEditorError.message(String(localized: AppStrings.Settings.skillDeleted))
            }
            var fields = SettingsFields(original, draft, current)
            if draft.name != original.name {
                guard library.conflictingSkillIDs.contains(original.id), AgentSkillNaming.isValid(draft.name),
                    !library.hasNameConflict(draft.name, excluding: draft.id)
                else {
                    throw MobileEditorError.message(
                        String(localized: AppStrings.Settings.anotherSkillAlreadyUsesThisName))
                }
                try fields.merge(\.name)
            }
            try fields.merge(\.isEnabled)
            try fields.merge(\.title)
            try fields.merge(\.summary)
            try fields.merge(\.body)
            try fields.merge(\.package)
            value = fields.result
        }
        if value.name.isEmpty, AgentSkillNaming.isValid(value.effectiveName),
            !library.hasNameConflict(value.effectiveName, excluding: value.id)
        {
            value.name = value.effectiveName
        }
        library.upsert(value)
        if let error = library.storageError { throw MobileEditorError.message(error) }
    }
}

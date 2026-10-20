// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

/// Optional interaction overrides for workflows that keep the picker mounted
/// after confirmation. Existing callers keep synchronous save-and-dismiss behavior.
struct MobileMultiHostPickerInteraction {
    var allowsSelection = true
    var allowsDismissal = true
    var allowsConfirmation = true
    var dismissesOnSave = true

    static let standard = MobileMultiHostPickerInteraction()
}

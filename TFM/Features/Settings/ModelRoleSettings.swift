// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindPresentation

struct ModelRoleSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View { TermindPresentation.ModelRoleSettings(ai: app.aiConfiguration) }
}

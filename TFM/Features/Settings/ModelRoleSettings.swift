import SwiftUI
import TermindPresentation

struct ModelRoleSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View { TermindPresentation.ModelRoleSettings(ai: app.aiConfiguration) }
}

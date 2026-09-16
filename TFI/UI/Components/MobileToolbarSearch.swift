import SwiftUI
import TermindPresentation

extension View {
    @ViewBuilder
    func mobileToolbarSearch(text: Binding<String>, prompt: Text? = nil) -> some View {
        if #available(iOS 26.0, *) {
            searchable(text: text.singleLineText, placement: .toolbar, prompt: prompt)
                .searchToolbarBehavior(.minimize)
        } else {
            searchable(text: text.singleLineText, placement: .toolbar, prompt: prompt)
        }
    }

    @ViewBuilder
    func mobileToolbarSearch(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        prompt: Text? = nil
    ) -> some View {
        if #available(iOS 26.0, *) {
            searchable(text: text.singleLineText, isPresented: isPresented, placement: .toolbar, prompt: prompt)
                .searchToolbarBehavior(.minimize)
        } else {
            searchable(text: text.singleLineText, isPresented: isPresented, placement: .toolbar, prompt: prompt)
        }
    }
}

import SwiftUI
import TermindPresentation
import UIKit

extension View {
    func mobileToolbarSearch(
        text: Binding<String>,
        isPresented: Binding<Bool>? = nil,
        prompt: LocalizedStringResource,
        onSubmit: @escaping () -> Void = {}
    ) -> some View {
        background {
            MobileToolbarSearchAnchor(
                text: text.singleLineText, isPresented: isPresented, prompt: prompt,
                onSubmit: onSubmit)
        }
    }
}

private struct MobileToolbarSearchAnchor: UIViewControllerRepresentable {
    let text: Binding<String>
    let isPresented: Binding<Bool>?
    let prompt: LocalizedStringResource
    let onSubmit: () -> Void
    @Environment(\.locale) private var locale

    func makeUIViewController(context: Context) -> MobileToolbarSearchController {
        MobileToolbarSearchController()
    }

    func updateUIViewController(_ controller: MobileToolbarSearchController, context: Context) {
        var prompt = prompt
        prompt.locale = locale
        controller.configure(
            text: text, isPresented: isPresented, placeholder: String(localized: prompt),
            onSubmit: onSubmit)
    }

    static func dismantleUIViewController(_ controller: MobileToolbarSearchController, coordinator: ()) {
        controller.disconnect()
    }
}

/// UIKit owns the entire search presentation. SwiftUI's searchable focus and
/// presentation bindings can otherwise reopen an integrated toolbar mid-dismissal.
@MainActor
private final class MobileToolbarSearchController: UIViewController, UISearchControllerDelegate, UISearchBarDelegate {
    private let search = UISearchController(searchResultsController: nil)
    private var text: Binding<String>?
    private var presentation: Binding<Bool>?
    private var onSubmit: () -> Void = {}
    private var isEnabled = false
    private var isDismissing = false
    private weak var owner: UIViewController?
    private var previousDefinesPresentationContext = false

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        search.delegate = self
        search.searchBar.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
    }

    func configure(
        text: Binding<String>, isPresented: Binding<Bool>?, placeholder: String,
        onSubmit: @escaping () -> Void
    ) {
        self.text = text
        presentation = isPresented
        isEnabled = true
        self.onSubmit = onSubmit
        search.searchBar.placeholder = placeholder
        // Configuration comes from a SwiftUI update. Defer UIKit's delegate
        // callbacks, which can publish presentation changes back to the model.
        DispatchQueue.main.async { [weak self] in self?.synchronize() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        synchronize()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil { synchronize() }
    }

    private var navigationOwner: UIViewController? {
        var child: UIViewController = self
        while let parent = child.parent {
            if parent is UINavigationController { return child }
            child = parent
        }
        return nil
    }

    private func synchronize() {
        guard isEnabled else {
            removeSearch()
            return
        }
        guard let destination = navigationOwner else { return }
        if owner !== destination {
            removeSearch()
            owner = destination
            previousDefinesPresentationContext = destination.definesPresentationContext
            destination.definesPresentationContext = true
        }
        let item = destination.navigationItem
        if item.searchController !== search {
            if #available(iOS 26.0, *) {
                item.preferredSearchBarPlacement = .integratedButton
            } else {
                item.preferredSearchBarPlacement = .inline
            }
            item.searchController = search
        }
        guard !isDismissing else { return }
        if search.searchBar.text != text?.wrappedValue {
            search.searchBar.text = text?.wrappedValue
        }
        if let requested = presentation?.wrappedValue, search.isActive != requested {
            if requested {
                search.isActive = true
                search.searchBar.becomeFirstResponder()
            } else {
                dismissSearch()
            }
        }
    }

    func disconnect() {
        isEnabled = false
        removeSearch()
    }

    private func removeSearch() {
        if search.isActive { dismissSearch() }
        if let owner, owner.navigationItem.searchController === search {
            owner.navigationItem.searchController = nil
            owner.definesPresentationContext = previousDefinesPresentationContext
        }
        owner = nil
    }

    private func publishPresentation(_ presented: Bool) {
        guard let presentation, presentation.wrappedValue != presented else { return }
        presentation.wrappedValue = presented
    }

    private func dismissSearch() {
        // Do not accept a new presentation until UIKit completes this dismissal.
        isDismissing = true
        search.searchBar.resignFirstResponder()
        publishPresentation(false)
        search.isActive = false
    }

    func willPresentSearchController(_ searchController: UISearchController) {
        guard isEnabled, !isDismissing else {
            searchController.isActive = false
            return
        }
        searchController.searchBar.text = text?.wrappedValue
        publishPresentation(true)
    }

    func willDismissSearchController(_ searchController: UISearchController) {
        isDismissing = true
        publishPresentation(false)
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        isDismissing = false
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        dismissSearch()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard !isDismissing else { return }
        text?.wrappedValue = searchText
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard !isDismissing else { return }
        onSubmit()
    }
}

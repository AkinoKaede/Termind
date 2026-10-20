// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import PhotosUI
import SwiftUI

/// PHPicker exposes file providers without requesting access to the entire library.
struct MobileTerminalPhotoPicker: UIViewControllerRepresentable {
    let selected: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 0
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let selected: ([NSItemProvider]) -> Void
        init(selected: @escaping ([NSItemProvider]) -> Void) { self.selected = selected }
        func picker(_: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            selected(results.map(\.itemProvider))
        }
    }
}

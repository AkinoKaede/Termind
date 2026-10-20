// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

public nonisolated enum HostIconArtwork: Equatable, Sendable {
    case asset(String)
    case systemImage(String)

    public var assetName: String? {
        if case .asset(let name) = self { name } else { nil }
    }

    public var systemImageName: String? {
        if case .systemImage(let name) = self { name } else { nil }
    }

    public var image: Image {
        switch self {
        case .asset(let name): Image(name, bundle: .main)
        case .systemImage(let name): Image(systemName: name)
        }
    }
}

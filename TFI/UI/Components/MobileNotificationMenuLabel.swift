// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import UIKit

/// Native menus extract an image from their label, so the unread dot must be part of that image.
struct MobileNotificationMenuLabel: View {
    let title: String
    let symbol: String
    let hasUnread: Bool
    var isToolbar = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            if hasUnread, let image = badgedImage {
                Image(uiImage: image).renderingMode(.original)
            } else {
                Image(systemName: symbol)
            }
        }
    }

    private var badgedImage: UIImage? {
        guard let symbol = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17))
        else { return nil }
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let tint = (isToolbar ? UIColor(Color.accentColor) : .label).resolvedColor(with: traits)
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        let size = CGSize(width: symbol.size.width + 6, height: symbol.size.height + 6)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            symbol.withTintColor(tint, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: 3, y: 3))
            UIColor(Color.accentColor).resolvedColor(with: traits).setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width - 6, y: 0, width: 6, height: 6)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}

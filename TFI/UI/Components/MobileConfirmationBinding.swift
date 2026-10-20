// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

extension Binding {
    /// Only the selected row presents. A dismissed or recycled row cannot clear another row's request.
    func isPresenting<Selection>(matching matches: @escaping (Selection) -> Bool) -> Binding<Bool>
    where Value == Selection? {
        Binding<Bool>(
            get: { wrappedValue.map(matches) == true },
            set: { presented in
                if !presented, wrappedValue.map(matches) == true { wrappedValue = nil }
            })
    }
}

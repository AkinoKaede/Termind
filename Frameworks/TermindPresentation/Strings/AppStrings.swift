// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Semantic copy shared by the macOS and iOS apps. Resources are created on demand,
/// keeping localization at the display boundary. The catalog is compiled into each
/// application's main bundle; platform-specific wording uses explicit feature variants.
public nonisolated enum AppStrings {}

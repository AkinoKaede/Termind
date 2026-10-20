// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension DispatchQueue {
    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            async {
                do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func perform(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            async {
                operation()
                continuation.resume()
            }
        }
    }
}

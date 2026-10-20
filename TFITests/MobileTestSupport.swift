// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Testing
import UIKit

/// Shared traversal and polling helpers for the UIKit-hosted mobile suites.

func descendants<T: UIViewController>(
    of type: T.Type, in controller: UIViewController
) -> [T] {
    var pending = [controller]
    var visited = Set<ObjectIdentifier>()
    var results: [T] = []
    while let next = pending.popLast() {
        guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
        if let result = next as? T { results.append(result) }
        pending.append(contentsOf: next.children)
        if let presented = next.presentedViewController { pending.append(presented) }
    }
    return results
}

func descendant<T: UIViewController>(of type: T.Type, in controller: UIViewController) -> T? {
    descendants(of: type, in: controller).first
}

func descendant<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
    if let result = controller as? T { return result }
    return controller.children.lazy.compactMap { descendant(type, in: $0) }.first
}

func descendant<T: UIView>(of type: T.Type, in view: UIView) -> T? {
    if let result = view as? T { return result }
    for subview in view.subviews {
        if let result = descendant(of: type, in: subview) { return result }
    }
    return nil
}

func descendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
    if let result = view as? T { return result }
    return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
}

func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
}

func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
}

func presented(in controller: UIViewController) -> UIViewController? {
    controller.presentedViewController ?? controller.children.lazy.compactMap { presented(in: $0) }.first
}

func menuActions(_ menu: UIMenu) -> [UIAction] {
    menu.children.flatMap { element -> [UIAction] in
        if let action = element as? UIAction { return [action] }
        if let submenu = element as? UIMenu { return menuActions(submenu) }
        return []
    }
}

func toolbarButton(named name: String, in navigation: UINavigationController) -> UIBarButtonItem? {
    guard let item = navigation.topViewController?.navigationItem else { return nil }
    let buttons =
        item.leadingItemGroups.flatMap(\.barButtonItems)
        + item.trailingItemGroups.flatMap(\.barButtonItems)
        + (item.leftBarButtonItems ?? [])
        + (item.rightBarButtonItems ?? [])
    return buttons.first {
        $0.accessibilityLabel == name || $0.title == name || $0.customView?.accessibilityLabel == name
    }
}

@MainActor
func eventually(attempts: Int = 100, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

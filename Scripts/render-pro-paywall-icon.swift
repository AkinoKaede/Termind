import AppKit
import SwiftUI

// Preserve the former native Pro hero in RevenueCat's remote image component.
// Run from the repository root: swift Scripts/render-pro-paywall-icon.swift
@MainActor
func renderIcon(name: String, red: Double, green: Double, blue: Double) throws {
    let content = Image(systemName: "sparkles.rectangle.stack.fill")
        .font(.system(size: 52, weight: .medium))
        .foregroundStyle(.tint)
        .tint(Color(red: red, green: green, blue: blue))
        .symbolRenderingMode(.hierarchical)
        .frame(width: 80, height: 72)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 4
    guard let cgImage = renderer.cgImage,
        let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    let directory = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "Design/Brand/ProPaywall", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try png.write(to: directory.appending(path: name))
}

try MainActor.assumeIsolated {
    try renderIcon(name: "pro-hero-light.png", red: 0, green: 122.0 / 255, blue: 1)
    try renderIcon(name: "pro-hero-dark.png", red: 10.0 / 255, green: 132.0 / 255, blue: 1)
}

# App icon

`Termind/Resources/AppIcon.icon` is the source of truth for the application icon.
Xcode recognizes it through the synchronized Termind folder and the existing
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` setting.

## Artwork and rendering

- `Assets/Artwork.png` is a full-bleed, opaque, 1024 × 1024 sRGB image. It preserves
  the existing symbol, blue gradient, and baked-in lighting. Its outer background
  was extended to remove the old transparent border and pre-rendered rounded rim.
- Keep the artwork square and unmasked. Do not add Dock padding or rounded corners
  to this source image. Icon Composer and Xcode own the platform mask and padding.
- The image is intentionally flattened to retain the existing design. Additional
  glass, specular, translucency, and group-shadow effects are disabled to avoid
  applying a second set of effects to the artwork.
- Xcode compiles the modern icon stack and generates the compatibility `AppIcon.icns`
  for the macOS 15 deployment target. Do not restore a competing PNG appiconset or
  maintain the generated icon sizes by hand.

## Verification

Build using the pinned package versions. Inspect the compiled asset catalog for
an `AppIcon` icon stack containing opaque, full-canvas artwork, and inspect the
generated ICNS for a visible width of about 80.5% of its canvas (206 of 256 pixels).
Use a temporary bundle with a distinct identifier when checking system rendering;
`NSWorkspace` can otherwise return an older cached image after a rebuild.

Check the actual TestFlight listing after uploading a new build. Local rendering
and successful compilation do not verify App Store Connect's icon processing.

# App icon

`Termind/Resources/AppIcon.icon` is the source of truth and is selected by
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

- `Assets/Artwork.png` is opaque, full-bleed, square 1024 x 1024 sRGB artwork.
  Keep it unmasked: Icon Composer/Xcode owns platform padding and corner masks.
- The flattened artwork already contains its gradient and lighting. Keep glass,
  specular, translucency, and group-shadow effects disabled, and do not restore a
  competing PNG appiconset or hand-maintained generated sizes.
- Xcode produces the modern icon stack and compatibility `AppIcon.icns` for the
  macOS 15 deployment target.

Verify with pinned dependencies: inspect the compiled `AppIcon` stack for opaque
full-canvas artwork and ICNS visible width near 206/256 pixels. Use a temporary
bundle identifier to avoid `NSWorkspace` cache, then confirm the uploaded
TestFlight listing because local compilation does not verify App Store processing.

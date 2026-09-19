# App icons

Sources: `TFM/Resources/AppIcon.icon` and `TFI/Resources/AppIcon.icon`, selected by
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Each contains layered SVGs:
Terminal, FrontWindow, MiddleWindow and BackWindow. Preserve `icon.json` layer order,
lighting and platform declarations; glass/specular/translucency are disabled, while
window layers have subtle shadows. The old flattened `Artwork.png` workflow is obsolete.

Icon Composer/Xcode owns padding, masks and compatibility output. Do not add a competing
PNG appiconset or hand-maintained generated sizes. Verify both compiled platform icons
with pinned builds; use a temporary bundle identifier to bypass macOS icon cache.
Local compilation does not verify App Store processing: inspect the uploaded TestFlight icon.

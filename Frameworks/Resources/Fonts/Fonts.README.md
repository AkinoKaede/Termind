# Bundled terminal fonts

The patched families come from Nerd Fonts **v3.4.0**, using the standard
`Nerd Font` variant (not `Nerd Font Mono` or `Nerd Font Propo`).
JetBrains Mono comes from the official **v2.304** release. All files are unmodified.

| Family | Upstream family | Faces |
| --- | --- | --- |
| SauceCodePro Nerd Font | Source Code Pro | Regular, Bold, Italic, BoldItalic |
| FiraCode Nerd Font | Fira Code | Regular, Bold |
| JetBrains Mono | JetBrains Mono | Regular, Bold, Italic, BoldItalic |

`Fonts.sources.json` records each file's upstream URL, size, and SHA-256 digest.
The accompanying `SauceCodePro-LICENSE.txt`, `FiraCode-LICENSE.txt`,
`NerdFonts-LICENSE.txt`, and `JetBrainsMono-OFL.txt` retain the upstream copyright and license notices.
These font assets are distributed under their own licenses, not the app's
source-code license.

Xcode's synchronized Resources group copies the files to each app's resource
root. iOS declares the ten faces in `UIAppFonts`; macOS registers fonts at
the resource root through `ATSApplicationFontsPath`. App-hosted tests verify
the actual registration and resource URLs on both platforms.

Ghostty's private embedded JetBrains Mono is a fallback, not a CoreText-registered
family. The official faces are also bundled here so users can explicitly select
and preview JetBrains Mono without installing it on their device. Nerd symbols
continue to use Ghostty's embedded symbol fallback. The default “Follow Theme”
preference is unchanged. These resources are excluded from the widget target.

# Website and App Store marketing workflow

This file is the durable source of truth for Termind website screenshots,
MockUPhone device renders, Figma App Store artwork, localization, and export
verification. It covers marketing infrastructure only. Do not change product
behavior to make a screenshot easier to capture.

## Scope and invariants

- Production SwiftUI, persistence, navigation, networking, and settings behavior
  are out of scope. Screenshot-only tests and scripts may construct real app views
  with in-memory fixtures.
- Source screenshots are immutable inputs. Never overwrite a source while framing,
  composing, or exporting marketing artwork.
- The screenshot tree is feature-first. Do not reorganize it by device.
- All fixtures use in-memory fake hosts, files, metrics, and conversations. They
  never connect to a real host, account, or network service.
- Terminal commands and output stay in English in every locale. Only app chrome,
  marketing titles, and explanatory copy are localized.
- iPhone and iPad captures must include the real system status bar, navigation
  title, back/sidebar controls, toolbar controls, and home indicator. Do not draw
  any of them by hand in Figma, CSS, or an image editor.
- A Mac capture is valid only while the capture window is the active key window.
  The colored traffic lights and blue focused-pane outline are visible evidence.
- Website CSS may position and shadow device artwork, but must never recreate a
  bezel, notch, laptop body, screen mask, status bar, or traffic lights.
- Traditional Chinese follows Taiwan usage. In particular, Server is `伺服器`.
  Use PingFang SC for Simplified Chinese and PingFang TC for Traditional Chinese.

## Asset layout

Raw captures and their generated device frames live separately under:

```text
Marketing/Screenshots/Captures/<feature>/<device>-<locale>.png
Marketing/Screenshots/DeviceFrames/<feature>/<device>-<locale>-framed.png
```

The website imports its allowlist from `DeviceFrames` through
`LandingPage/src/lib/marketingImages.ts`; Astro emits optimized AVIF, WebP and JPEG
assets during the build. Do not copy these sources into `LandingPage/public`.

Locales in filenames are `en`, `zh-hans`, and `zh-hant`. Current feature folders
include `workspace`, `ssh`, `sftp`, `metrics`, `assistant`, `vault`, and
`command-generator`. A missing platform file is not permission to fabricate UI.

Raw captures have no `-framed` suffix. Framing scripts may replace a framed file,
but must never replace its raw input. The Mac capture script backs up previous raw
Workspace files under `.build/screenshot-backups/<timestamp>/` before replacement.

## iPhone and iPad source captures

The source is `TFITests/MobileMarketingScreenshotTests.swift`. It mounts the real
SwiftUI feature views in a system window and uses in-memory demo models. The test
and the external script exchange a ready/acknowledgement marker so `simctl` captures
the complete simulator display rather than only a rendered view hierarchy.

Generate every mobile source:

```sh
Scripts/run-mobile-marketing-screenshots.sh
```

The required devices and outputs are:

- iPhone 17 Pro Max, portrait, `1320x2868`.
- iPad Pro 13-inch (M5), landscape, `2752x2064`.
- Five scenes per locale: `vault`, `sftp`, `ssh`, `metrics`, and `assistant`.
- Three locales, producing 15 screenshots per device and 30 total.

For a targeted recapture, set both filters. This example refreshes only the three
localized iPad Assistant sources:

```sh
TERMIND_MARKETING_SCENES=assistant \
TERMIND_MARKETING_DEVICES=ipad \
Scripts/run-mobile-marketing-screenshots.sh
```

The iPhone Vault, Metrics and Assistant fixtures use the same native `Tab` API,
sidebar-adaptable style and feature registration order as the production shell:
Vault, Metrics, Workspaces, Assistant, Settings. Metrics is its own selected tab;
Vault no longer contains the former Metrics navigation row. Refresh all nine
localized sources after a change to that navigation:

```sh
TERMIND_MARKETING_SCENES=vault,metrics,assistant \
TERMIND_MARKETING_DEVICES=iphone \
Scripts/run-mobile-marketing-screenshots.sh
```

Regenerate only their matching device frames, replace the corresponding Figma
iPhone boards 04-06, and export those nine boards again. The three-device first
boards use iPhone SSH and therefore do not change for this navigation refresh.

The runner sets a deterministic `9:41` status bar, charged battery, Wi-Fi, and
cellular state. iPad framebuffer output is rotated after capture because `simctl`
keeps portrait pixel orientation for a landscape display. Confirm the final file
dimensions rather than trusting Simulator orientation alone.

Whenever SFTP, Metrics, Assistant navigation, or system chrome changes, recapture
the affected device and every locale. A marketing fixture may be updated to expose
the current UI, but it must not add production behavior.

## Mac Workspace source captures

The source is `TFMTests/MacMarketingScreenshotTests.swift`. It constructs the real
`RootView` and `ScreenshotDemoConfiguration` inside a native `NSWindow`. Before it
publishes the ready marker, it requires both `NSApp.isActive` and
`window.isKeyWindow`.

Generate all three localized Workspace sources:

```sh
Scripts/run-mac-marketing-screenshots.sh
```

The runner:

1. builds the TFM test host from the pinned package resolution;
2. launches one locale at a time with matching Apple language and region;
3. waits for an active/key window marker;
4. captures the system window by window number;
5. removes only the two-pixel transparent capture edge when present;
6. verifies a final `2360x1480` sRGB source.

The current Workspace contains focused English terminal panes and the current SFTP
browser. SFTP filenames, types, dates, and app chrome localize; terminal transcripts
do not. Re-run this flow whenever desktop SFTP or Workspace UI changes.

## MockUPhone device renders

`Scripts/generate-mockuphone-assets.py` uses MockUPhone's front-facing Apple device
templates and its screen geometry. Run it with the workspace Python runtime, which
provides Pillow:

```sh
/Users/kaede/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  Scripts/generate-mockuphone-assets.py
```

Selected device templates are the highest-end suitable models currently available
in MockUPhone:

- iPhone 15 Pro Max, Black Titanium, portrait.
- iPad Pro 13-inch, Space Gray, landscape.
- MacBook Pro 16-inch, front.

The generator creates 15 framed iPhone files, 15 framed iPad files, and three
framed Mac Workspace files. Device templates are credited by MockUPhone to Apple
Design Resources.

The Mac source is a window, not a complete desktop. Before it enters the MacBook
screen, the generator places it over a deterministic Termind-owned blue/cyan
abstract background. The background contains no Apple wallpaper, third-party
photography, Dock, desktop icons, or user data. The window occupies approximately
91% of screen width and 88% of screen height, leaving a visible border of the
background. Do not add a second titlebar or another set of traffic lights.

## Website integration

The Astro homepage imports `*-framed.png` files through `marketingImages.ts` and
renders them with `ScreenshotPicture.astro`. Keep source dimensions synchronized
with generated assets:

- iPhone framed: `1530x3036`.
- iPad framed: `2960x2290`.
- MacBook framed: `4340x2860`.

Device images use their intrinsic aspect ratio and `object-fit: contain`. Feature
containers may clip decorative shadows, but never device pixels. A complete device
must remain visible from status/title bar through the bottom toolbar or home
indicator.

Formal locale routes are `/`, `/zh-hans/`, and `/zh-hant/`. `/zh/` and its child
paths remain compatibility redirects to Simplified Chinese. Automatic language
detection runs only on the root English path and respects `termind.locale` after a
manual selection. Taiwan displays `正體中文`; Hong Kong, Macau, and generic Hant
display `繁體中文`.

The App Store call-to-action uses the restored Apple silhouette path. Do not replace
it with a dot, text glyph, emoji, or CSS circle.

### Homepage messaging

The primary story is a capable, permission-aware remote workspace, not merely the
number of supported devices. Keep the established line:

```text
Your terminal, with judgment.
你的终端，自有判断。
```

The concise Hero description is:

```text
SSH, SFTP, workspaces, and a bring-your-own-key AI assistant—built as one native
app. It can inspect, explain, and act, but only inside boundaries you control.
```

Platform-specific marketing must state a useful workflow rather than physical
screen size or implementation trivia:

- SFTP: `Move files. Keep your flow.` / `传文件，不必换工具。` Emphasize browse,
  preview, drag-to-upload, background transfers, and opening the same path in SSH.
- Metrics: `Know which server needs you.` / `哪台服务器需要你，一眼就知道。`
  Emphasize finding abnormal hosts, drilling into pressure, and continuing over the
  same SSH connection. Sync exclusions belong in FAQ or Privacy, not the feature
  pitch.
- Assistant: `An agent that knows when to ask.` / `会行动，也懂得先询问。`
- Vault: `Your Vault, protected by design.` / `你的保管库，安全为先。` Explain
  private iCloud sync and separate Keychain protection in one concise sentence.
- Built-in MCP Server remains a prominent Mac-only section. Keep tool-level control,
  loopback-default access, and auditability visible without turning the Hero into a
  protocol description.

## Figma and Figwright workflow

The App Store source of truth is the connected Figma design file named `Termind`.
Use the Figwright MCP connection, not the rate-limited hosted Figma MCP, for this
file. The Figwright plugin must be running in the target Figma tab.

Before any write:

1. call `ping`;
2. call `list_files`;
3. claim `Termind` when more than one file is connected;
4. inspect variables, local components, styles, fonts, and existing pages;
5. stop rather than writing into a different or unclaimed file.

The file pages are `Foundations`, `Components`, `App Store Mac`,
`App Store iPhone`, `App Store iPad`, and `Promo`. Reuse the established Termind
color, scale, typography, title-block, platform-label, and screenshot-surface
assets. Build and screenshot-check English first, then expand to both Chinese
locales.

The final matrix is exactly 54 store boards:

```text
3 locales x 3 platform sets x 6 boards = 54
```

Board sizes:

- Mac: `2880x1800`.
- iPhone 6.5-inch: `1284x2778` (the raw simulator capture remains `1320x2868`).
- iPad 13-inch: `2752x2064`.

Content order:

| Number | iPhone / iPad | Mac |
| --- | --- | --- |
| 01 | Mac + iPhone + iPad | Mac + iPhone + iPad |
| 02 | SSH | Workspace |
| 03 | SFTP | Metrics |
| 04 | Metrics | Assistant |
| 05 | Assistant | Vault |
| 06 | Vault | Command Generator |

Mockup rules are strict:

- iPhone and iPad use MockUPhone artwork on all six boards.
- Mac uses MockUPhone only on board 01.
- Mac boards 02-06 use native window screenshots with one consistent soft window
  shadow. Do not add another hardware or window frame.
- The first board uses Mac Workspace, iPhone SSH, and iPad SFTP as complementary
  scenes. All three devices remain completely visible.

English uses SF Pro. Simplified Chinese uses PingFang SC. Traditional Chinese uses
PingFang TC and Taiwan terminology. Platform labels remain `MAC`, `IPHONE`, and
`IPAD`; do not translate product platform names.

Useful Figma node IDs from the completed file:

- Foundations: `25:54`.
- Components: `25:96`.
- Mac locale sections: `25:106`, `25:308`, `25:374`.
- iPhone locale sections: `25:173`, `25:440`, `25:511`.
- iPad locale sections: `25:236`, `25:582`, `25:653`.

## App Store exports

Export the 54 final boards as high-quality, opaque, sRGB JPG files:

```text
Marketing/AppStore/<locale>/mac/01-06-*.jpg
Marketing/AppStore/<locale>/iphone-6.5/01-06-*.jpg
Marketing/AppStore/<locale>/ipad-13/01-06-*.jpg
```

No `.DS_Store`, preview, manifest, temporary PNG, or Figma helper file belongs in
the delivery tree. A quick verification is:

```sh
test "$(find Marketing/AppStore -type f -name '*.jpg' | wc -l | tr -d ' ')" = 54
test -z "$(find Marketing/AppStore -type f ! -name '*.jpg' -print -quit)"

for platform in mac iphone-6.5 ipad-13; do
  find Marketing/AppStore -path "*/$platform/*.jpg" -print0 \
    | xargs -0 identify -format '%wx%h %[colorspace] %[channels] opaque=%[opaque]\n' \
    | sort | uniq -c
done
```

Expected grouped results are 18 opaque sRGB three-channel images at each platform
size. Review every board at 100% in Figma and inspect contact sheets for each
platform/locale before delivery.

Use Figwright `save_screenshots` with `format: "JPG"` and `scale: 1` for final
exports. `get_screenshot` is for visual review and caps its output size; it is not
the delivery export path. Keep temporary node-ID filenames outside `Marketing/AppStore`
and copy the verified full-size results to the established locale/platform names.

## Verification checklist

Run after screenshot, copy, route, or marketing changes:

```sh
cd LandingPage && npm run build
cd .. && Scripts/check-zh-localization.sh
xcrun swift-format lint --strict \
  TFITests/MobileMarketingScreenshotTests.swift \
  TFMTests/MacMarketingScreenshotTests.swift
zsh -n \
  Scripts/run-mobile-marketing-screenshots.sh \
  Scripts/run-mac-marketing-screenshots.sh
/Users/kaede/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  -m py_compile Scripts/generate-mockuphone-assets.py
```

Also confirm manually:

- all formal and compatibility routes build;
- the Apple icon renders in the App Store button;
- no CSS bezel obscures a screenshot;
- iOS status/navigation chrome is real and complete;
- SFTP reflects the current production UI on every platform;
- iPad Assistant is the latest capture;
- Mac traffic lights are colored, one pane has the active blue outline, and the
  MacBook render contains no Dock or copyrighted wallpaper;
- Chinese glyphs use the intended PingFang family;
- Traditional Chinese uses `伺服器` and other Taiwan-standard terms;
- the store export directory contains exactly 54 final JPG files.

As of 2026-09-13, these checks pass and the 54 exported files are present under
`Marketing/AppStore`.

The 2026-09-18 iPhone navigation refresh regenerated the English, Simplified
Chinese and Traditional Chinese Metrics, Assistant and Vault captures, device
frames and Figma exports. SHA-256 verification confirmed that exactly those 27
images changed; the other 108 marketing files, including SSH/SFTP, first boards,
iPad and Mac assets, stayed unchanged. The nine Figma image fills match the local
device-frame PNGs byte for byte, and the nine final JPGs are full-size
`1284x2778` opaque sRGB exports. The App Store directory still contains 54 JPGs.

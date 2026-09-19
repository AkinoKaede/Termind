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
files by feature under `.build/screenshot-backups/<timestamp>/` before replacement.

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

The runner defaults to the iOS/iPadOS 26.5 simulator runtime so installing a newer
runtime cannot silently change the marketing UI or select another same-name
device. Set `TERMIND_MARKETING_RUNTIME` to a full CoreSimulator runtime identifier
only when intentionally updating the runtime used for a capture set.
An iPad-only selection builds on the selected iPad and does not require an iPhone
simulator to be installed.

Each locale launches a separate test process with matching Apple language, region,
and locale arguments. `TERMIND_MARKETING_LOCALE` selects that process's fixture
language, so Foundation-localized strings (including Vault's last-connection label)
match SwiftUI labels. The iPhone fixture requests portrait orientation through its
window scene; the runner does not depend on Simulator menu automation.

For a targeted recapture, set both filters. This example refreshes only the three
localized iPad Assistant sources:

```sh
TERMIND_MARKETING_SCENES=assistant \
TERMIND_MARKETING_DEVICES=ipad \
Scripts/run-mobile-marketing-screenshots.sh
```

The iPhone and iPad Vault, Metrics and Assistant fixtures use the same native `Tab` API,
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

For the matching nine iPad sources, run:

```sh
TERMIND_MARKETING_SCENES=vault,metrics,assistant \
TERMIND_MARKETING_DEVICES=ipad \
Scripts/run-mobile-marketing-screenshots.sh
```

The iPad fixtures use the native adaptive tab container: Metrics shows the top
tab bar, while Assistant and Vault show the expanded sidebar. Each capture fixes
that presentation independently of restored simulator state. They do not add
simulated sidebar or back buttons to the top-level Metrics and Assistant pages.
Regenerate only the matching nine iPad device frames and App Store boards 04-06;
first boards use iPad SFTP and remain unchanged.

The iPad SSH and SFTP fixtures mount the production `MobileRootView` and workspace
pages, with deterministic in-memory data supplied through the existing
`MobileWorkspaceConnectionServices`. They select Workspaces, collapse the native
sidebar, and show the current top tabs, workspace switcher and action menu. Keep
the iPhone-only legacy scene wrappers out of this iPad path. Terminal output stays
English in every locale. The approved topbar capture set uses iPadOS 27.0:

```sh
TERMIND_MARKETING_SCENES=ssh,sftp \
TERMIND_MARKETING_DEVICES=ipad \
TERMIND_MARKETING_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
Scripts/run-mobile-marketing-screenshots.sh
```

Refresh those six device frames and iPad boards 02–03, plus the iPad SFTP image in
all nine three-device first boards. Other frames and boards are outside that set.

The runner sets a deterministic `9:41` status bar, charged battery, Wi-Fi, and
cellular state. It sets the iPad orientation and captures its landscape display
with `devicectl`, verifying `2752x2064` before acknowledging each capture. The
iPhone uses `simctl` screenshots. No post-capture rotation is required.
Each locale process receives a fresh `TERMIND_MARKETING_CAPTURE_ID`; the runner
ignores ready markers from earlier processes. Captures are staged under the
derived-data directory and copied to the source tree only after the tests and
expected capture count pass. Back up raw images and a SHA-256 manifest before
running a refresh.

Whenever SFTP, Metrics, Assistant navigation, or system chrome changes, recapture
the affected device and every locale. A marketing fixture may be updated to expose
the current UI, but it must not add production behavior.

## Mac source captures

The source is `TFMTests/MacMarketingScreenshotTests.swift`. It captures the existing
production WindowGroup launched with `ScreenshotDemoConfiguration`; it never
mounts a second RootView or duplicates a terminal/transcript surface. Before it
publishes the ready marker, it requires both `NSApp.isActive` and
`window.isKeyWindow`, allows the focused appearance to render, and requires native
2× backing scale. Focus is checked again when the capture is acknowledged.
The focus retry loop also requires activation to survive the 300 ms appearance
render interval. Do not run another Mac app activation alongside a capture.

Generate all three localized Workspace sources:

```sh
Scripts/run-mac-marketing-screenshots.sh
```

The default remains Workspace. Use `TERMIND_MAC_MARKETING_SCENES` to select a
comma-separated subset of `hosts`, `workspace`, `agent`, `command`, and `metrics`.
Use `TERMIND_MAC_MARKETING_LOCALES` for `en`, `zh-Hans`, and `zh-Hant` (all three by
default). The filename mappings are Vault `mac`, Workspace `mac`, Assistant `mac`,
Command Generator `mac`, and Metrics `mac-overview`, respectively. Metrics detail
remains available as a development demo, but has no marketing source or export.

```sh
TERMIND_MAC_MARKETING_SCENES=hosts,metrics,command \
  Scripts/run-mac-marketing-screenshots.sh
TERMIND_MAC_MARKETING_SCENES=agent TERMIND_MAC_MARKETING_LOCALES=zh-Hant \
  Scripts/run-mac-marketing-screenshots.sh
```

The runner:

1. builds the TFM test host from the pinned package resolution;
2. launches one locale at a time with matching Apple language and region;
3. waits for an active/key window marker;
4. captures the system window by window number;
5. removes only the two-pixel transparent capture edge when present;
6. verifies the test's focus acknowledgement and final dimensions before replacing
   the source: `2360x1480`, or `2044x1280` for Command Generator.

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
If a Figma JPG export has no embedded color profile, add the sRGB ICC profile as
JPEG metadata without re-encoding its image data. Verify that decoded RGB pixels
are identical to the original export before copying it into the delivery tree.

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
- Mac traffic lights are colored, Workspace's active pane has the blue outline,
  and the MacBook render contains no Dock or copyrighted wallpaper;
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

The subsequent 2026-09-18 iPad refresh updated the same three scenes and locales:
Metrics uses native top tabs; Assistant and Vault use the expanded native sidebar.
Raw captures and final App Store exports are `2752x2064`, with `2960x2290` device
frames. Figwright readback confirmed matching original image bytes and unchanged
copy, fonts, layout, geometry and FIT mode. SHA-256 comparison against the completed
iPhone baseline found exactly 27 changed iPad images and 108 unchanged marketing
files, including iPhone, Mac, SSH/SFTP and the first boards. All 54 App Store JPGs
remain opaque three-channel sRGB.

The 2026-09-19 Port Forwarding navigation refresh generated 16 raw captures:
Mac Vault, Metrics overview and Command Generator in all three languages,
Traditional Chinese Mac Assistant, and iPhone/iPad Vault in all three languages.
The two English/Simplified Chinese Mac Metrics detail sources were removed;
the product detail view and development demo remain available. Existing Workspace
sources and English/Simplified Chinese Mac Assistant sources stayed unchanged.
All 15 retained Mac source images and boards 02–06 were checked for colored
traffic lights. The ten new Mac captures also passed active/key checks before
capture and after acknowledgement. Traditional Chinese Assistant now contains a
Traditional Chinese interface and conversation, with English terminal output.

Only the six mobile Vault MockUPhone frames were regenerated. The Figwright
development plugin was reconnected to the verified `Termind` file
(`udtCX9xVEeoHsTGTwIBgBw`). Mac boards 03, 05 and 06 in all languages, Traditional
Chinese Mac board 04, and mobile board 06 in all languages were replaced and
exported as JPG at 1×. All 16 Figma image fills match their local PNG source bytes;
readback confirmed unchanged text, fonts, geometry, shadows and FIT mode. The
final JPGs have embedded sRGB profiles, opaque RGB pixels and the original
platform dimensions. App Store delivery remains 54 JPGs, six per platform/locale.

The pre-capture backup and SHA-256 manifests are under
`.build/marketing-forwarding-refresh/`. The exact-path audit found 35 modified,
three added, two deleted and 94 unchanged images: the final tree has 45 raw
captures, 33 device frames and 54 App Store exports. English, Simplified Chinese
and Traditional Chinese homepages were checked with the rebuilt Vault frames;
`/zh/` redirects to `/zh-hans/`. The production website build, Chinese localization
check, full Swift format lint and screenshot script syntax checks passed.

Swift verification for this refresh is not fully green. The opt-in capture runs,
`ScreenshotDemoTests` and `AppLanguageTests` passed. The full TFI run completed
307 app tests with seven issues and passed all 316 shared-framework tests. The
full TFM run reported UI/runtime issues and was interrupted after its upload
cancellation test remained blocked in the fixture's socket read. Serial reruns
(`-parallel-testing-enabled NO`) passed the previously failing cancellation,
input, mobile editor, mobile forwarding and saved-name checks; the isolated
`MCPUploadTests` (23 tests) and `MobileUploadBatchTests` (nine tests) also passed.
The following failures persisted in unchanged tests:

- `PortForwardingRenderingTests.saveClosesTheEditorOnlyAfterPersistenceSucceeds`:
  the native Save accessibility element is missing in both parameter cases.
- `PortForwardingRenderingTests.closingJourneyRetainsItsExitViewButDisablesAuthentication`:
  a secure text field remains when Reduce Motion is off.
- `MetricsDetailToolbarTests.legacyCompactSearchOpensTheNativeFieldAndKeepsItsQueryWhenWidened`:
  the native search field is missing.
- `SpeechWaveformViewTests.waveformRespondsToLevelsAndReduceMotionMakesItStable`:
  the Reduce Motion bitmap equality check fails on Mac, including an isolated rerun.
- `MobileProviderDefaultsTests.modelNamesAreMaterializedAfterMergingTheProviderDraft`:
  the expected validation error is not thrown.

Logs and `.xcresult` bundles remain in `.build/marketing-forwarding-refresh/`.
No production behavior or unrelated tests were changed to address these failures.

The later 2026-09-19 navigation topbar refresh replaced Mac Metrics overview and
Vault in all three languages (`2360x1480`) and iPad SSH/SFTP in all three languages
(`2752x2064`, iPadOS 27.0, iPad Pro 13-inch M5 landscape, 9:41). All six Mac sources
passed active/key checks before capture and after acknowledgement; visual and
pixel checks confirmed colored traffic lights and the current `plus` icons.
The iPad captures use the actual root/workspace views, with Workspaces selected,
the sidebar collapsed and the native topbar and bottom controls fully visible.

Only the six matching iPad device frames (`2960x2290`) were regenerated. In the
verified `Termind` Figma file, the refresh replaced Mac boards 03/05, iPad boards
02/03 and the iPad SFTP image in every platform's board 01, across all locales.
English was reviewed first. Readback confirmed all 21 image fills match their
local source PNG bytes, and every other reported node property stayed unchanged,
including copy, fonts, geometry, FIT, shadows and stacking. The 21 JPG exports use
`save_screenshots` at 1×, retain the original dimensions and have opaque RGB pixels
with embedded sRGB profiles. Profile metadata was added without re-encoding or
changing decoded pixels.

The complete pre-capture image backup, SHA-256 manifests, focus evidence, Figma
readbacks, contact sheets and validation logs are in
`.build/marketing-topbar-refresh/`. Exact-path auditing found 39 changed and 93
unchanged images, with no additions or removals: 45 captures, 33 device frames and
54 App Store JPGs. A profile audit also found 23 untouched baseline JPGs without an
embedded ICC profile; this corrects the earlier blanket statement about all 54
files being tagged. Those 23 originals remain byte-identical to the backup.

The website rebuilt successfully (17 pages, no errors or warnings), using the
existing image references. The English, Simplified Chinese and Traditional Chinese
homepages were checked visually, including their hero and SFTP images; `/zh/`
redirects to `/zh-hans/`. Full Swift formatting, Chinese localization, screenshot
shell syntax, generator Python syntax and whitespace checks passed. The Xcode
project and resolved package versions remain unchanged. Python bytecode caches
are now ignored by Git.

All nine opt-in capture runs passed (six Mac runs and three iPad locale runs,
producing 12 sources). The complete TFM run finished with 1,719 passed tests,
one failed test and 23 skipped tests. Its only failure is the previously recorded
`MetricsDetailToolbarTests.legacyCompactSearchOpensTheNativeFieldAndKeepsItsQueryWhenWidened`
in all three language cases. `ScreenshotDemoTests`, `AppLanguageTests` and all
352 shared-framework tests passed.

The TFI run completed 328 app tests and all 352 shared-framework tests: 679 passed
tests and one failed test. The unchanged
`MobileAssistantInteractionRenderingTests.interactionTextRemainsVisibleOnMaterial`
reported 12 OCR mismatches on iPadOS 27.0, including `Deployment` read as
`Deplovment` and `prod.example` read as `oroo.examole`. The existing capture build
excluded `MobileNavigationParityTests`; a normal pinned build and separate run of
all four tests passed, and the obsolete exclusion was removed from the runner.
After both main suites had finished, Xcode stalled collecting simulator diagnostics;
only its `simctl diagnose` child was stopped so the complete `.xcresult` could
finalize. No tests were interrupted. Both full-run result bundles and the
navigation supplement are retained in the evidence directory. Product code and
unrelated test assertions were not changed to address the failures.

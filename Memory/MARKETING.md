# Marketing assets and workflow

Scope: website screenshots, device renders, Figma App Store boards and exports. Never change product behavior to
make a screenshot easier; fixture-only tests may mount real views with in-memory data and no real host/account/network.

## Invariants and asset map

- Raw sources are immutable during framing/composition/export; back up raw files and a SHA-256 manifest before recapture.
  Feature-first paths, never reorganize by device:
  `Marketing/Screenshots/Captures/<feature>/<device>-<locale>.png` and
  `Marketing/Screenshots/DeviceFrames/<feature>/<device>-<locale>-framed.png`.
- Filenames use `en`, `zh-hans`, `zh-hant`; features include workspace/ssh/sftp/metrics/assistant/vault/command-generator.
  Missing platform captures are not permission to fabricate UI. Terminal commands/output stay English; localize chrome/copy.
- Mobile status bar/navigation/toolbars/home indicator must be real captured system UI. Mac capture must be active/key
  (colored traffic lights; focused Workspace pane blue). Do not run competing app activations while capturing.
- Device artwork comes from MockUPhone, not CSS/Figma-drawn hardware/chrome. Keep every device pixel visible; shadows may clip.
  Traditional Chinese uses Taiwan terminology (`伺服器`), PingFang TC; Simplified uses PingFang SC, English SF Pro.
- Website imports the DeviceFrames allowlist through `LandingPage/src/lib/marketingImages.ts` and `ScreenshotPicture.astro`;
  Astro optimizes assets. Do not copy sources into `LandingPage/public`.

## Captures

### Mobile

`TFITests/MobileMarketingScreenshotTests.swift` mounts real feature views in system windows. Ready/ack markers coordinate
complete simulator display capture; unique `TERMIND_MARKETING_CAPTURE_ID` rejects stale markers. Output stages in DerivedData
and enters the source tree only after tests/count checks pass.

```sh
Scripts/run-mobile-marketing-screenshots.sh
# Target one feature/device across all locales:
TERMIND_MARKETING_SCENES=assistant TERMIND_MARKETING_DEVICES=ipad \
  Scripts/run-mobile-marketing-screenshots.sh
```

| Device | Orientation / raw size | Scenes per locale |
| --- | --- | --- |
| iPhone 17 Pro Max | Portrait, 1320×2868 | vault, sftp, ssh, metrics, assistant |
| iPad Pro 13-inch (M5) | Landscape, 2752×2064 | same |

Three locales yield 30 captures. Screenshots require iOS/iPadOS 27 and default to the 27.0 runtime;
`TERMIND_MARKETING_RUNTIME` may select another 27.x runtime, but never a different major version or a silently newer
same-name device. iPad-only runs do not require an iPhone. Each locale is a separate process
with matching Apple language/region/locale and fixture language. Status is deterministic 9:41/charged/Wi-Fi/cellular;
iPhone uses scene-requested portrait plus simctl capture; iPad uses devicectl landscape capture/dimension validation, no rotation.

Fixtures follow production Vault/Metrics/Workspaces/Assistant/Settings order. iPad Metrics shows top tabs, Vault/Assistant
expanded sidebar; SSH/SFTP use `MobileRootView`/production Workspace pages with in-memory connection services, Workspaces
selected/sidebar collapsed. Do not use legacy iPhone wrappers for iPad. The approved screenshot baseline uses
iOS/iPadOS 27.0:

```sh
TERMIND_MARKETING_SCENES=ssh,sftp TERMIND_MARKETING_DEVICES=ipad \
TERMIND_MARKETING_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
  Scripts/run-mobile-marketing-screenshots.sh
```

Recapture affected scenes in **every locale**, regenerate matching frames/boards only. Vault/Metrics/Assistant map to mobile
boards 04–06; SSH/SFTP to 02–03. First boards additionally depend on iPhone Assistant and iPad SFTP, so those source changes affect
all nine first boards.

### Mac

`TFMTests/MacMarketingScreenshotTests.swift` captures the production WindowGroup with `ScreenshotDemoConfiguration`, never
a second RootView/terminal/transcript. It verifies app active + key window before/after capture, 300 ms focused rendering
and native 2× scale. The runner requires macOS 27.x and backs up replaced raws under
`.build/screenshot-backups/<timestamp>/`.

```sh
Scripts/run-mac-marketing-screenshots.sh # Workspace, all locales
TERMIND_MAC_MARKETING_SCENES=hosts,metrics,command Scripts/run-mac-marketing-screenshots.sh
TERMIND_MAC_MARKETING_SCENES=agent TERMIND_MAC_MARKETING_LOCALES=zh-Hant \
  Scripts/run-mac-marketing-screenshots.sh
```

Scene mapping: hosts → vault/mac, workspace → workspace/mac, agent → assistant/mac, command → command-generator/mac,
metrics → metrics/mac-overview. Metrics detail is a development demo, not a marketing export. Locale selectors are
`en`, `zh-Hans`, `zh-Hant`. Pinned build → serial locale launches → stdout key-window marker → system capture by window
number → remove only optional two-pixel transparent edge → completion/dimensions. Raw size 2360×1480, command 2044×1280.
SFTP chrome/file metadata localize; terminal transcripts do not.

## Device frames and website

Run `Scripts/generate-mockuphone-assets.py` with Python/Pillow (the workspace runtime is
`/Users/kaede/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3`). Templates: iPhone 15 Pro Max
Black Titanium portrait, iPad Pro 13-inch Space Gray landscape, MacBook Pro 16-inch front; credited through MockUPhone
to Apple Design Resources. Outputs: 15 iPhone +15 iPad +3 Mac Workspace frames.

Mac windows sit on deterministic Termind-owned blue/cyan artwork, approximately 91% screen width/88% height. No Apple
wallpaper, third-party photography, Dock/user data, duplicated titlebar/traffic lights. Framed sizes: iPhone 1530×3036,
iPad 2960×2290, MacBook 4340×2860. Keep dimensions in website metadata, intrinsic aspect ratio and `object-fit: contain`.

Formal routes: `/`, `/zh-hans/`, `/zh-hant/`; `/zh/` and children redirect to Simplified Chinese. Automatic language
selection only on root English, respecting manual `termind.locale`. Taiwan label `正體中文`; HK/Macau/generic Hant `繁體中文`.
App Store CTA uses the Apple silhouette, never an emoji/text/CSS substitute.

Messaging: capable permission-aware remote workspace, not device count. Preserve “Your terminal, with judgment.” /
“你的终端，自有判断。” Focus SFTP on file workflow, Metrics on diagnosing/continuing over SSH, Assistant on controlled action,
Vault on private iCloud plus separate Keychain protection. Mac-only MCP remains prominent with tool controls, loopback default
and audits. Keep sync exclusions in FAQ/Privacy, not feature pitches; exact localized copy belongs in website sources.

## Figma authoring and exports

Use Figwright MCP with its plugin running in the connected **Termind** file (not rate-limited hosted Figma MCP). Before writes:
`ping` → `list_files` → claim Termind if multiple files → inspect existing variables/components/styles/fonts/pages.
Stop on wrong/unclaimed file. Reuse the design system; English first, screenshot-review, then both Chinese locales.

Pages: Foundations, Components, App Store Mac, App Store iPhone, App Store iPad, Promo. Reference IDs (revalidate before use):
Foundations `25:54`, Components `25:96`; Mac locale sections `25:106`, `25:308`, `25:374`;
iPhone `25:173`, `25:440`, `25:511`; iPad `25:236`, `25:582`, `25:653`.
Platform labels remain MAC/IPHONE/IPAD.

**54 boards = 3 locales × 3 platforms × 6.** Sizes: Mac 2880×1800, iPhone 6.5-inch 1284×2778 (not raw capture size),
iPad 13-inch 2752×2064.

| Board | iPhone / iPad | Mac |
| --- | --- | --- |
| 01 | Mac Workspace + iPhone Assistant + iPad SFTP | same |
| 02 | SSH | Workspace |
| 03 | SFTP | Metrics |
| 04 | Metrics | Assistant |
| 05 | Assistant | Vault |
| 06 | Vault | Command Generator |

All mobile boards use MockUPhone; Mac only board 01 does. Mac 02–06 use native windows with one consistent soft shadow,
no extra frame. All three devices on first boards remain fully visible.

Export high-quality opaque sRGB JPG at 1× with Figwright `save_screenshots` (`format: "JPG"`, `scale: 1`).
`get_screenshot` is size-capped review only. Keep helper/temporary exports outside delivery:

```text
Marketing/AppStore/<locale>/mac/01-06-*.jpg
Marketing/AppStore/<locale>/iphone-6.5/01-06-*.jpg
Marketing/AppStore/<locale>/ipad-13/01-06-*.jpg
```

If an export lacks ICC metadata, add sRGB **without recompressing** and verify decoded RGB equality before delivery.
Check Figma image bytes against sources and unchanged copy/fonts/geometry/FIT/shadows on targeted replacement.
Review every board at 100% plus platform/locale contact sheets.

```sh
test "$(find Marketing/AppStore -type f -name '*.jpg' | wc -l | tr -d ' ')" = 54
test -z "$(find Marketing/AppStore -type f ! -name '*.jpg' -print -quit)"
for platform in mac iphone-6.5 ipad-13; do
  find Marketing/AppStore -path "*/$platform/*.jpg" -print0 \
    | xargs -0 identify -format '%wx%h %[colorspace] %[channels] opaque=%[opaque]\n' \
    | sort | uniq -c
done
```

Expect 18 opaque sRGB RGB images at each platform size; also inspect embedded ICC profiles, not colorspace alone.
No `.DS_Store`, manifests/previews/temp PNGs in delivery.

## Verification and retained caveats

```sh
(cd LandingPage && npm run build)
Scripts/check-zh-localization.sh
xcrun swift-format lint --strict TFITests/MobileMarketingScreenshotTests.swift TFMTests/MacMarketingScreenshotTests.swift
zsh -n Scripts/run-mobile-marketing-screenshots.sh Scripts/run-mac-marketing-screenshots.sh
python3 -m py_compile Scripts/generate-mockuphone-assets.py
git diff --check
```

Visually check formal/compatibility routes, Apple CTA, unclipped real device chrome, current production SFTP/navigation,
Mac key-window appearance, owned background, Chinese fonts/terminology and 54 final exports. Capture success is not a
full regression-suite pass; never adjust production behavior/unrelated assertions to satisfy marketing fixtures.

The macOS 27 refresh on 2026-09-22 recaptured all 15 Mac sources, regenerated the three Mac Workspace frames, replaced
24 Figma image nodes, and exported 24 affected App Store JPGs: all 18 Mac boards plus all six iPhone/iPad first boards.
The Vault sources and boards no longer show “Host key changed.” All 54 exports retained their required dimensions; the
24 changed files are opaque RGB JPEGs with embedded sRGB profiles. The capture runner, strict formatting, localization,
script syntax, Astro build, Figma render review, and three-locale contact-sheet review passed.

Historical evidence is in local `.build/marketing-forwarding-refresh/` and `.build/marketing-topbar-refresh/` when retained,
not guaranteed repository artifacts. The latest recorded topbar refresh (2026-09-19) left 45 raws, 33 frames and 54 JPGs;
39 changed/93 unchanged. **23 untouched baseline JPGs lacked embedded ICC profiles** despite earlier blanket claims.
Do not declare every export tagged without a new profile audit.

That refresh passed capture/build/localization/format checks, but full suites were not green:
- TFM: 1,719 passed, one failed, 23 skipped; `MetricsDetailToolbarTests.legacyCompactSearchOpensTheNativeFieldAndKeepsItsQueryWhenWidened`
  failed in all three language cases.
- TFI: 679 passed, one failed; `MobileAssistantInteractionRenderingTests.interactionTextRemainsVisibleOnMaterial` had iPadOS 27.0
  OCR mismatches. All 352 framework tests passed on both platforms; four separately run `MobileNavigationParityTests` passed,
  and their obsolete capture exclusion was removed.
- Xcode diagnostic collection stalled after suites completed; stopping only its `simctl diagnose` child allowed xcresults to
  finalize without interrupting tests. Historical counts/failures are not current verification; rerun affected checks.

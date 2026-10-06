# Asset production workflow

Run these commands from the Termind application repository. The public website,
marketing images, and design artwork live in the `com.akinokaede.termind` submodule;
Xcode, Swift screenshot fixtures, Ruby dependencies, and fastlane stay here.

```sh
git submodule update --init com.akinokaede.termind
```

Native application builds do not need this submodule. Default capture and framing
operations fail before writing if it is absent; explicit external review paths
remain supported. Preview a capture matrix with `plan:true` without opening windows.

After review, commit and push changes in the asset repository first, then commit
the updated gitlink here. Use SSH for pushes and retain the HTTPS `.gitmodules` URL.
The website deploys directly from the asset repository's `main` branch.

## Capture and framing reference

Marketing files are organized by destination and production stage:

- `com.akinokaede.termind/assets/app_store/` contains final App Store artwork grouped by locale and device.
- `com.akinokaede.termind/assets/captures/` contains immutable, full-resolution app captures.
- `com.akinokaede.termind/assets/device_frames/` contains reproducible PNG mockups generated from
  captures by `bundle exec fastlane frames` (`frameit`).

The Astro site imports the small allowlist in
`com.akinokaede.termind/src/lib/marketingImages.ts` directly from `device_frames`. During a
production build, Astro resizes each imported source and emits AVIF, WebP, and JPEG
assets. Do not copy source screenshots or device frames into `com.akinokaede.termind/public`.

Release captures use **fastlane `run_tests` (scan)**. The lanes build once, run
isolated Swift Testing fixtures serially for each locale/device, and capture the
native compositor output. This keeps Liquid Glass, focused Mac window chrome,
and the system software keyboard in the images. `snapshot`'s XCUITest helper is
not used: these fixtures are hosted Swift Testing suites, not UI automation tests.

Install Ruby 3.3 or newer (below 4.0) and the locked gems first. On macOS with
Homebrew, one setup is:

```sh
brew install ruby@3.3
export PATH="$(brew --prefix ruby@3.3)/bin:$PATH"
bundle config set --local path .build/bundle
bundle install
```

The Mac capture lane opens and focuses the real Termind window and moves the
pointer outside its content while capturing. Run it when desktop focus is
available. `plan:true` and the `frames` lane do not open app windows.

Capture from the repository root:

```sh
bundle exec fastlane mac screenshots scenes:hosts,workspace,agent,command,metrics
bundle exec fastlane ios screenshots
```

Only Workspace (used by Overview) uses a full-screen capture on the built-in
display at its native 3024 × 1964 size. All other Mac scenes, including Command
Generator, use the standard 2360 × 1480 window capture. The full-screen window is
captured in isolation; any excluded camera strip is padded black without
capturing personal system UI. Overview uses the narrow MacBook Pro template
documented in the local frame templates section below; retain its local source for
regeneration.
Mac defaults to Workspace in all three languages. Mobile defaults to all five
scenes on iPhone and iPad in all three languages. Filter a refresh or inspect its
matrix without building or opening windows:

```sh
bundle exec fastlane mac screenshots scenes:agent locales:zh-Hant
bundle exec fastlane ios screenshots scenes:ssh,sftp devices:ipad locales:zh-Hans,zh-Hant
bundle exec fastlane ios screenshots devices:ipad runtime:com.apple.CoreSimulator.SimRuntime.iOS-27-0
bundle exec fastlane ios screenshots plan:true
```

`output:/absolute/path` stages a review capture outside the source asset tree.
The default remains `com.akinokaede.termind/assets/captures/<locale>/<device>/<feature>.png`.
Logs and build products live under `.build/fastlane-screenshots/<platform>/`;
each run has its own logs. Existing captures are backed up with `SHA256SUMS` under
`.build/screenshot-backups/<run>/` before replacement. A failed test, missing
scene, duplicate request, or incorrect image size prevents the affected capture
batch from replacing its sources. Runs are serialized across both platforms.

`Scripts/run-mac-screenshots.sh` and
`Scripts/run-mobile-screenshots.sh` commands delegate to these lanes.
The `TERMIND_MAC_SCREENSHOT_SCENES`, `TERMIND_MAC_SCREENSHOT_LOCALES`, and
`TERMIND_SCREENSHOT_{SCENES,DEVICES,LOCALES,RUNTIME}` variables provide defaults; explicit
lane options take precedence. Invalid and duplicate selectors fail before build.
These lanes generate source captures; device frames and final Figma artwork keep
the downstream workflow described below.

`hosts` produces Vault, `metrics` produces only the Metrics overview, `command`
produces Command Generator, and `agent` produces Assistant. Metrics detail is a
development demo only; do not retain its captures as marketing assets.

The mobile lane requires iOS/iPadOS 27. iPhone 18 Pro Max and iPad Pro use
**iOS/iPadOS 27.0**; Duo uses **iOS 27.1**. The lane selects 27.1 for Duo-only
batches and 27.0 otherwise. The installed 27.1 runtime supports only Duo, so
capture it separately from iPhone and iPad.
It checks both the simulator model identifier and the raw pixel dimensions:

| Selector | Capture device | Native capture size |
| --- | --- | --- |
| `iphone` | iPhone 18 Pro Max (6.9-inch), portrait | 1320×2868 |
| `iphone-duo-outer` | iPhone Duo, closed, portrait | 1398×2034 |
| `iphone-duo-inner` | iPhone Duo, open, landscape | 2853×2007 |
| `ipad` | iPad Pro 13-inch (M5), landscape | 2752×2064 |

Create the exact simulators once if they are missing:

```sh
xcrun simctl create "iPhone 18 Pro Max" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-27-0
xcrun simctl create "iPhone Duo" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo com.apple.CoreSimulator.SimRuntime.iOS-27-1
xcrun simctl create "iPad Pro 13-inch (M5)" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

The lane does not resize iPhone captures or substitute another device. Existing
`com.akinokaede.termind/assets/app_store/*/iphone-6.9` artwork uses a separate 1320×2868 composition canvas;
that folder describes the final artwork, not the screenshot device. Recapturing
does not regenerate those downstream assets automatically.

Duo captures are opt-in and use one simulator with two displays. In Device Hub,
select **Closed** before the outer batch and **Open** before the inner batch.
Run each separately; the runner rejects an inactive display before starting the
capture tests and passes the display selector through the capture handshake.

```sh
bundle exec fastlane ios screenshots devices:iphone-duo-outer
bundle exec fastlane ios screenshots devices:iphone-duo-inner
bundle exec fastlane frames devices:iphone-duo-outer,iphone-duo-inner
```

Each Duo batch includes all five scenes in all three languages. Sources and
frames use separate `iphone-duo-outer` and `iphone-duo-inner` directories.
The default iPhone/iPad capture matrix and website frame matrix are unchanged.
Apple accepts these native sizes in the
[Duo screenshot specification](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
An App Store composition must use an accepted canvas size and be opaque RGB;
the transparent device-frame PNG is an intermediate design asset, not the upload.
The Figma `App Store iPhone Duo` page contains one six-image set per language,
all on 2853×2007 landscape canvases. SSH, SFTP, and Assistant show the inner display;
Metrics and Vault show the outer display. Overview combines Mac Workspace, Duo inner
SFTP, and Duo outer Vault, without an iPad. Export these to
`assets/app_store/<locale>/iphone-duo/` as opaque sRGB JPGs.

SSH and SFTP captures on every device mount the real workspace shell
with in-memory connection services. The workspace capture supplies an active scene
phase, and SSH requires terminal focus plus the visible system software keyboard
and native keyboard accessory before export. SSH captures use English QWERTY
while localizing the app independently. Disconnect the simulator's hardware
keyboard when capturing SSH. Dismiss first-use keyboard tips and return to the
Home Screen before starting a batch to avoid prompts or app-return links in captures.
Selecting only `ipad` also builds on the iPad, so
an iPhone simulator is not required. Capture markers are scoped to each run, and
new sources replace their destinations only after the locale's capture tests and
expected image count pass. Mobile captures use a deterministic 9:41 status bar
with 100% battery in the discharging state. Mac captures require an active key
window throughout rendering and capture, with colored traffic lights, and the
Mac runner requires macOS 27. The capture launch arguments force
`statusBar.expanded` to `YES` in the process argument domain, so captures do not
inherit a collapsed bar or change the user's saved preference.

Mac Vault shows two demo workspaces with matching connected host indicators;
other hosts are disconnected and no SFTP transfers are seeded. Workspace selects
only `nginx.conf` in SFTP. Before capture, the Mac test delivers a pointer move
inside the window to clear any stale SwiftUI row hover, then moves the pointer
out of the content and temporarily disables mouse events. Moving directly
outside can leave a hovered row highlighted in the captured image.

In Figma, keep Mac artwork 02–06 as native windows in all three languages.
Mac and iPad artwork 01 retain the three-device composition. iPhone artwork 01
uses two devices with aligned bottom edges: iPhone Assistant fully visible in
the right foreground (width 820), with Mac Workspace enlarged behind it (width
1800). The Mac layer deliberately extends left of the clipping Product imagery
frame; only part of the laptop is shown. No iPad appears in this composition.
Keep the existing export filenames. Replace screenshot layers while
preserving their geometry, text, shared shadows, and stacking order, then export
the affected boards as opaque RGB JPGs with an sRGB ICC profile. Refresh the mobile
layers wherever they appear in the existing Overview sets when their sources change.

Both lanes keep builds pinned with `-onlyUsePackageVersionsFromResolvedFile`.
Run the orchestration regression checks with `bundle exec ruby Scripts/Tests/test_screenshots.rb`.

Regenerate device frames after replacing captures:

```sh
bundle exec fastlane frames
bundle exec fastlane frames devices:iphone scenes:vault locales:en
bundle exec fastlane frames devices:ipad scenes:ssh,sftp locales:zh-Hans,zh-Hant
```

Install ImageMagick (`brew install imagemagick`) for frameit. Frame assets are
locked by `fastlane/Framefile.json`; frameit downloads that version on first use.
`input:` and `output:` allow a separate review directory, and `plan:true` lists
selected jobs without changing files. Defaults include only website-used scenes:
iPhone Assistant/SSH/Vault, iPad Metrics/SFTP/Vault, and Mac Workspace, in all three
locales. Use `scenes:` explicitly when another composition is needed.
The lane stages source copies and publishes
`<locale>/<device>/<feature>.png` only after every selected output succeeds. Old Pro captures
must be recaptured on iPhone 18 Pro Max before framing; they are rejected by size.

- iPhone uses Apple's official iPhone 18 Pro Max Silver portrait frame at native
  screenshot size. Import it locally or pass `iphone_frame:/path/to/portrait.png`.
- iPad uses Apple's official iPad Pro (M5) 13-inch Space Black PNG as a custom
  frameit device. Its opening matches the native capture exactly, with no resize.
  Import the PNG once as described in the local frame templates section below, or pass
  `ipad_frame:/path/to/portrait.png`. The licensed source artwork stays local.
- Mac Workspace fills the MacBook frame with the full-screen app capture.
  Capture aspect ratio is preserved while trimming the top of the black camera
  strip to match the aperture. No wallpaper or Dock is composited. Other Mac scenes stay as native
  window captures for final artwork.

Frame dimensions now come from frameit. Astro imports image metadata directly,
so no hard-coded website image sizes need updating. Built-in frame assets are distributed
by [fastlane frameit-frames](https://github.com/fastlane/frameit-frames), based on
the upstream device artwork; follow its usage terms.


## Local frame templates

### Official iPhone 18 Pro Max frame

Download the [iPhone 18 bezels](https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-18.dmg)
from Apple Design Resources. Copy `PNG/iPhone 18 Pro Max/iPhone 18 Pro Max - Silver - Portrait.png`
to `.build/frameit-assets/iphone-18-pro-max.png`, or pass `iphone_frame:/path/to/frame.png`.
The template is 1470×3000 with a native 1320×2868 opening at (75, 66).
The lane registers the template as a custom frameit device. Keep the licensed source local.

### Official iPhone Duo frames

Download the [iPhone Duo bezels](https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-Duo.dmg)
from [Apple Design Resources](https://developer.apple.com/design/resources/#product-bezels).
Keep the licensed originals local. Copy the two Star White portrait PNGs:

- `PNG/iPhone Duo - Star White - Outer Closed Portrait.png` → `.build/frameit-assets/iphone-duo-outer.png`
- `PNG/iPhone Duo - Star White - Inner Open Portrait.png` → `.build/frameit-assets/iphone-duo-inner.png`

Alternate paths use `iphone_duo_outer_frame:` and `iphone_duo_inner_frame:` lane
options. The outer template is 1574×2194 with a 1398×2034 opening at (88, 80).
The inner template is 2247×3093 with a 2007×2853 opening at (120, 120).
The inner frame rotates clockwise (`landscape_right`) for landscape output
(3093×2247), placing the volume buttons along the top edge near the right corner.
The screen mask rotates with it; screenshot content stays upright. Both preserve the
native screenshot scale. The lane registers them as custom
frameit devices and checks source and template sizes before publishing outputs.

### Official iPad Pro frame

The `frames` lane uses Apple's **iPad Pro (M5) 13-inch, Space Black, Portrait**
PNG, available from [Apple Design Resources](https://developer.apple.com/design/resources/#product-bezels)
in the [iPad Pro (M5) download](https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-Pro-(M5).dmg).

Download and open the disk image, review its Apple Design Resources license,
and copy `PNG/iPad Pro (M5) 13" - Space Black - Portrait.png` to:

```text
.build/frameit-assets/ipad-pro-13-m5.png
```

Alternatively pass `ipad_frame:/absolute/path/to/portrait.png` to
`bundle exec fastlane frames`. Keep the licensed source artwork local; do not
commit or redistribute it as a standalone asset. The lane exports composed
Termind mockups using frameit, under Apple's design-resource usage terms.

The unmodified template is 2300×3000. Its transparent screen opening is exactly
2064×2752 at (118, 124), matching the M5 simulator at native scale. frameit rotates
it for landscape captures and produces a 3000×2300 composition. Neither the
screenshot nor the frame is resized. The pinned frameit library has no built-in
M5 frame, so the lane registers this device at runtime.

### MacBook Pro narrow frame

Mac Overview compositions use Apple's MacBook Pro M5 16-inch Space Black PNG,
prepared locally as `.build/frameit-assets/macbook_pro_template.png`. Supply an
alternate location with `mac_frame:/absolute/path/to/frame.png`. Keep the source
artwork outside version control and retain its original usage terms.

Download the MacBook Pro M5 bezel from Apple's Design Resources and accept its
license locally. Remove only the 220-pixel transparent top margin from the
official 4260×2840 PNG:

```sh
magick "/Volumes/Bezel-MacBook-Pro-M5/PNG/MacBook Pro M5 16-inch Space Black.png" \
  -crop 4260x2620+0+220 +repage .build/frameit-assets/macbook_pro_template.png
```

The prepared transparent template is 4260×2620, with a 3456×2234 screen opening
at (402, 83). The native 3024×1964 capture scales proportionally to 3456×2245;
11 pixels are trimmed from its black full-screen camera strip to fill the opening.
No desktop or personal system UI is added. Do not reuse a template extracted from
a composed screenshot: it can retain wallpaper or mismatched rounded corners.
A missing template fails before publishing outputs.

### Screen aperture masks

Before composition, the framing lane masks staged captures to the enclosed
transparent screen opening in each official template, including iPad and Mac.
The opaque bezel separates this opening from the transparent exterior; an open
bezel fails validation. Landscape masks rotate with the frame. This prevents
rectangular capture corners from appearing outside thin bezels and preserves
opaque screen content. Raw captures remain unchanged. Regenerate device frames
and refresh their Figma image layers and marketing exports after a mask change.

## Brand and icon exports

The master mark is `com.akinokaede.termind/design/brand/termind.svg`.
Application Icon Composer documents remain at `TFM/Resources/AppIcon.icon` and
`TFI/Resources/AppIcon.icon`. Do not make app resources depend on the submodule.
Export the website icon from the Mac document:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  "$PWD/TFM/Resources/AppIcon.icon" --export-image \
  --output-file "$PWD/com.akinokaede.termind/public/app_icon.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

Regenerate the Pro artwork with `swift Scripts/render-pro-paywall-icon.swift`;
outputs go to `com.akinokaede.termind/design/paywall/`.
Check artwork in English, Simplified Chinese, and Traditional Chinese before
publishing. Keep credentials, management-console links, internal release records,
and local licensed source downloads out of the public asset repository.

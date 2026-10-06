# Official iPad Pro frame

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

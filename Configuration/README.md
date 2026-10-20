# Local service configuration

The repository does not contain Firebase project configuration or RevenueCat SDK
keys. Both app targets use `Services.xcconfig` for Debug and Release builds.
Without local overrides, Firebase stays unconfigured, Crashlytics symbol upload
is disabled, and RevenueCat purchases are unavailable. This does not bypass Pro
feature access checks.

## Configure your own services

1. Copy `Configuration/Services.local.xcconfig.example` to
   `Configuration/Services.local.xcconfig`.
2. Set `REVENUECAT_API_KEY` to your RevenueCat public Apple SDK key and set
   `REVENUECAT_ENTITLEMENT_ID` to the entitlement configured in your project.
   Never put a private RevenueCat management key in an app build.
3. Download your own Firebase Apple app's `GoogleService-Info.plist` to
   `Configuration/Firebase/GoogleService-Info.plist`. Its bundle ID must match the
   app being built. Uncomment `FIREBASE_CONFIG_PATH` in the local xcconfig.
4. To upload Crashlytics symbols from Release builds, also uncomment
   `FIREBASE_UPLOAD_SYMBOLS = YES`. Runtime diagnostics still require user consent.

The local xcconfig and Firebase plist are ignored by Git. Keep the tracked
Firebase example unconfigured: its intentionally mismatched bundle ID prevents
SDK initialization. CI can provision the same ignored files from its secret
store, or pass build-setting overrides to `xcodebuild`. Never publish those files
or build logs containing their values.

Firebase client configuration and RevenueCat public SDK keys are shipped in app
binaries; they are not server-side secrets. Keeping them out of this repository
prevents forks from accidentally using the production services, but does not
replace Firebase API restrictions, security rules, or private credential
rotation.

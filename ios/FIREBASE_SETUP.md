# iOS Firebase / Push Notification setup (required before first iOS build)

The app uses **firebase_core** + **firebase_messaging** (FCM push). Android is
already configured (`android/app/google-services.json`). iOS needs the equivalent
file, which is **not** in the repo and must be downloaded from Firebase.

## 1. Add an iOS app to the existing Firebase project
- Firebase console → project **`phoneopia-14cc8`** → *Add app* → **iOS**.
- iOS bundle ID: **`com.phoneopia.phoneopiaMobile`** (must match exactly).
- Download **`GoogleService-Info.plist`**.

## 2. Place the file
Put it at:
```
ios/Runner/GoogleService-Info.plist
```
Then, in Xcode, drag it into the **Runner** target (check "Copy items if needed"
and the *Runner* target checkbox) so it is bundled into the app.

## 3. APNs key (so FCM can deliver push on iOS)
- Apple Developer → Certificates, Identifiers & Profiles → **Keys** → create an
  **APNs Auth Key (.p8)**.
- Firebase console → Project settings → **Cloud Messaging** → *Apple app config*
  → upload the .p8 (with Key ID + Team ID).

## 4. Xcode capabilities (Signing & Capabilities tab)
- **Push Notifications** — enables APNs; auto-links `Runner.entitlements`.
- **Background Modes** — tick *Remote notifications*, *Audio*, *Background fetch*
  (these mirror the keys already in `Info.plist`).

> Without `GoogleService-Info.plist` the app will crash on launch at
> `Firebase.initializeApp()`. Everything else is already wired in code.

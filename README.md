# VineViewer

Vineyard layout drawing and per-vine data tracking.

Draw a vineyard's rows and blocks over an aerial image, then attach a
user-defined data schema to every individual vine with full change history.

See [VINEYARD_APP_PLAN.md](VINEYARD_APP_PLAN.md) for architecture, decisions,
and phasing. That document is the source of truth.

**Status:** Phase 0 — foundation & update pipeline.

## Platforms

| Platform | Priority | Notes |
|---|---|---|
| Android (Fire OS) | P0 | Amazon Fire Max 11, sideloaded APK. No Play Services. |
| Windows desktop | P0 | Development + large-screen drawing |

iOS, macOS, and Linux are deferred. Add them later with
`flutter create --platforms=ios,macos,linux .`

## Development

Requires the Flutter SDK on the stable channel (built against 3.44.8).

```sh
flutter pub get          # fetch dependencies
flutter analyze          # static analysis
flutter test             # unit + widget tests
flutter run -d windows   # run on desktop
```

### Running on the Fire Max 11

The tablet must have developer options and USB debugging enabled, and the
"Allow USB debugging?" prompt must be accepted on-device.

```sh
adb devices              # confirm the tablet is listed as "device"
flutter run -d <device>  # hot-reload build over USB
```

To produce an installable APK:

```sh
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

## Versioning

`version:` in `pubspec.yaml` is the single source of truth. It feeds the
Android `versionName`/`versionCode`, and the app displays it on screen so a
pushed build can be confirmed on-device at a glance.

## A note on secrets

The release signing keystore must never be committed. It is unrecoverable if
lost and unrotatable if leaked — losing it means every user must uninstall and
reinstall. `.gitignore` blocks `*.jks`, `*.keystore`, and `key.properties`.
Keep an offline backup; give CI its own copy via GitHub Secrets.

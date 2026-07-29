# VineViewer

Layout drawing and per-plant data tracking.

Draw over an aerial image, then attach a user-defined data schema to every
individual plant with full change history.

Nothing here is specific to grapes. What a drawn object *is* — a row, a block, a
terrace, a road — is a field the user defines, and so is the way a plant's
identifier is composed from them. It grew out of a vineyard and still carries the
name, but an orchard would work the same way.

See [VINEYARD_APP_PLAN.md](VINEYARD_APP_PLAN.md) for architecture, decisions and
phasing, and [V3_PLAN.md](V3_PLAN.md) for the generic-engine rework that
supersedes parts of it. Read V3_PLAN.md's amendments block first; where the two
disagree, the amendments win.

## Shipping a release

```sh
# 1. bump `version:` in pubspec.yaml (BOTH parts, e.g. 0.1.3+4 -> 0.1.4+5)
# 2. commit and push
git tag -a v0.1.4 -m "What changed."   # annotation becomes the release notes
git push origin v0.1.4
```

The tag fires `.github/workflows/release.yml`, which builds, signs, verifies
the APK is not debug-signed, and publishes it with `version.json`. The tablet
picks it up from **Check for updates**.

The tag must match `version:` in pubspec.yaml or the workflow fails before
building. Bump the build number too — Android compares `versionCode`, not the
version name, and will refuse an install whose code did not increase.

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

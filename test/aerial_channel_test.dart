import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/features/projects/aerial_image.dart';

/// The one string in this app that has to match a piece of Kotlin.
///
/// The image picker is a `MethodChannel` rather than a plugin -- `file_picker`
/// was removed because its Gradle script applies the Kotlin Gradle Plugin, which
/// AGP 9 with built-in Kotlin will not configure. That trade is fine, but it
/// leaves a channel name duplicated across two languages with nothing checking
/// the two copies agree.
///
/// **They already disagreed once, and it shipped.** The vine-to-plant rename
/// swept the Dart side to `plantviewer/files` while `MainActivity.CHANNEL` kept
/// its original value, so 0.6.0 went out with the device picker throwing
/// `MissingPluginException` the moment anyone tapped "Choose from device". The
/// analyzer cannot see it, no existing test touched it, and the failure only
/// appears on a real device.
///
/// So this test reads the Kotlin source as text. Crude, but it is the only thing
/// standing between a one-word edit and a dead button.
void main() {
  test('the Dart channel name matches MainActivity.CHANNEL', () {
    final kotlin = File(
      'android/app/src/main/kotlin/com/mitch8845/vine_viewer/MainActivity.kt',
    );
    expect(
      kotlin.existsSync(),
      isTrue,
      reason: 'MainActivity.kt moved; update this test to follow it',
    );

    final match = RegExp(
      r'const\s+val\s+CHANNEL\s*=\s*"([^"]+)"',
    ).firstMatch(kotlin.readAsStringSync());

    expect(
      match,
      isNotNull,
      reason: 'could not find `const val CHANNEL = "..."` in MainActivity.kt',
    );
    expect(
      match!.group(1),
      aerialChannelName,
      reason:
          'Dart and Kotlin disagree about the channel name, so the image '
          'picker will throw MissingPluginException on the device',
    );
  });

  test('the channel name is tied to the application id, not the app name', () {
    // `vineviewer` here is deliberate and matches `com.mitch8845.vine_viewer`.
    // A future rename of the *app* must not touch it: the application id cannot
    // change without making the next release a new install rather than an
    // update, so this string is anchored to the id and not to the branding.
    expect(aerialChannelName, 'vineviewer/files');
  });

  test('the bundled aerial asset is declared and present', () {
    // The sample aerial is the path that works with no file system to navigate,
    // and it is the fallback when the picker misbehaves -- so it is worth
    // knowing it is actually in the bundle.
    expect(File(sampleAerialAsset).existsSync(), isTrue);
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('assets/aerial/'),
      reason: 'the asset exists on disk but is not bundled into the APK',
    );
  });
}

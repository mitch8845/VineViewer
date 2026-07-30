/// Attaching an aerial photo to a project.
///
/// Images are never stored in the database -- a multi-megabyte blob would be
/// read into memory on every row fetch -- so every path here ends the same way:
/// the bytes land in a real file under the documents directory and the project
/// records where.
library;

import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/providers.dart';

/// The Five Sisters aerial that ships with the app.
const sampleAerialAsset = 'assets/aerial/five_sisters_aerial.jpg';

/// Talks to `MainActivity`'s picker.
///
/// Not a plugin. `file_picker` was removed because its Gradle script applies
/// the Kotlin Gradle Plugin, which AGP 9 with built-in Kotlin will not
/// configure; app-module Kotlin has no such problem, so the picker lives in
/// `MainActivity.kt` instead.
///
/// **This string must match `MainActivity.CHANNEL` exactly**, and it is not
/// checked by the compiler -- a mismatch is a `MissingPluginException` at the
/// moment the user taps, with everything up to that point looking fine. It has
/// already happened once: the vine-to-plant rename swept this to
/// `plantviewer/files` while the Kotlin constant stayed put, and it shipped in
/// 0.6.0 with the device picker dead. `aerial_channel_test.dart` now reads the
/// Kotlin source and fails if the two ever disagree again.
const aerialChannelName = 'vineviewer/files';

const _channel = MethodChannel(aerialChannelName);

/// Records the background image and its pixel dimensions.
///
/// Dimensions are stored rather than read on demand because every coordinate in
/// the project lives in this image's pixel space, and the canvas needs them
/// before the image itself has finished decoding.
Future<void> setProjectImage(
  WidgetRef ref,
  String projectId,
  String path,
) async {
  int? width;
  int? height;
  try {
    final codec = await ui.instantiateImageCodec(
      await File(path).readAsBytes(),
    );
    final frame = await codec.getNextFrame();
    width = frame.image.width;
    height = frame.image.height;
    // Only the dimensions are wanted here; the canvas decodes its own copy.
    frame.image.dispose();
  } catch (_) {
    // An unreadable image is still recorded, so the path stays visible and the
    // user can see what went wrong rather than the action doing nothing.
  }

  await ref
      .read(projectsDaoProvider)
      .setImage(projectId, imagePath: path, width: width, height: height);
}

/// Opens the system picker and attaches the chosen image to a project.
///
/// Returns false if the user backed out, so the caller can stay quiet rather
/// than reporting a cancellation as a failure.
Future<bool> pickAerialImage(WidgetRef ref, String projectId) async {
  final picked = await _channel.invokeMethod<String>('pickImage');
  if (picked == null) return false;

  final temporary = File(picked);
  try {
    await _install(ref, projectId, await temporary.readAsBytes());
  } finally {
    // The Android side copies into the cache directory, which the OS may clear
    // whenever it likes. Once the bytes are in documents this is dead weight.
    if (temporary.existsSync()) {
      try {
        await temporary.delete();
      } catch (_) {
        // A leftover cache file is not worth failing the pick over.
      }
    }
  }
  return true;
}

/// Copies the bundled aerial out to disk and attaches it to a project.
///
/// The asset is copied rather than referenced in place because everything
/// downstream works from a real filesystem path. Bundled assets have none; they
/// live inside the APK behind [rootBundle].
Future<void> installSampleAerial(WidgetRef ref, String projectId) async {
  final bytes = await rootBundle.load(sampleAerialAsset);
  await _install(ref, projectId, bytes.buffer.asUint8List());
}

/// Writes [bytes] to this project's aerial file and records it.
///
/// Named per project so two vineyards can start from the same image and then
/// have it repositioned independently. Overwrites deliberately: choosing an
/// image again is the user asking to replace the one that is there.
Future<void> _install(WidgetRef ref, String projectId, Uint8List bytes) async {
  final directory = await getApplicationDocumentsDirectory();
  final file = File('${directory.path}/aerials/$projectId.img');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);

  await setProjectImage(ref, projectId, file.path);
}

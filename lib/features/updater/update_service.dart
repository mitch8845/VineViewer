import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'version.dart';

/// Release metadata published alongside the APK by .github/workflows/release.yml.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.apkUrl,
    required this.notes,
  });

  final Version version;
  final String apkUrl;
  final String notes;

  static UpdateInfo? fromJson(Map<String, dynamic> json) {
    final version = Version.tryParse('${json['version'] ?? ''}');
    final apkUrl = '${json['apk_url'] ?? ''}';
    if (version == null || apkUrl.isEmpty) return null;
    return UpdateInfo(
      version: version,
      apkUrl: apkUrl,
      notes: '${json['notes'] ?? ''}',
    );
  }
}

/// Outcome of a check. Modelled as distinct states rather than a nullable
/// result so the UI can tell "up to date" apart from "couldn't reach GitHub" --
/// conflating them would let a silent network failure masquerade as success.
sealed class UpdateCheck {
  const UpdateCheck();
}

class UpToDate extends UpdateCheck {
  const UpToDate(this.current);
  final Version current;
}

class UpdateAvailable extends UpdateCheck {
  const UpdateAvailable(this.current, this.info);
  final Version current;
  final UpdateInfo info;
}

class UpdateCheckFailed extends UpdateCheck {
  const UpdateCheckFailed(this.message);
  final String message;
}

class UpdateService {
  UpdateService({Dio? dio, this.repo = 'mitch8845/PlantViewer'})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  final Dio _dio;
  final String repo;

  /// `releases/latest/download/<asset>` always resolves to the newest release,
  /// so the app never needs to know release tags or call the GitHub API. Works
  /// anonymously because the repository is public.
  String get versionJsonUrl =>
      'https://github.com/$repo/releases/latest/download/version.json';

  Future<UpdateCheck> check() async {
    final Version current;
    try {
      final info = await PackageInfo.fromPlatform();
      final parsed = Version.tryParse(info.version);
      if (parsed == null) {
        return UpdateCheckFailed('Cannot read installed version.');
      }
      current = parsed;
    } catch (e) {
      return UpdateCheckFailed('Cannot read installed version.');
    }

    try {
      // Fetch as plain text and decode by hand. GitHub serves release assets
      // as application/octet-stream, and Dio's ResponseType.json only decodes
      // when the content type looks like JSON -- otherwise it hands back a
      // String, which every type check downstream then rejects as malformed.
      final res = await _dio.get<String>(
        versionJsonUrl,
        options: Options(responseType: ResponseType.plain),
      );

      final raw = res.data;
      if (raw == null || raw.isEmpty) {
        return const UpdateCheckFailed('Empty version.json.');
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return const UpdateCheckFailed('Malformed version.json.');
      }

      if (decoded is! Map) {
        return const UpdateCheckFailed('Malformed version.json.');
      }

      final info = UpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
      if (info == null) {
        return const UpdateCheckFailed('Malformed version.json.');
      }

      return info.version.isNewerThan(current)
          ? UpdateAvailable(current, info)
          : UpToDate(current);
    } on DioException catch (e) {
      // 404 before the first release exists is expected, not an error worth
      // alarming the user about.
      if (e.response?.statusCode == 404) {
        return UpToDate(current);
      }
      return UpdateCheckFailed(_describe(e));
    } catch (e) {
      return UpdateCheckFailed('Update check failed: $e');
    }
  }

  /// Downloads to app-private storage. Reports 0.0-1.0, or null when the server
  /// sends no Content-Length.
  Future<File> download(
    UpdateInfo info, {
    void Function(double? progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/PlantViewer-v${info.version}.apk');

    // A partial file from an interrupted download would fail to install with a
    // confusing parse error, so never resume onto an existing one.
    if (await file.exists()) {
      await file.delete();
    }

    await _dio.download(
      info.apkUrl,
      file.path,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (onProgress == null) return;
        onProgress(total > 0 ? received / total : null);
      },
    );

    return file;
  }

  /// Hands the APK to the system installer. Android shows its own confirmation;
  /// the app cannot and should not install silently.
  Future<String?> install(File apk) async {
    final result = await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type == ResultType.done) return null;

    if (result.type == ResultType.permissionDenied) {
      return 'Permission denied. Enable "Install unknown apps" for PlantViewer '
          'in Settings, then try again.';
    }
    return 'Could not start the installer: ${result.message}';
  }

  String _describe(DioException e) {
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout => 'Timed out reaching GitHub.',
      DioExceptionType.connectionError => 'No network connection.',
      DioExceptionType.badResponse =>
        'GitHub returned ${e.response?.statusCode}.',
      _ => 'Update check failed.',
    };
  }
}

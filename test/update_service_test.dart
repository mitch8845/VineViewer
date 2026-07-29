import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:vine_viewer/features/updater/update_service.dart';

/// Returns a canned body with a chosen content type, so we can reproduce how
/// GitHub actually serves release assets.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.body, required this.contentType});

  final String body;
  final String contentType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

UpdateService _serviceReturning(String body, {required String contentType}) {
  final dio = Dio()
    ..httpClientAdapter = _FakeAdapter(body: body, contentType: contentType);
  return UpdateService(dio: dio);
}

const _validJson = '''
{
  "version": "0.1.1",
  "apk_url": "https://example.com/PlantViewer-v0.1.1.apk",
  "notes": "test",
  "min_supported_db": 1
}
''';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PackageInfo.setMockInitialValues(
      appName: 'PlantViewer',
      packageName: 'com.mitch8845.vine_viewer',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  test('parses version.json served as application/octet-stream', () async {
    // REGRESSION: GitHub serves release assets as octet-stream, not JSON.
    // Dio's ResponseType.json only decodes when the content type looks like
    // JSON, so it handed back a String and the app reported "Malformed
    // version.json" against a file that was perfectly valid. Caught only by
    // running the real update on a real device.
    final service = _serviceReturning(
      _validJson,
      contentType: 'application/octet-stream',
    );

    final result = await service.check();

    expect(result, isA<UpdateAvailable>());
    expect((result as UpdateAvailable).info.version.toString(), '0.1.1');
  });

  test('still parses when served as application/json', () async {
    final service = _serviceReturning(
      _validJson,
      contentType: 'application/json',
    );
    expect(await service.check(), isA<UpdateAvailable>());
  });

  test('reports up to date when the published version matches', () async {
    final service = _serviceReturning(
      _validJson.replaceAll('0.1.1', '0.1.0'),
      contentType: 'application/octet-stream',
    );
    expect(await service.check(), isA<UpToDate>());
  });

  test('reports up to date when the published version is older', () async {
    final service = _serviceReturning(
      _validJson.replaceAll('0.1.1', '0.0.9'),
      contentType: 'application/octet-stream',
    );
    expect(await service.check(), isA<UpToDate>());
  });

  test('reports failure on malformed json rather than throwing', () async {
    final service = _serviceReturning(
      'not json at all',
      contentType: 'application/octet-stream',
    );
    expect(await service.check(), isA<UpdateCheckFailed>());
  });

  test('reports failure on an empty body', () async {
    final service = _serviceReturning('', contentType: 'application/json');
    expect(await service.check(), isA<UpdateCheckFailed>());
  });

  test('missing apk_url is treated as malformed, not as an update', () async {
    final service = _serviceReturning(
      '{"version": "9.9.9"}',
      contentType: 'application/octet-stream',
    );
    expect(await service.check(), isA<UpdateCheckFailed>());
  });
}

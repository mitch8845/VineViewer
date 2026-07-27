import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/features/updater/version.dart';

void main() {
  group('Version.tryParse', () {
    test('parses a plain version', () {
      expect(Version.tryParse('1.2.3'), const Version(1, 2, 3));
    });

    test('strips a leading v from git tags', () {
      expect(Version.tryParse('v0.1.1'), const Version(0, 1, 1));
    });

    test('strips the +build suffix from pubspec versions', () {
      expect(Version.tryParse('0.1.1+7'), const Version(0, 1, 1));
    });

    test('pads missing components', () {
      expect(Version.tryParse('2'), const Version(2, 0, 0));
      expect(Version.tryParse('2.5'), const Version(2, 5, 0));
    });

    test('returns null on garbage rather than throwing', () {
      // A malformed version.json must leave the app on "couldn't check",
      // never crash it.
      for (final bad in ['', 'abc', '1.2.3.4', '1.-2.3', 'v', '1.x.3']) {
        expect(Version.tryParse(bad), isNull, reason: 'input: "$bad"');
      }
    });
  });

  group('comparison', () {
    test('orders by major, then minor, then patch', () {
      expect(
        const Version(1, 0, 0).isNewerThan(const Version(0, 9, 9)),
        isTrue,
      );
      expect(
        const Version(0, 2, 0).isNewerThan(const Version(0, 1, 9)),
        isTrue,
      );
      expect(
        const Version(0, 1, 2).isNewerThan(const Version(0, 1, 1)),
        isTrue,
      );
    });

    test('equal versions are not newer', () {
      expect(
        const Version(1, 2, 3).isNewerThan(const Version(1, 2, 3)),
        isFalse,
      );
    });

    test('older versions are not newer', () {
      expect(
        const Version(1, 2, 3).isNewerThan(const Version(2, 0, 0)),
        isFalse,
      );
    });

    test('compares numerically, not lexicographically', () {
      // The bug this guards: string comparison puts "0.10.0" before "0.9.0",
      // so the tablet would sit on 0.9.0 reporting itself up to date forever.
      expect(
        const Version(0, 10, 0).isNewerThan(const Version(0, 9, 0)),
        isTrue,
      );
      expect(
        const Version(0, 2, 10).isNewerThan(const Version(0, 2, 9)),
        isTrue,
      );
    });

    test('the real upgrade path this release will exercise', () {
      final installed = Version.tryParse('0.1.0+1')!;
      final published = Version.tryParse('v0.1.1')!;
      expect(published.isNewerThan(installed), isTrue);
    });
  });
}

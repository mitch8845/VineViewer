/// Semantic version comparison, kept free of I/O so it can be tested directly.
///
/// A wrong comparison here fails silently and in the worst direction: the
/// tablet reports "up to date" while sitting on an old build, and nothing
/// surfaces the mistake. It is the one piece of the updater worth testing hard.
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// Parses `1.2.3`. Tolerates a leading `v` and a `+buildNumber` suffix, since
  /// tags arrive as `v0.1.1` and pubspec versions as `0.1.1+2`.
  ///
  /// Returns null rather than throwing: a malformed version from the network
  /// should leave the app on "couldn't check", never crash it.
  static Version? tryParse(String input) {
    var s = input.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final plus = s.indexOf('+');
    if (plus != -1) s = s.substring(0, plus);
    final hyphen = s.indexOf('-');
    if (hyphen != -1) s = s.substring(0, hyphen);

    final parts = s.split('.');
    if (parts.isEmpty || parts.length > 3) return null;

    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0) return null;
      nums.add(n);
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return Version(nums[0], nums[1], nums[2]);
  }

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool isNewerThan(Version other) => compareTo(other) > 0;

  @override
  String toString() => '$major.$minor.$patch';

  @override
  bool operator ==(Object other) =>
      other is Version &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}

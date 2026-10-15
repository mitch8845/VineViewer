/// Small display helpers shared across screens.
library;

/// 1976 -> "1,976". A plant count is read at a glance, and four digits run
/// together are not.
String groupDigits(int n) {
  final s = '${n.abs()}';
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '$b';
}

/// "2026-10-15", in local time.
String isoDate(DateTime at) {
  final d = at.toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

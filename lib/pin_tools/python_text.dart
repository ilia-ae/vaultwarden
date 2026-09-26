/// Text helpers that reproduce Python `str` semantics the PIN tools depend on.
///
/// The Python sources (personal-crypto-tools) split and strip with
/// `str.split()` / `str.strip()`, whose whitespace set is NOT Dart's `\s` or
/// `String.trim()`: it includes U+001C–001F and U+0085 but not U+FEFF or
/// U+200B. Using the Dart built-ins would silently change derived PINs.
library;

/// Code points for which Python 3's `str.isspace()` is true (Unicode 16).
const Set<int> pythonWhitespace = {
  0x0009, 0x000A, 0x000B, 0x000C, 0x000D, //
  0x001C, 0x001D, 0x001E, 0x001F, 0x0020, //
  0x0085, 0x00A0, 0x1680, //
  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, //
  0x2006, 0x2007, 0x2008, 0x2009, 0x200A, //
  0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
};

bool isPythonSpace(int codePoint) => pythonWhitespace.contains(codePoint);

/// Python `s.split()` (no separator): split on runs of whitespace, drop empties.
List<String> pythonSplit(String s) {
  final parts = <String>[];
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (isPythonSpace(r)) {
      if (buf.isNotEmpty) {
        parts.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.writeCharCode(r);
    }
  }
  if (buf.isNotEmpty) parts.add(buf.toString());
  return parts;
}

/// Python `s.strip()` (no argument).
String pythonStrip(String s) {
  final runes = s.runes.toList();
  var start = 0;
  var end = runes.length;
  while (start < end && isPythonSpace(runes[start])) {
    start++;
  }
  while (end > start && isPythonSpace(runes[end - 1])) {
    end--;
  }
  return String.fromCharCodes(runes.sublist(start, end));
}

/// True if [s] contains an unpaired UTF-16 surrogate. Python's strict UTF-8
/// encoder rejects these, while Dart's `utf8.encode` silently replaces them
/// with U+FFFD — which would derive a different (wrong) PIN.
bool hasLoneSurrogate(String s) {
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 < units.length &&
          units[i + 1] >= 0xDC00 &&
          units[i + 1] <= 0xDFFF) {
        i++;
        continue;
      }
      return true;
    }
    if (u >= 0xDC00 && u <= 0xDFFF) return true;
  }
  return false;
}

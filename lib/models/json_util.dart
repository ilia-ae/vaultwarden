/// Small helpers for reading Bitwarden / Vaultwarden JSON.
///
/// bitwarden.com answers with PascalCase keys in several places (identity
/// token responses, `ErrorModel`), Vaultwarden mostly with camelCase — so
/// every lookup here is case-insensitive.
library;

import 'dart:convert';

/// Case-insensitive lookup of [key] in a JSON object. Returns null when
/// [map] is not a map or the key is absent.
Object? jsonGet(Object? map, String key) {
  if (map is! Map) return null;
  if (map.containsKey(key)) return map[key];
  final lower = key.toLowerCase();
  for (final entry in map.entries) {
    final k = entry.key;
    if (k is String && k.toLowerCase() == lower) return entry.value;
  }
  return null;
}

/// Case-insensitive nested lookup: `jsonPath(body, ['errorModel', 'message'])`.
Object? jsonPath(Object? map, List<String> path) {
  Object? current = map;
  for (final key in path) {
    current = jsonGet(current, key);
    if (current == null) return null;
  }
  return current;
}

/// A string value, or null when absent / not a string.
String? jsonString(Object? map, String key) {
  final v = jsonGet(map, key);
  return v is String ? v : null;
}

/// A non-empty (after trim) string value, or null.
String? jsonNonEmptyString(Object? map, String key) {
  final v = jsonString(map, key);
  if (v == null || v.trim().isEmpty) return null;
  return v;
}

/// An int value; accepts ints, integral doubles and numeric strings.
int? jsonInt(Object? map, String key) => asInt(jsonGet(map, key));

/// Coerces a JSON scalar to int (ints, integral nums, numeric strings).
int? asInt(Object? v) {
  if (v is int) return v;
  if (v is num && v == v.roundToDouble()) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// A bool value; accepts bools and 'true'/'false' strings.
bool? jsonBool(Object? map, String key) {
  final v = jsonGet(map, key);
  if (v is bool) return v;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true') return true;
    if (s == 'false') return false;
  }
  return null;
}

/// A JSON object value as `Map<String, dynamic>`, or null.
Map<String, dynamic>? jsonMap(Object? map, String key) =>
    asJsonMap(jsonGet(map, key));

/// Converts any map with string keys to `Map<String, dynamic>`.
Map<String, dynamic>? asJsonMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) {
    return {
      for (final e in v.entries)
        if (e.key != null) e.key.toString(): e.value,
    };
  }
  return null;
}

/// Decodes a response body that arrived as a JSON string (e.g. without a
/// JSON content type); anything else is returned unchanged.
Object? decodeJsonBody(Object? body) {
  if (body is String) {
    final s = body.trim();
    if (s.startsWith('{') || s.startsWith('[')) {
      try {
        return jsonDecode(s);
      } catch (_) {
        return body;
      }
    }
  }
  return body;
}

final _tzSuffix = RegExp(r'(?:[zZ]|[+-]\d{2}(?::?\d{2})?)$');

/// Parses a server timestamp and returns it in UTC.
///
/// Timestamps without an explicit offset are taken as UTC (Vaultwarden and
/// bitwarden.com both store UTC; a missing `Z` must not be read as local
/// time). Returns null for anything that is not a parseable date string.
DateTime? parseServerDate(Object? value) {
  if (value is! String) return null;
  var s = value.trim();
  if (s.isEmpty) return null;
  final sep = s.indexOf(RegExp('[Tt ]'));
  if (sep < 0) {
    // Date only.
    s = '${s}T00:00:00Z';
  } else {
    final timePart = s.substring(sep + 1);
    if (!_tzSuffix.hasMatch(timePart)) s = '${s}Z';
  }
  return DateTime.tryParse(s)?.toUtc();
}

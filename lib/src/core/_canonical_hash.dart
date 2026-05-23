/// Deterministic SHA-256 hash of a bundle's canonical JSON.
///
/// Used by [Canonical] to compare committed disk state against the
/// in-memory draft mirror (DDD-03 §3) and by the patch pipeline's
/// before/after audit row (DDD-04 §6).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mcp_bundle/mcp_bundle.dart';

/// Compute the canonical SHA-256 of [bundle].
///
/// Produces a stable hex string regardless of map iteration order — keys
/// are recursively sorted before encoding. The same bundle round-tripped
/// through `toJson` / `fromJson` always hashes identically.
String canonicalHash(McpBundle bundle) {
  final encoded = _encodeCanonical(bundle.toJson());
  return sha256.convert(utf8.encode(encoded)).toString();
}

/// Identity helper for callers that already hold a JSON map.
String canonicalHashOfJson(Map<String, dynamic> json) {
  return sha256.convert(utf8.encode(_encodeCanonical(json))).toString();
}

String _encodeCanonical(Object? value) {
  final buf = StringBuffer();
  _writeCanonical(buf, value);
  return buf.toString();
}

void _writeCanonical(StringBuffer buf, Object? value) {
  if (value == null) {
    buf.write('null');
  } else if (value is num || value is bool) {
    buf.write(jsonEncode(value));
  } else if (value is String) {
    buf.write(jsonEncode(value));
  } else if (value is List) {
    buf.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) buf.write(',');
      _writeCanonical(buf, value[i]);
    }
    buf.write(']');
  } else if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    buf.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buf.write(',');
      buf.write(jsonEncode(keys[i]));
      buf.write(':');
      _writeCanonical(buf, value[keys[i]]);
    }
    buf.write('}');
  } else {
    buf.write(jsonEncode(value));
  }
}

/// Typed reads of fields in a decoded JSON object. A missing required
/// field or a wrong type raises [HerdrProtocolException].
library;

import 'herdr_errors.dart';

/// The required field [key] of type [T].
T jsonField<T>(Map<String, Object?> j, String key) {
  final v = j[key];
  if (v is T) return v;
  throw HerdrProtocolException(
    'field "$key": expected $T, got ${v == null ? 'nothing' : v.runtimeType}',
  );
}

/// The field [key] of type [T], or null when it is missing or null.
T? jsonOptional<T>(Map<String, Object?> j, String key) {
  final v = j[key];
  if (v == null) return null;
  if (v is T) return v as T;
  throw HerdrProtocolException(
    'field "$key": expected $T or null, got ${v.runtimeType}',
  );
}

/// The objects in the list field [key], each parsed; empty when missing.
List<T> jsonList<T>(
  Map<String, Object?> j,
  String key,
  T Function(Map<String, Object?>) parse,
) {
  final raw = jsonOptional<List<Object?>>(j, key) ?? const [];
  return [
    for (final item in raw)
      if (item is Map<String, Object?>)
        parse(item)
      else
        throw HerdrProtocolException('"$key" holds a non-object item'),
  ];
}

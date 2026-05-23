/// Minimal RFC 6902 patch + inverse calculator used by `PatchPipeline`.
///
/// Supports the four operations that knowledge_builder actually emits —
/// `add` / `remove` / `replace` / `move`. `copy` and `test` are out of
/// scope (DDD-04 §5). The implementation operates on plain JSON maps so
/// the same code is exercised by tests without spinning up the full
/// `mcp_bundle` model.
library;

/// One JSON Patch operation.
class PatchOp {
  const PatchOp({
    required this.op,
    required this.path,
    this.value,
    this.from,
  });

  factory PatchOp.fromJson(Map<String, dynamic> json) {
    return PatchOp(
      op: json['op'] as String,
      path: json['path'] as String,
      value: json['value'],
      from: json['from'] as String?,
    );
  }

  final String op;
  final String path;
  final Object? value;
  final String? from;

  Map<String, dynamic> toJson() => {
        'op': op,
        'path': path,
        if (value != null || op == 'add' || op == 'replace') 'value': value,
        if (from != null) 'from': from,
      };
}

/// A full patch set (ordered list of [PatchOp]).
class JsonPatchSet {
  const JsonPatchSet(this.ops);
  final List<PatchOp> ops;

  /// Pointer paths the patch touches — used by the canonical to track
  /// dirty regions and by the validator to scope cross-ref checks.
  List<String> get changedPointers => [for (final o in ops) o.path];
}

/// Apply [patch] to [json] in place, returning the mutated map. Throws
/// [PatchApplyException] on illegal operations (missing parent, invalid
/// pointer, unsupported op).
Map<String, dynamic> applyPatch(
  Map<String, dynamic> json,
  JsonPatchSet patch,
) {
  for (final op in patch.ops) {
    _applyOne(json, op);
  }
  return json;
}

/// Compute the inverse of [patch] given the [beforeJson] state. Apply
/// the returned set after [patch] to revert in-memory changes.
///
/// Implementation simulates the patch step by step on a private clone so
/// each inverse op resolves the `/-` list-end sentinel to a concrete
/// index and captures the right "old value" even when several ops touch
/// the same path. The collected inverse ops are then reversed so that
/// applying them in order undoes the original sequence.
JsonPatchSet computeInverse(
  Map<String, dynamic> beforeJson,
  JsonPatchSet patch,
) {
  final state = _deepCloneJson(beforeJson);
  final inverseOps = <PatchOp>[];
  for (final op in patch.ops) {
    inverseOps.add(_inverseOf(state, op));
    _applyOne(state, op);
  }
  return JsonPatchSet(inverseOps.reversed.toList());
}

PatchOp _inverseOf(Map<String, dynamic> state, PatchOp op) {
  switch (op.op) {
    case 'add':
      if (op.path.endsWith('/-')) {
        final parentPath = op.path.substring(0, op.path.length - 2);
        final list = _readPointer(state, parentPath);
        final idx = (list is List) ? list.length : 0;
        return PatchOp(op: 'remove', path: '$parentPath/$idx');
      }
      return PatchOp(op: 'remove', path: op.path);
    case 'remove':
      final old = _readPointer(state, op.path);
      return PatchOp(op: 'add', path: op.path, value: old);
    case 'replace':
      final old = _readPointer(state, op.path);
      return PatchOp(op: 'replace', path: op.path, value: old);
    case 'move':
      return PatchOp(op: 'move', path: op.from!, from: op.path);
    default:
      throw PatchApplyException('Unsupported op for inverse: ${op.op}');
  }
}

Map<String, dynamic> _deepCloneJson(Map<String, dynamic> source) {
  return _cloneValue(source) as Map<String, dynamic>;
}

Object? _cloneValue(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key as String: _cloneValue(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) _cloneValue(item)];
  }
  return value;
}

void _applyOne(Object container, PatchOp op) {
  final segments = _splitPointer(op.path);
  if (segments.isEmpty) {
    throw PatchApplyException('Cannot mutate document root via patch');
  }
  final last = segments.removeLast();
  final parent = _walkToParent(container, segments);

  switch (op.op) {
    case 'add':
      _addInto(parent, last, op.value);
      break;
    case 'remove':
      _removeFrom(parent, last);
      break;
    case 'replace':
      _replaceIn(parent, last, op.value);
      break;
    case 'move':
      final fromSegments = _splitPointer(op.from!);
      final fromLast = fromSegments.removeLast();
      final fromParent = _walkToParent(container, fromSegments);
      final moved = _readChild(fromParent, fromLast);
      _removeFrom(fromParent, fromLast);
      _addInto(parent, last, moved);
      break;
    default:
      throw PatchApplyException('Unsupported op: ${op.op}');
  }
}

Object _walkToParent(Object container, List<String> segments) {
  Object current = container;
  for (final seg in segments) {
    final next = _readChild(current, seg);
    if (next == null) {
      throw PatchApplyException('Pointer segment "$seg" missing');
    }
    current = next;
  }
  return current;
}

Object? _readChild(Object container, String key) {
  if (container is Map) {
    return container[key];
  } else if (container is List) {
    final idx = int.parse(key);
    return container[idx];
  }
  throw PatchApplyException('Cannot index $key into ${container.runtimeType}');
}

Object? _readPointer(Map<String, dynamic> json, String pointer) {
  final segments = _splitPointer(pointer);
  Object? current = json;
  for (final seg in segments) {
    if (current is Map) {
      current = current[seg];
    } else if (current is List) {
      current = current[int.parse(seg)];
    } else {
      return null;
    }
  }
  return current;
}

void _addInto(Object container, String key, Object? value) {
  if (container is Map) {
    (container as Map<String, dynamic>)[key] = value;
  } else if (container is List) {
    if (key == '-') {
      container.add(value);
    } else {
      container.insert(int.parse(key), value);
    }
  } else {
    throw PatchApplyException('Cannot add into ${container.runtimeType}');
  }
}

void _removeFrom(Object container, String key) {
  if (container is Map) {
    container.remove(key);
  } else if (container is List) {
    container.removeAt(int.parse(key));
  } else {
    throw PatchApplyException('Cannot remove from ${container.runtimeType}');
  }
}

void _replaceIn(Object container, String key, Object? value) {
  if (container is Map) {
    (container as Map<String, dynamic>)[key] = value;
  } else if (container is List) {
    container[int.parse(key)] = value;
  } else {
    throw PatchApplyException(
        'Cannot replace in ${container.runtimeType}');
  }
}

List<String> _splitPointer(String pointer) {
  if (!pointer.startsWith('/')) {
    throw PatchApplyException('Pointer must start with /: $pointer');
  }
  if (pointer == '/') return <String>[];
  return pointer
      .substring(1)
      .split('/')
      .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
      .toList();
}

class PatchApplyException implements Exception {
  PatchApplyException(this.message);
  final String message;
  @override
  String toString() => 'PatchApplyException: $message';
}

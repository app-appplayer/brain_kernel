/// Public core types shared across knowledge_builder modules.
///
/// Anything that flows between CORE / FEAT / INFRA layers belongs here so
/// that no upper module depends on another upper module just for a value
/// type. (DDD-15 §1 — `ChatTurn` lives here, not in `feat/chat`.)
library;

/// Six asset categories produced and edited by knowledge_builder. Each
/// maps 1:1 to an `mcp_bundle` native section (DDD-13 §2 / SDD §2.2 of
/// MOD-CORE-005 AssetCategoryMap).
enum AssetCategory {
  chunks,
  fact,
  skill,
  profile,
  philosophy,
  agent,
}

/// Role of a single chat turn in the LLM assistant pane (DDD-15 §1).
enum ChatRole {
  user,
  assistant,
  system,
  assistantError,
  toolUse,
  toolResult,
}

/// One conversation turn in the assistant pane. Lives in `core/types.dart`
/// so `infra` adapters can hydrate it from disk without depending on the
/// `feat/chat` widget tree.
///
/// `agentId` carries which FlowBrain agent produced or received the turn —
/// chat is agent-scoped (FR-CHT-001 / FR-CHT-002). `null` for legacy global
/// turns (pre-agent-scoping).
class ChatTurn {
  const ChatTurn({
    required this.id,
    required this.role,
    required this.text,
    required this.ts,
    this.agentId,
    this.meta,
  });

  factory ChatTurn.fromJson(Map<String, dynamic> json) {
    return ChatTurn(
      id: json['id'] as String? ?? '',
      role: ChatRole.values.firstWhere(
        (r) => r.name == json['role'],
        orElse: () => ChatRole.system,
      ),
      text: json['text'] as String? ?? '',
      ts: DateTime.tryParse(json['ts'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      agentId: json['agentId'] as String?,
      meta: (json['meta'] as Map?)?.cast<String, dynamic>(),
    );
  }

  final String id;
  final ChatRole role;
  final String text;
  final DateTime ts;
  final String? agentId;
  final Map<String, dynamic>? meta;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'ts': ts.toUtc().toIso8601String(),
        if (agentId != null) 'agentId': agentId,
        if (meta != null) 'meta': meta,
      };

  ChatTurn copyWith({
    String? id,
    ChatRole? role,
    String? text,
    DateTime? ts,
    String? agentId,
    Map<String, dynamic>? meta,
  }) {
    return ChatTurn(
      id: id ?? this.id,
      role: role ?? this.role,
      text: text ?? this.text,
      ts: ts ?? this.ts,
      agentId: agentId ?? this.agentId,
      meta: meta ?? this.meta,
    );
  }
}

/// MOD-INFRA-004 — AgentChatController.
///
/// Per-agent chat surface (FR-CHT-006). One controller per FlowBrain agent —
/// holds the agent's chat.jsonl, exposes a turn stream, dispatches user
/// messages through `KnowledgeSystem.agents.ask`, and persists each turn
/// (user / assistant / assistantError / toolUse / toolResult) as it lands.
///
/// Agent switch = controller swap. The kernel never multiplexes turns from
/// multiple agents through one controller — that would violate the
/// agent-scoped LLM context invariant of `project_flowbrain_agent_layer`.
///
/// Tool-use (FR-CHT-003): when [tools] is non-empty, the controller exposes
/// the same tool whitelist on every dispatch and persists `toolUse` /
/// `toolResult` turns as the host runs handlers. The recursive tool-call
/// loop itself stays on the host side (kernel does not pick handlers); the
/// controller only enforces [turnLimit] (FR-CHT-004) on consecutive
/// tool-use rounds.
///
/// System prompt composition (FR-CHT-007): the controller passes through
/// `agent.systemPrompt` unchanged. Synthesis with the four axes
/// (Profile.sections / Skill.procedures / Fact summary / Philosophy) is the
/// host's responsibility — supply a [systemPromptResolver] that returns the
/// composed prompt when called, and the controller will invoke it before
/// each `agents.ask`.
///
/// Headless: the implementation depends on `dart:async` / `dart:io` only —
/// no Flutter / `package:flutter/foundation.dart` ValueNotifier (NFR-HEADLESS-001).
library;

import 'dart:async';

import 'package:flowbrain_core/flowbrain_core.dart'
    show AgentReply, AgentToolCall, KnowledgeSystem;
import 'package:mcp_bundle/mcp_bundle.dart' show LlmTool;

import '../../core/sidecar/chat_log.dart';
import '../../core/types.dart';

/// Result of one [AgentChatController.sendUser] call. Surfaces the latest
/// `AgentReply` plus the turns appended during the dispatch (handy for
/// host-side tool-use loops that need the structured tool-call list
/// without re-reading the whole stream).
class AgentChatDispatchResult {
  const AgentChatDispatchResult({
    required this.appended,
    this.reply,
    this.error,
  });

  final List<ChatTurn> appended;
  final AgentReply? reply;
  final Object? error;

  bool get isError => error != null;
}

/// Strategy for composing the agent's runtime system prompt. Receives the
/// current agent id (host can look up the Agent definition + 4-axis state)
/// and returns the synthesized prompt that will be carried in
/// `KnowledgeSystem.agents.ask`. Returning `null` falls back to whatever
/// `agent.systemPrompt` the registry already holds.
typedef SystemPromptResolver = Future<String?> Function(String agentId);

class AgentChatController {
  AgentChatController({
    required this.agentId,
    required KnowledgeSystem system,
    required ChatLog chatLog,
    List<LlmTool>? tools,
    int turnLimit = 8,
    SystemPromptResolver? systemPromptResolver,
  })  : _system = system,
        _chatLog = chatLog,
        _tools = tools,
        _turnLimit = turnLimit,
        _systemPromptResolver = systemPromptResolver,
        _turns = <ChatTurn>[];

  /// Owning agent id. Every turn appended through this controller will
  /// carry this id (via `ChatTurn.agentId`) so a single multi-agent host
  /// can replay logs without ambiguity.
  final String agentId;

  final KnowledgeSystem _system;
  final ChatLog _chatLog;
  final List<LlmTool>? _tools;
  final int _turnLimit;
  final SystemPromptResolver? _systemPromptResolver;

  final List<ChatTurn> _turns;
  final StreamController<List<ChatTurn>> _historyChanges =
      StreamController<List<ChatTurn>>.broadcast();
  final StreamController<ChatTurn> _turnAppended =
      StreamController<ChatTurn>.broadcast();

  bool _disposed = false;

  /// Snapshot of the current in-memory history. Returned as an unmodifiable
  /// view — callers should subscribe to [historyChanges] / [onTurn] for
  /// live updates rather than polling.
  List<ChatTurn> get history => List.unmodifiable(_turns);

  /// Broadcast: emits the full history snapshot whenever it changes.
  Stream<List<ChatTurn>> get historyChanges => _historyChanges.stream;

  /// Broadcast: emits each appended turn individually (cheaper for UIs
  /// that want to render only the delta).
  Stream<ChatTurn> get onTurn => _turnAppended.stream;

  /// Path to the underlying `chat/<agentId>.jsonl` file.
  String get logPath => _chatLog.path;

  /// Hydrate the controller's history from disk. Call once after construction
  /// (before [sendUser]). Subsequent calls reset the in-memory state to whatever
  /// is on disk.
  Future<void> rehydrate({int? limit}) async {
    _checkAlive();
    final all = await _chatLog.readAll();
    final loaded = limit == null || all.length <= limit
        ? all
        : all.sublist(all.length - limit);
    _turns
      ..clear()
      ..addAll(loaded);
    _emitHistory();
  }

  /// Replace the in-memory history with [turns]. Does not touch the disk
  /// log — used by tests and by host code that already loaded turns
  /// elsewhere.
  void seed(Iterable<ChatTurn> turns) {
    _checkAlive();
    _turns
      ..clear()
      ..addAll(turns);
    _emitHistory();
  }

  /// Truncate the on-disk log and clear the in-memory history.
  Future<void> clear() async {
    _checkAlive();
    await _chatLog.clear();
    _turns.clear();
    _emitHistory();
  }

  /// Append a turn to history and persist it to disk. Returns the turn
  /// (with `agentId` stamped) so callers can chain it into their own
  /// downstream logic.
  Future<ChatTurn> appendTurn(ChatTurn turn) async {
    _checkAlive();
    final stamped =
        turn.agentId == null ? turn.copyWith(agentId: agentId) : turn;
    _turns.add(stamped);
    _turnAppended.add(stamped);
    _emitHistory();
    await _chatLog.append(stamped);
    return stamped;
  }

  /// Dispatch a user message: append the user turn, call
  /// `system.agents.ask`, append the assistant reply (or `assistantError`
  /// on failure plus optional toolUse turns), and return a structured
  /// result.
  Future<AgentChatDispatchResult> sendUser(String text) async {
    _checkAlive();
    final appended = <ChatTurn>[];
    final userTurn = ChatTurn(
      id: _newId('user'),
      role: ChatRole.user,
      text: text,
      ts: DateTime.now().toUtc(),
      agentId: agentId,
    );
    appended.add(await appendTurn(userTurn));

    AgentReply? reply;
    try {
      reply = await _ask(text);
    } catch (err) {
      final errTurn = ChatTurn(
        id: _newId('err'),
        role: ChatRole.assistantError,
        text: err.toString(),
        ts: DateTime.now().toUtc(),
        agentId: agentId,
        meta: <String, dynamic>{'error': err.runtimeType.toString()},
      );
      appended.add(await appendTurn(errTurn));
      return AgentChatDispatchResult(
        appended: List.unmodifiable(appended),
        error: err,
      );
    }

    final assistantTurn = ChatTurn(
      id: _newId('asst'),
      role: ChatRole.assistant,
      text: reply.content,
      ts: reply.timestamp.toUtc(),
      agentId: agentId,
      meta: _replyMeta(reply),
    );
    appended.add(await appendTurn(assistantTurn));

    final calls = reply.toolCalls ?? const <AgentToolCall>[];
    if (calls.isNotEmpty) {
      final clamped =
          calls.length > _turnLimit ? calls.sublist(0, _turnLimit) : calls;
      for (final c in clamped) {
        final toolTurn = ChatTurn(
          id: _newId('tool'),
          role: ChatRole.toolUse,
          text: c.name,
          ts: DateTime.now().toUtc(),
          agentId: agentId,
          meta: <String, dynamic>{
            'toolCallId': c.id,
            'arguments': c.arguments,
          },
        );
        appended.add(await appendTurn(toolTurn));
      }
      if (calls.length > _turnLimit) {
        final warn = ChatTurn(
          id: _newId('warn'),
          role: ChatRole.system,
          text: 'turn-limit reached ($_turnLimit) — '
              '${calls.length - _turnLimit} additional tool call(s) suppressed',
          ts: DateTime.now().toUtc(),
          agentId: agentId,
        );
        appended.add(await appendTurn(warn));
      }
    }

    return AgentChatDispatchResult(
      appended: List.unmodifiable(appended),
      reply: reply,
    );
  }

  /// Append a `toolResult` turn. Hosts call this once their handler for a
  /// preceding `toolUse` finishes, so the assistant's next turn (if any)
  /// can read the result back from history.
  Future<ChatTurn> appendToolResult({
    required String toolCallId,
    required String resultText,
    Map<String, dynamic>? meta,
  }) {
    _checkAlive();
    final turn = ChatTurn(
      id: _newId('result'),
      role: ChatRole.toolResult,
      text: resultText,
      ts: DateTime.now().toUtc(),
      agentId: agentId,
      meta: <String, dynamic>{'toolCallId': toolCallId, ...?meta},
    );
    return appendTurn(turn);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _historyChanges.close();
    await _turnAppended.close();
  }

  Future<AgentReply> _ask(String message) async {
    final composed = _systemPromptResolver == null
        ? null
        : await _systemPromptResolver(agentId);
    final ctx = composed == null
        ? null
        : <String, Object?>{'systemPromptOverride': composed};
    return _system.agents.ask(
      agentId,
      message,
      context: ctx,
      tools: _tools,
    );
  }

  Map<String, dynamic>? _replyMeta(AgentReply reply) {
    final m = <String, dynamic>{
      'replyId': reply.id,
      'model': reply.model,
      if (reply.finishReason != null) 'finishReason': reply.finishReason,
      if (reply.tokenUsage != null) 'tokenUsage': reply.tokenUsage!.toJson(),
    };
    return m.isEmpty ? null : m;
  }

  void _emitHistory() {
    if (_disposed) return;
    _historyChanges.add(List.unmodifiable(_turns));
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('AgentChatController(${agentId}) already disposed');
    }
  }

  String _newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';
}

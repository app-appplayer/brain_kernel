import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<Directory> _tmpProject() =>
    Directory.systemTemp.createTemp('agent_chat_ctrl_');

Future<Agent> _agent(KnowledgeSystem system, String id) =>
    system.agents.createAgent(
      id: id,
      displayName: id,
      model: ModelSpec.stub(),
      workspaceId: 'default',
    );

void main() {
  group('AgentChatController', () {
    test('sendUser appends user + assistant turns and persists them',
        () async {
      final system = KnowledgeSystem.withAgents();
      await _agent(system, 'sara');

      final dir = await _tmpProject();
      addTearDown(() => dir.delete(recursive: true));

      final ctrl = AgentChatController(
        agentId: 'sara',
        system: system,
        chatLog: ChatLog.attachAgent(dir.path, 'sara'),
      );

      final result = await ctrl.sendUser('hello');
      expect(result.error, isNull);
      expect(result.reply, isNotNull);
      expect(result.reply!.agentId, 'sara');

      final history = ctrl.history;
      expect(history.first.role, ChatRole.user);
      expect(history.first.text, 'hello');
      expect(history.first.agentId, 'sara');
      expect(history.last.role, ChatRole.assistant);
      expect(history.last.agentId, 'sara');

      // Disk persistence: jsonl matches in-memory snapshot.
      final logFile = File(p.join(dir.path, 'chat', 'sara.jsonl'));
      expect(await logFile.exists(), isTrue);
      final lines = (await logFile.readAsString()).trim().split('\n');
      expect(lines.length, history.length);

      await ctrl.dispose();
    });

    test('agents are isolated — controller A does not leak into B', () async {
      final system = KnowledgeSystem.withAgents();
      await _agent(system, 'sara');
      await _agent(system, 'bob');

      final dir = await _tmpProject();
      addTearDown(() => dir.delete(recursive: true));

      final saraCtrl = AgentChatController(
        agentId: 'sara',
        system: system,
        chatLog: ChatLog.attachAgent(dir.path, 'sara'),
      );
      final bobCtrl = AgentChatController(
        agentId: 'bob',
        system: system,
        chatLog: ChatLog.attachAgent(dir.path, 'bob'),
      );

      await saraCtrl.sendUser('how is sara?');
      await bobCtrl.sendUser('how is bob?');

      // Sara only has Sara turns; Bob only has Bob turns.
      expect(
        saraCtrl.history.every((t) => t.agentId == 'sara'),
        isTrue,
        reason: 'sara controller must not contain bob turns',
      );
      expect(
        bobCtrl.history.every((t) => t.agentId == 'bob'),
        isTrue,
        reason: 'bob controller must not contain sara turns',
      );

      // Two distinct sidecar files — no shared journal.
      final saraLog = File(p.join(dir.path, 'chat', 'sara.jsonl'));
      final bobLog = File(p.join(dir.path, 'chat', 'bob.jsonl'));
      expect(await saraLog.exists(), isTrue);
      expect(await bobLog.exists(), isTrue);
      expect(saraLog.path, isNot(equals(bobLog.path)));

      await saraCtrl.dispose();
      await bobCtrl.dispose();
    });

    test('rehydrate replays persisted turns', () async {
      final system = KnowledgeSystem.withAgents();
      await _agent(system, 'sara');

      final dir = await _tmpProject();
      addTearDown(() => dir.delete(recursive: true));

      final first = AgentChatController(
        agentId: 'sara',
        system: system,
        chatLog: ChatLog.attachAgent(dir.path, 'sara'),
      );
      await first.sendUser('first round');
      final beforeCount = first.history.length;
      await first.dispose();

      final second = AgentChatController(
        agentId: 'sara',
        system: system,
        chatLog: ChatLog.attachAgent(dir.path, 'sara'),
      );
      await second.rehydrate();
      expect(second.history.length, beforeCount);
      expect(second.history.last.agentId, 'sara');
      await second.dispose();
    });

    test('clear truncates both memory and disk', () async {
      final system = KnowledgeSystem.withAgents();
      await _agent(system, 'sara');

      final dir = await _tmpProject();
      addTearDown(() => dir.delete(recursive: true));

      final ctrl = AgentChatController(
        agentId: 'sara',
        system: system,
        chatLog: ChatLog.attachAgent(dir.path, 'sara'),
      );
      await ctrl.sendUser('first');
      expect(ctrl.history, isNotEmpty);

      await ctrl.clear();
      expect(ctrl.history, isEmpty);

      final logFile = File(p.join(dir.path, 'chat', 'sara.jsonl'));
      expect(await logFile.readAsString(), isEmpty);

      await ctrl.dispose();
    });

    test('historyChanges + onTurn streams emit on append', () async {
      final system = KnowledgeSystem.withAgents();
      await _agent(system, 'sara');

      final dir = await _tmpProject();
      addTearDown(() => dir.delete(recursive: true));

      final ctrl = AgentChatController(
        agentId: 'sara',
        system: system,
        chatLog: ChatLog.attachAgent(dir.path, 'sara'),
      );

      final history = <List<ChatTurn>>[];
      final turns = <ChatTurn>[];
      final s1 = ctrl.historyChanges.listen(history.add);
      final s2 = ctrl.onTurn.listen(turns.add);

      await ctrl.sendUser('hi');
      // Allow microtasks to drain.
      await Future<void>.delayed(Duration.zero);

      expect(history, isNotEmpty);
      expect(turns, isNotEmpty);
      expect(turns.first.role, ChatRole.user);
      expect(turns.every((t) => t.agentId == 'sara'), isTrue);

      await s1.cancel();
      await s2.cancel();
      await ctrl.dispose();
    });

    test('appendToolResult writes a toolResult turn linked by toolCallId',
        () async {
      final system = KnowledgeSystem.withAgents();
      await _agent(system, 'sara');

      final dir = await _tmpProject();
      addTearDown(() => dir.delete(recursive: true));

      final ctrl = AgentChatController(
        agentId: 'sara',
        system: system,
        chatLog: ChatLog.attachAgent(dir.path, 'sara'),
      );
      final turn = await ctrl.appendToolResult(
        toolCallId: 'tc-1',
        resultText: 'ok',
      );
      expect(turn.role, ChatRole.toolResult);
      expect(turn.agentId, 'sara');
      expect(turn.meta?['toolCallId'], 'tc-1');
      expect(ctrl.history.last, equals(turn));
      await ctrl.dispose();
    });
  });
}

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mcpb_caps_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('empty .mbd → empty capabilities', () async {
    final mbd = Directory(p.join(tmp.path, 'empty.mbd'));
    await mbd.create();
    final caps = await McpbPackager.computeCapabilities(mbd.path);
    expect(caps, isEmpty);
  });

  test('shell.json present → studio.shell capability', () async {
    final mbd = Directory(p.join(tmp.path, 'sh.mbd'));
    await mbd.create();
    await File(p.join(mbd.path, 'shell.json')).writeAsString('{}');
    final caps = await McpbPackager.computeCapabilities(mbd.path);
    expect(caps, contains('studio.shell'));
  });

  test(
      'builder_extension.json contributes → studio.tool.<n> + .agent.<id> + '
      '.settings_section.<id> + .debug_view.<id> capabilities',
      () async {
    final mbd = Directory(p.join(tmp.path, 'ext.mbd'));
    await mbd.create();
    await File(p.join(mbd.path, 'demo.builder_extension.json'))
        .writeAsString('''
{
  "schemaVersion": 1,
  "id": "demo",
  "name": "Demo",
  "version": "0.0.1",
  "contributes": {
    "tools": [
      {"name": "demo_alpha", "description": "x", "handler": "demo.alpha"},
      {"name": "demo_beta",  "description": "y", "handler": "demo.beta"}
    ],
    "agents": [
      {
        "id": "demo-coach",
        "displayName": "Demo Coach",
        "modelId": "claude-haiku-4-5-20251001",
        "systemPrompt": "...",
        "toolNames": ["demo_alpha"],
        "role": "worker"
      }
    ],
    "settingsSections": [
      {"label": "Demo", "viewId": "demo.tuning"}
    ],
    "debugViews": [
      {"label": "Demo Debug", "viewId": "demo.debug"}
    ]
  }
}
''');
    final caps = await McpbPackager.computeCapabilities(mbd.path);
    expect(caps, containsAll(<String>[
      'studio.tool.demo_alpha',
      'studio.tool.demo_beta',
      'studio.agent.demo-coach',
      'studio.settings_section.demo.tuning',
      'studio.debug_view.demo.debug',
    ]));
  });

  test('knowledge/<namespace> subdirs → studio.knowledge.<ns>', () async {
    final mbd = Directory(p.join(tmp.path, 'kn.mbd'));
    await mbd.create();
    final knowledge = Directory(p.join(mbd.path, 'knowledge'));
    await knowledge.create();
    await Directory(p.join(knowledge.path, 'recipe.nutrition')).create();
    await Directory(p.join(knowledge.path, 'recipe.allergens')).create();
    final caps = await McpbPackager.computeCapabilities(mbd.path);
    expect(caps, containsAll(<String>[
      'studio.knowledge.recipe.allergens',
      'studio.knowledge.recipe.nutrition',
    ]));
  });

  test('combo bundle yields all capability prefixes deterministically',
      () async {
    final mbd = Directory(p.join(tmp.path, 'combo.mbd'));
    await mbd.create();
    await File(p.join(mbd.path, 'shell.json')).writeAsString('{}');
    await Directory(p.join(mbd.path, 'knowledge', 'core'))
        .create(recursive: true);
    await File(p.join(mbd.path, 'tools.builder_extension.json'))
        .writeAsString('''
{
  "schemaVersion": 1,
  "id": "combo",
  "name": "Combo",
  "version": "0.0.1",
  "contributes": {
    "tools": [
      {"name": "combo_x", "description": "x", "handler": "combo.x"}
    ]
  }
}
''');
    final caps = await McpbPackager.computeCapabilities(mbd.path);
    expect(caps, <String>[
      'studio.knowledge.core',
      'studio.shell',
      'studio.tool.combo_x',
    ]); // sorted
  });

  test('malformed builder_extension.json is silently skipped', () async {
    final mbd = Directory(p.join(tmp.path, 'bad.mbd'));
    await mbd.create();
    await File(p.join(mbd.path, 'broken.builder_extension.json'))
        .writeAsString('not json');
    await File(p.join(mbd.path, 'good.builder_extension.json'))
        .writeAsString('''
{
  "schemaVersion": 1,
  "id": "good",
  "name": "Good",
  "version": "0.0.1",
  "contributes": {
    "tools": [
      {"name": "good_tool", "description": "x", "handler": "good.x"}
    ]
  }
}
''');
    final caps = await McpbPackager.computeCapabilities(mbd.path);
    expect(caps, contains('studio.tool.good_tool'));
    // No crash, no entry from malformed file.
  });
}

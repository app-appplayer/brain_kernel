/// `bk.profile.*` — ProfileFacade wrappers (`register` / `unregister`
/// / `list` / `get`).
library;

import 'package:flowbrain_core/flowbrain_core.dart' as fb;

import '../kernel_app.dart';
import 'standard_tools.dart';

Map<String, InProcessToolHandler> buildProfileTools(KernelApp app) {
  fb.ProfileFacade facade() => app.system.profile;

  Future<Object?> register(Map<String, dynamic> p) async {
    final raw = p['profile'];
    if (raw is! Map) return stdErr('profile object required');
    try {
      final m = Map<String, dynamic>.from(raw);
      m['id'] = app.scopeIdFor(m['id'] as String);
      final profile = fb.Profile.fromJson(m);
      facade().register(profile);
      return <String, dynamic>{'ok': true, 'id': profile.id};
    } catch (e) {
      return stdErr('register failed: $e');
    }
  }

  Future<Object?> unregister(Map<String, dynamic> p) async {
    final id = p['profileId'];
    if (id is! String || id.isEmpty) return stdErr('profileId required');
    final removed = facade().unregister(app.scopeIdFor(id));
    return <String, dynamic>{'ok': true, 'removed': removed};
  }

  Future<Object?> list(Map<String, dynamic> p) async {
    try {
      final all = facade().list();
      return <String, dynamic>{
        'ok': true,
        'profiles': all.map((e) => e.toJson()).toList(),
      };
    } catch (e) {
      return stdErr('list failed: $e');
    }
  }

  Future<Object?> get(Map<String, dynamic> p) async {
    final id = p['profileId'];
    if (id is! String || id.isEmpty) return stdErr('profileId required');
    try {
      final profile = facade().get(app.scopeIdFor(id));
      return <String, dynamic>{'ok': true, 'profile': profile?.toJson()};
    } catch (e) {
      return stdErr('get failed: $e');
    }
  }

  return <String, InProcessToolHandler>{
    'bk.profile.register': register,
    'bk.profile.unregister': unregister,
    'bk.profile.list': list,
    'bk.profile.get': get,
  };
}

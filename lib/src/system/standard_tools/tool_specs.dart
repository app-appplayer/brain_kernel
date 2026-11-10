/// What each standard tool is for and what it takes, as the endpoint lists it.
///
/// A model that calls a tool knows only this description and schema, so every
/// tool states its arguments here. The schemas follow what the handlers read;
/// they stay open (`additionalProperties`) so a caller that sends more than
/// is named here is still served as before.
library;

/// One standard tool's listing.
class StandardToolSpec {
  const StandardToolSpec(this.description, this.inputSchema);

  final String description;
  final Map<String, dynamic> inputSchema;
}

const Map<String, dynamic> _str = <String, dynamic>{'type': 'string'};
// A count. The handlers read any number and cut a fraction, so the listing
// says `number`: `integer` would refuse a call such as `limit: 5.5` that the
// tool serves.
const Map<String, dynamic> _count = <String, dynamic>{'type': 'number'};
const Map<String, dynamic> _obj = <String, dynamic>{'type': 'object'};

Map<String, dynamic> _s(
  Map<String, dynamic> properties, [
  List<String> required = const <String>[],
]) =>
    <String, dynamic>{
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': true,
    };

Map<String, dynamic> _d(String text, [Map<String, dynamic> of = _str]) =>
    <String, dynamic>{...of, 'description': text};

const Map<String, dynamic> _factQuery = <String, dynamic>{
  'type': 'object',
  'description':
      'Which facts: {workspaceId?, types?: [string], entityId?, limit?}.',
  'properties': <String, dynamic>{
    'workspaceId': _str,
    'types': <String, dynamic>{
      'type': 'array',
      'items': _str,
    },
    'entityId': _str,
    'limit': _count,
  },
};

const Map<String, dynamic> _modelSpec = <String, dynamic>{
  'type': 'object',
  'description': 'The model the agent runs on: {provider, model}.',
  'properties': <String, dynamic>{'provider': _str, 'model': _str},
};

const Map<String, dynamic> _args = <String, dynamic>{
  'type': 'object',
  'description': 'The inputs of the run, by name.',
};

final Map<String, StandardToolSpec> standardToolSpecs =
    <String, StandardToolSpec>{
  // ── facts ────────────────────────────────────────────────────────────
  'bk.fact.write': StandardToolSpec(
    'Write facts into the store. Each fact is {id, type, content, entityId?, '
    'workspaceId?, confidence?, createdAt?}.',
    _s({
      'facts': <String, dynamic>{
        'type': 'array',
        'description': 'The facts to write.',
        'items': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': _str,
            'type': _str,
            'content': _obj,
            'entityId': _str,
            'workspaceId': _str,
            'confidence': <String, dynamic>{'type': 'number'},
            'createdAt': _str,
          },
          'required': <String>['id', 'type'],
        },
      },
    }, ['facts']),
  ),
  'bk.fact.query': StandardToolSpec(
    'Find facts by type or entity.',
    _s({'query': _factQuery}, ['query']),
  ),
  'bk.fact.get': StandardToolSpec(
    'Read one fact by id.',
    _s({'id': _str}, ['id']),
  ),
  'bk.fact.delete': StandardToolSpec(
    'Delete facts by id.',
    _s({
      'ids': <String, dynamic>{'type': 'array', 'items': _str},
    }, ['ids']),
  ),
  'bk.fact.extract': StandardToolSpec(
    'Cut a text into fragments that could become facts.',
    _s({'text': _str, 'mimeType': _d('Defaults to text/plain.')}, ['text']),
  ),
  'bk.fact.candidates.list': StandardToolSpec(
    'List candidate facts waiting for a reviewer.',
    _s({'workspaceId': _str, 'limit': _count}),
  ),
  'bk.fact.candidates.confirm': StandardToolSpec(
    'Confirm a candidate so it becomes a fact.',
    _s({'candidateId': _str, 'reviewerId': _str}, ['candidateId']),
  ),
  'bk.fact.candidates.reject': StandardToolSpec(
    'Reject a candidate, with the reason.',
    _s({
      'candidateId': _str,
      'reason': _str,
      'reviewerId': _str,
    }, ['candidateId', 'reason']),
  ),
  'bk.fact.entity.get': StandardToolSpec(
    'Read one entity (a person, organisation, project, place) by id.',
    _s({'entityId': _str}, ['entityId']),
  ),

  // ── skills ───────────────────────────────────────────────────────────
  'bk.skill.list': StandardToolSpec(
    'List the skills that can be seen from a scope.',
    _s({
      'workspaceId': _str,
      'scopeId': _d('The scope the caller works in; skills outside it are '
          'left out.'),
    }),
  ),
  'bk.skill.get': StandardToolSpec(
    'Read one skill.',
    _s({'skillId': _str, 'scopeId': _str}, ['skillId']),
  ),
  'bk.skill.execute': StandardToolSpec(
    'Run a skill.',
    _s({
      'skillId': _str,
      'inputs': _d('The inputs of the skill, by name.', _obj),
      'procedureId': _d('Which procedure of the skill to run, when it has '
          'more than one.'),
      'scopeId': _str,
      'actor': _str,
    }, ['skillId']),
  ),

  // ── profiles ─────────────────────────────────────────────────────────
  'bk.profile.register': StandardToolSpec(
    'Register a profile (a way of working).',
    _s({'profile': _d('The profile, as a JSON object.', _obj)}, ['profile']),
  ),
  'bk.profile.unregister': StandardToolSpec(
    'Remove a profile.',
    _s({'profileId': _str}, ['profileId']),
  ),
  'bk.profile.list': StandardToolSpec('List the profiles.', _s({})),
  'bk.profile.get': StandardToolSpec(
    'Read one profile.',
    _s({'profileId': _str}, ['profileId']),
  ),

  // ── philosophies ─────────────────────────────────────────────────────
  'bk.philosophy.put': StandardToolSpec(
    'Store a philosophy (the principles and prohibitions an agent keeps).',
    _s({'ethos': _d('The philosophy, as a JSON object with an `id`.', _obj)},
        ['ethos']),
  ),
  'bk.philosophy.list': StandardToolSpec(
    'List the stored philosophies.',
    _s({'limit': _count}),
  ),
  'bk.philosophy.get': StandardToolSpec(
    'Read one philosophy.',
    _s({'id': _str}, ['id']),
  ),
  'bk.philosophy.activate': StandardToolSpec(
    'Make a philosophy the active one.',
    _s({'id': _str}, ['id']),
  ),
  'bk.philosophy.get_active_id': StandardToolSpec(
    'The id of the active philosophy.',
    _s({}),
  ),
  'bk.philosophy.check': StandardToolSpec(
    'Check an action or an output against the active philosophy\'s '
    'prohibitions. Give `action` or `output`.',
    _s({
      'action': _str,
      'output': _str,
      'context': _d('Anything the check should know, by name.', _obj),
    }),
  ),

  // ── workflows, pipelines, runbooks, behaviours ───────────────────────
  'bk.workflow.run': StandardToolSpec(
    'Start a workflow; the answer carries the run id.',
    _s({'workflowId': _str, 'args': _args}, ['workflowId']),
  ),
  'bk.workflow.list': StandardToolSpec('List the workflows.', _s({})),
  'bk.workflow.get_run': StandardToolSpec(
    'The state of a workflow run.',
    _s({'runId': _str}, ['runId']),
  ),
  'bk.pipeline.run': StandardToolSpec(
    'Start a pipeline; the answer carries the run id.',
    _s({'pipelineId': _str, 'args': _args}, ['pipelineId']),
  ),
  'bk.pipeline.get_run': StandardToolSpec(
    'The state of a pipeline run.',
    _s({'runId': _str}, ['runId']),
  ),
  'bk.runbook.run': StandardToolSpec(
    'Start a runbook.',
    _s({'runbookId': _str, 'args': _args}, ['runbookId']),
  ),
  'bk.runbook.list': StandardToolSpec('List the runbooks.', _s({})),
  'bk.behavior.run': StandardToolSpec(
    'Start a behaviour (a process); give `runId` to name the run yourself.',
    _s({'behaviorId': _str, 'args': _args, 'runId': _str}, ['behaviorId']),
  ),
  'bk.behavior.resume': StandardToolSpec(
    'Continue a behaviour run that waits, optionally changing its state.',
    _s({
      'behaviorId': _str,
      'runId': _str,
      'statePatch': _d('Changes to the run\'s state, by name.', _obj),
    }, ['behaviorId', 'runId']),
  ),
  'bk.behavior.list': StandardToolSpec('List the behaviours.', _s({})),

  // ── agents ───────────────────────────────────────────────────────────
  'bk.agent.list': StandardToolSpec(
    'List agents, optionally of one role or one workspace.',
    _s({
      'role': _d('worker, manager or reviewer.', <String, dynamic>{
        'type': 'string',
        'enum': <String>['worker', 'manager', 'reviewer'],
      }),
      'workspaceId': _str,
    }),
  ),
  'bk.agent.get': StandardToolSpec(
    'Read one agent.',
    _s({'agentId': _str}, ['agentId']),
  ),
  'bk.agent.ask': StandardToolSpec(
    'Send a message to an agent and get its reply.',
    _s({'agentId': _str, 'message': _str}, ['agentId', 'message']),
  ),
  'bk.agent.create': StandardToolSpec(
    'Create an agent. A manager can route work; a reviewer can review; a '
    'worker (the default) does the work.',
    _s({
      'id': _str,
      'displayName': _str,
      'role': _d('worker, manager or reviewer.', <String, dynamic>{
        'type': 'string',
        'enum': <String>['worker', 'manager', 'reviewer'],
      }),
      'model': _modelSpec,
      'workspaceId': _str,
    }, ['id', 'displayName']),
  ),
  'bk.agent.delete': StandardToolSpec(
    'Delete an agent.',
    _s({'agentId': _str}, ['agentId']),
  ),
  'bk.agent.update': StandardToolSpec(
    'Change an agent; only what is given changes.',
    _s({
      'agentId': _str,
      'displayName': _str,
      'role': _d('worker, manager or reviewer.', <String, dynamic>{
        'type': 'string',
        'enum': <String>['worker', 'manager', 'reviewer'],
      }),
      'model': _modelSpec,
      'systemPrompt': _str,
      'tags': _d('Labels, name to text.', _obj),
    }, ['agentId']),
  ),
  'bk.agent.history': StandardToolSpec(
    'The turns an agent has had: what was asked and what it answered.',
    _s({'agentId': _str}, ['agentId']),
  ),
  'bk.agent.assign_skill': StandardToolSpec(
    'Give an agent a copy of a skill from the pool.',
    _s({'agentId': _str, 'skillId': _str}, ['agentId', 'skillId']),
  ),
  'bk.agent.assign_profile': StandardToolSpec(
    'Give an agent a copy of a profile from the pool.',
    _s({'agentId': _str, 'profileId': _str}, ['agentId', 'profileId']),
  ),
  'bk.agent.assign_philosophy': StandardToolSpec(
    'Give an agent a copy of a philosophy from the pool.',
    _s({'agentId': _str, 'ethosId': _str}, ['agentId', 'ethosId']),
  ),
  'bk.agent.assign_facts': StandardToolSpec(
    'Give an agent the facts a query selects.',
    _s({'agentId': _str, 'query': _factQuery}, ['agentId', 'query']),
  ),
  'bk.agent.materialize': StandardToolSpec(
    'Take an agent\'s copy of something into use.',
    _s({
      'agentId': _str,
      'axis': _d('skill, profile, philosophy or facts.', <String, dynamic>{
        'type': 'string',
        'enum': <String>['skill', 'profile', 'philosophy', 'facts'],
      }),
      'forkedRef': _str,
    }, ['agentId', 'axis', 'forkedRef']),
  ),
  'bk.agent.route': StandardToolSpec(
    'A manager picks the agent that should take a request.',
    _s({
      'managerId': _str,
      'request': _str,
      'candidateAgentIds': <String, dynamic>{
        'type': 'array',
        'items': _str,
      },
    }, ['managerId', 'request']),
  ),
  'bk.agent.review': StandardToolSpec(
    'A reviewer gives a verdict on what another agent said.',
    _s({
      'reviewerId': _str,
      'targetAgentId': _str,
      'content': _d('What the target agent said.'),
    }, ['reviewerId', 'targetAgentId', 'content']),
  ),

  // ── knowledge sources ────────────────────────────────────────────────
  'bk.knowledge.query': StandardToolSpec(
    'Search the knowledge sources (documents) of an active bundle. This is '
    'not a search of the recorded statements; use bk.knowledge.compose for '
    'those.',
    _s({
      'text': _d('What to look for.'),
      'topK': _d('How many hits; 5 by default.', _count),
      'namespace': _d('The bundle to search; the active one by default.'),
      'sourceId': _d('Only this source.'),
    }, ['text']),
  ),
  'bk.knowledge.test': StandardToolSpec(
    'Try a search on a bundle\'s knowledge sources by the bundle\'s path.',
    _s({
      'mbdPath': _str,
      'query': _str,
      'topK': _count,
      'sourceId': _str,
    }, ['mbdPath', 'query']),
  ),
};

import '../models/agent_status.dart';
import '../models/tool_config.dart';
import '../models/tool_descriptor.dart';
import '../models/tool_exception.dart';
import 'tool_backend.dart';

/// Stand-in for an OS where the tool cannot run.
///
/// Every method throws, so a button on Windows or Linux cannot quietly "succeed"
/// by writing a file nothing will ever read. The UI is driven by
/// [capabilities], which lists no actions and carries the explanation.
class UnsupportedToolBackend implements ToolBackend {
  UnsupportedToolBackend({required this.descriptor, required this.reason});

  @override
  final ToolDescriptor descriptor;

  final String reason;

  @override
  Capabilities get capabilities => Capabilities(
    support: Support.notOnThisOs,
    actions: const {},
    reason: reason,
  );

  @override
  Future<AgentStatus> status() async =>
      const AgentStatus.notApplicable().withNotes([reason]);

  @override
  Future<void> start() => _refuse('start the agent');

  @override
  Future<void> stop() => _refuse('stop the agent');

  @override
  Future<void> install() => _refuse('install the agent');

  @override
  Future<void> uninstall() => _refuse('uninstall the agent');

  @override
  Future<ToolConfig> readConfig() => _refuse('read its settings');

  @override
  Future<void> writeConfig(ToolConfig config) => _refuse('save its settings');

  @override
  Stream<String> tailLog() =>
      Stream<String>.error(ToolException('UNSUPPORTED_OS', reason));

  Future<Never> _refuse(String what) async =>
      throw ToolException('UNSUPPORTED_OS', 'Cannot $what here: $reason');
}

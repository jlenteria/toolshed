import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/agent_status.dart';
import '../../models/tool_descriptor.dart';
import '../../ui/screens/logs_panel.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/capability_notice.dart';
import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';
import 'app_lock_config.dart';
import 'lock_agent.dart';

/// The app lock console: who is watching, what is locked, and what reopens it.
///
/// Nothing here refuses a launch. A per-user agent cannot intercept `open`, so
/// it notices the launch, asks the app to quit, and lets it back in until it has
/// been idle for the unlock window. Every card describes that mechanism.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  static const _pollEvery = Duration(seconds: 3);

  AppLockConfig _draft = AppLockConfig.defaults;
  List<LockableApp> _apps = const [];
  LockAgentInfo? _info;
  String _query = '';
  bool _loading = true;
  bool _refreshing = false;
  String? _readError;
  String? _openNote;
  Timer? _poll;

  final TextEditingController _passA = TextEditingController();
  final TextEditingController _passB = TextEditingController();
  final TextEditingController _check = TextEditingController();

  String get _id => widget.entry.descriptor.id;

  @override
  void initState() {
    super.initState();
    final saved = widget.entry.config;
    if (saved is AppLockConfig) _draft = saved;
    for (final field in [_passA, _passB, _check]) {
      field.addListener(() => setState(() {}));
    }
    _poll = Timer.periodic(_pollEvery, (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _passA.dispose();
    _passB.dispose();
    _check.dispose();
    super.dispose();
  }

  /// Reads are questions, not controls, so they poll. The draft is never
  /// overwritten by a poll: that would discard an edit mid-typing.
  Future<void> _refresh({bool withApps = false}) async {
    if (!mounted) return;
    LockAgentInfo? info;
    List<LockableApp>? apps;
    String? error;
    try {
      info = await widget.registry.lockInfo(_id);
    } on Object catch (e) {
      error = '$e';
    }
    if (withApps || _apps.isEmpty) {
      try {
        apps = await widget.registry.lockableApps(_id);
      } on Object catch (e) {
        error ??= '$e';
      }
    }
    if (!mounted) return;
    setState(() {
      _info = info ?? _info;
      if (apps != null) _apps = apps;
      _readError = error;
      _loading = false;
    });
  }

  Future<void> _refreshNow() async {
    setState(() => _refreshing = true);
    await _refresh(withApps: true);
    if (mounted) setState(() => _refreshing = false);
  }

  /// Every control answers with a toast; a silent lock screen is one nobody
  /// trusts.
  Future<void> _act(
    Future<bool?> Function() action, {
    required String doing,
    required String Function() outcome,
    String Function()? refused,
  }) async {
    final entry = widget.entry;
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (entry.busy) {
      messenger.showSnackBar(
        const SnackBar(content: Text('App Lock is still on the last action.')),
      );
      return;
    }
    final answer = await action();
    await _refresh(withApps: true);
    if (!mounted) return;
    final failure = entry.error;
    final text =
        failure ??
        switch (answer) {
          true => outcome(),
          false => refused?.call() ?? '$doing did not happen.',
          null => '$doing did not happen.',
        };
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: Duration(
            seconds: answer == true && failure == null ? 5 : 12,
          ),
          backgroundColor: failure == null && answer == true
              ? null
              : scheme.error,
          action: failure == null
              ? null
              : SnackBarAction(
                  label: 'Dismiss',
                  onPressed: () => setState(() => entry.error = null),
                ),
        ),
      );
  }

  Future<void> _setPassphrase() => _act(
    () => widget.registry.setPassphrase(_id, _passA.text),
    doing: 'Storing the passphrase',
    outcome: () {
      _passA.clear();
      _passB.clear();
      return 'Saved as a salted PBKDF2 hash. The passphrase itself is not kept '
          'anywhere, and cannot be shown again.';
    },
  );

  Future<void> _checkPassphrase() => _act(
    () => widget.registry.verifyPassphrase(_id, _check.text),
    doing: 'Checking the passphrase',
    outcome: () {
      _check.clear();
      return 'That matches. The hash the agent compares against is yours.';
    },
    refused: () {
      _check.clear();
      return 'That does not match.';
    },
  );

  Future<void> _testPrompt() async {
    final target = _draft.locked.isEmpty ? null : _draft.locked.first;
    if (target == null) return;
    await _act(
      () => widget.registry.testLockPrompt(
        _id,
        target.bundleId,
        name: target.name,
      ),
      doing: 'Raising the prompt',
      outcome: () =>
          'The dialog for ${target.name} is on your screen. Answer it there — '
          'nothing typed here was sent to it.',
      refused: () =>
          'The prompt window is gone. It closes itself after a minute so an '
          'unanswered launch is not held open forever.',
    );
  }

  /// The phrase lives only in this method and the helper's stdin; it is never
  /// stored on the state.
  Future<void> _unlock(LockableApp app) async {
    final pass = await showDialog<String>(
      context: context,
      builder: (_) =>
          _PassphraseDialog(app: app, minutes: _draft.unlockMinutes),
    );
    if (pass == null || pass.isEmpty || !mounted) return;
    await _act(
      () => widget.registry.unlockApp(_id, app.bundleId, pass),
      doing: 'Opening ${app.name}',
      outcome: () =>
          '${app.name} is unlocked while it is in front. Once it has been in '
          'the background for ${_draft.unlockMinutes} min, the watcher closes '
          'it and asks for the passphrase again.',
      refused: () =>
          'That passphrase did not match, so ${app.name} is still locked. The '
          'guess was written to the agent log, not here.',
    );
  }

  Future<void> _closeNow(LockableApp app) => _act(
    () => widget.registry.closeApp(_id, app.bundleId, force: _draft.forceQuit),
    doing: 'Closing ${app.name}',
    outcome: () => '${app.name} was asked to quit.',
    refused: () => '${app.name} was not running.',
  );

  Future<void> _revoke(LockableApp app) => _act(
    () => widget.registry.revokeUnlock(_id, app.bundleId),
    doing: 'Ending the window',
    outcome: () =>
        '${app.name} is locked again on the next tick, rather than when the '
        'idle window runs out.',
  );

  Future<void> _closeAllOpen() async {
    final open = _openLocked;
    if (open.isEmpty) return;
    var closed = 0;
    for (final app in open) {
      final answer = await widget.registry.closeApp(
        _id,
        app.bundleId,
        force: _draft.forceQuit,
      );
      if (answer == true) closed++;
    }
    await _refresh(withApps: true);
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final failure = widget.entry.error;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            failure ??
                'Asked $closed of ${open.length} open locked app(s) to quit.',
          ),
          backgroundColor: failure == null ? null : scheme.error,
        ),
      );
  }

  Future<void> _save() => _act(
    () => widget.registry.saveConfig(_id, _draft),
    doing: 'Saving',
    outcome: _saveOutcome,
    refused: () =>
        'Those settings were not written. The problems are listed above.',
  );

  String _saveOutcome() {
    final live = _info;
    if (live == null) return 'Saved. The agent reads the file within a second.';
    if (live.lockedCount != _draft.locked.length) {
      return 'Saved. ${_draft.locked.length} app(s) are on the list now; the '
          'agent still holds ${live.lockedCount} until it re-reads.';
    }
    if (!live.watching) {
      return 'Saved. Nothing is watching yet, so nothing will be closed until '
          'the agent is running below.';
    }
    return 'Saved, and the watcher is enforcing it — ${_draft.blurb}.';
  }

  Future<void> _revert() async {
    await widget.registry.refresh(id: _id);
    if (!mounted) return;
    final saved = widget.entry.config;
    if (saved is! AppLockConfig) return;
    setState(() => _draft = saved);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Back to what is on disk: ${_draft.blurb}.')),
      );
  }

  List<LockableApp> get _openLocked => [
    for (final app in _info?.running ?? const <LockableApp>[])
      if (_draft.isLocked(app.bundleId)) app,
  ];

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final busy = entry.busy;
    final canEdit = entry.capabilities.can(ToolAction.configure);

    return ListenableBuilder(
      listenable: widget.registry,
      builder: (context, _) => ConsoleScaffold(
        title: 'App lock',
        loading: _loading || _refreshing,
        actions: [
          IconButton(
            tooltip: 'Ask the agent again',
            icon: const Icon(Icons.refresh),
            onPressed: _loading || _refreshing ? null : _refreshNow,
          ),
        ],
        children: [
          if (_readError != null) ...[
            FailureBanner(message: _readError!),
            const SizedBox(height: 12),
          ],
          if (entry.error != null) ...[
            FailureBanner(message: entry.error!),
            const SizedBox(height: 12),
          ],
          _LiveCard(info: _info, entry: entry, apps: _openLocked),
          const SizedBox(height: 14),
          _PassphraseCard(
            info: _info,
            busy: busy,
            canEdit: entry.capabilities.can(ToolAction.setPassphrase),
            passA: _passA,
            passB: _passB,
            check: _check,
            minPassLength: LockAgentClient.minPassLength,
            onSet: _setPassphrase,
            onCheck: _checkPassphrase,
            onTest: _testPrompt,
            hasTarget: _draft.locked.isNotEmpty,
            openNote: _openNote,
            onShowNote: _toggleNote,
          ),
          const SizedBox(height: 14),
          _AppListCard(
            apps: _apps,
            draft: _draft,
            info: _info,
            busy: busy,
            canEdit: canEdit,
            query: _query,
            onQuery: (value) => setState(() => _query = value),
            onCloseAll: _closeAllOpen,
            onToggle: _toggleApp,
            onUnlock: _unlock,
            onClose: _closeNow,
            onRevoke: _revoke,
          ),
          const SizedBox(height: 14),
          _RulesCard(
            draft: _draft,
            busy: busy,
            canEdit: canEdit,
            onChanged: (next) => setState(() => _draft = next),
            onRevert: _revert,
          ),
          const SizedBox(height: 14),
          ActionBar(
            primary: _saveAction(busy, canEdit),
            secondary: [
              _agentAction(busy, _info),
              if (entry.capabilities.can(ToolAction.update))
                _updateAction(busy),
              _logsAction(context),
            ],
            openNote: _openNote,
            onShowNote: _toggleNote,
          ),
          const SizedBox(height: 14),
          if (entry.capabilities.support != Support.full)
            CapabilityNotice(capabilities: entry.capabilities),
          const SizedBox(height: 10),
          Text(
            'Enforced by toolshed-lockd as uid ${_info?.uid ?? 0}, one '
            'LaunchAgent per user. It reacts to a launch and asks the app to '
            'quit; it cannot stop the system from starting one, so a locked app '
            'opens for a moment first. Anyone who can delete '
            '~/Library/LaunchAgents can unlock it, and a passphrase that cannot '
            'be hashed cannot be recovered.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _toggleNote(String key) =>
      setState(() => _openNote = _openNote == key ? null : key);

  void _toggleApp(LockableApp app, bool on) {
    setState(() => _draft = _draft.withApp(app.asLocked(), on: on));
  }

  BarAction _saveAction(bool busy, bool canEdit) {
    final problems = _draft.problems;
    final blocked = switch ((canEdit, busy, problems.isEmpty)) {
      (false, _, _) =>
        'This tool cannot write its settings — '
            '${widget.entry.capabilities.reason}',
      (true, true, _) => 'App Lock is still on the last action.',
      (true, false, false) => problems.first,
      (true, false, true) => null,
    };
    return BarAction(
      key: 'save',
      label: 'Save the lock',
      icon: Icons.lock_outline,
      note:
          'Writes app_lock.json. The watcher notices the file changed and '
          're-reads it within about a second, so saving needs no restart and '
          'keeps every open unlock window. Nothing moves until this is pressed.',
      onPressed: blocked == null ? _save : null,
      blocked: blocked,
    );
  }

  /// One button for the agent's whole life cycle; the three states are never
  /// simultaneous.
  BarAction _agentAction(bool busy, LockAgentInfo? info) {
    final caps = widget.entry.capabilities;
    final watching = info?.watching ?? false;
    if (caps.can(ToolAction.install)) {
      return BarAction(
        key: 'agent',
        label: 'Install agent',
        icon: Icons.download_outlined,
        tone: BarTone.tonal,
        note:
            'Copies toolshed-lockd into Application Support and writes a '
            'per-user LaunchAgent, then bootstraps it. No administrator '
            'password: it only touches apps in your own session, and it '
            'respawns itself at every login from then on.',
        onPressed: busy
            ? null
            : () => _act(
                () => widget.registry.install(_id),
                doing: 'Installing',
                outcome: () =>
                    'The watcher is running. Locked apps will be closed when '
                    'they launch.',
              ),
        blocked: busy ? 'App Lock is still on the last action.' : null,
      );
    }
    if (caps.can(ToolAction.stop)) {
      return BarAction(
        key: 'agent',
        label: 'Stop agent',
        icon: Icons.stop_circle_outlined,
        tone: BarTone.tonal,
        note: watching
            ? 'Boots the agent out of launchd. It stops closing things '
                  'immediately and the lock list is kept, so this is a pause '
                  'rather than a reset. Never a plain kill: KeepAlive would '
                  'respawn it.'
            : 'The agent is not running, so there is nothing to stop.',
        onPressed: busy || !watching
            ? null
            : () => _act(
                () => widget.registry.stop(_id),
                doing: 'Stopping',
                outcome: () =>
                    'Stopped. Locked apps stay open until it is started again.',
              ),
        blocked: busy
            ? 'App Lock is still on the last action.'
            : watching
            ? null
            : 'The watcher is already stopped.',
      );
    }
    if (caps.can(ToolAction.start)) {
      return BarAction(
        key: 'agent',
        label: 'Start agent',
        icon: Icons.play_arrow_rounded,
        tone: BarTone.tonal,
        note:
            'Bootstraps the installed plist into the gui domain and waits for '
            'launchd to report it running. Everything on this screen already '
            'works without it — this is what keeps working after the next '
            'launch.',
        onPressed: busy
            ? null
            : () => _act(
                () => widget.registry.start(_id),
                doing: 'Starting',
                outcome: () =>
                    'Running. ${_openLocked.length} locked app(s) were open '
                    'when it came up.',
              ),
        blocked: busy ? 'App Lock is still on the last action.' : null,
      );
    }
    return BarAction(
      key: 'agent',
      label: 'Install agent',
      icon: Icons.download_outlined,
      tone: BarTone.tonal,
      note: 'Needs the native helper.',
      onPressed: null,
      blocked: caps.reason,
    );
  }

  BarAction _updateAction(bool busy) => BarAction(
    key: 'update',
    label: 'Update agent',
    icon: Icons.system_update_alt,
    tone: BarTone.tonal,
    note:
        'Copies the toolshed-lockd this app carries over the installed one and '
        'restarts the watcher on it. The agent runs the binary it started with, '
        'so this is how an updated toolshed reaches the lock. Your list, '
        'passphrase and open windows are kept.',
    onPressed: busy
        ? null
        : () => _act(
            () => widget.registry.updateAgent(_id),
            doing: 'Updating the agent',
            outcome: () =>
                'The watcher is running the helper this app carries.',
          ),
    blocked: busy ? 'App Lock is still on the last action.' : null,
  );

  BarAction _logsAction(BuildContext context) => BarAction(
    key: 'logs',
    label: 'Agent log',
    icon: Icons.receipt_long_outlined,
    tone: BarTone.outlined,
    note:
        'Follows ~/Library/Logs/toolshed-lockd.log — every close, every '
        'passphrase answer, every refused guard case. This is the only record '
        'of what the lock did while you were not looking at it.',
    onPressed: widget.entry.capabilities.can(ToolAction.tailLogs)
        ? () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => LogsPanel(registry: widget.registry, id: _id),
            ),
          )
        : null,
    blocked: widget.entry.capabilities.can(ToolAction.tailLogs)
        ? null
        : 'There is no helper to have written a log.',
  );
}

class _LiveCard extends StatelessWidget {
  const _LiveCard({
    required this.info,
    required this.entry,
    required this.apps,
  });

  final LockAgentInfo? info;
  final ToolEntry entry;
  final List<LockableApp> apps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = entry.status ?? const AgentStatus(state: AgentState.unknown);
    final tone = statusTone(status.state, scheme);
    final live = info;
    final now = DateTime.now();
    final events = live == null
        ? const <LockEvent>[]
        : live.events.reversed.take(4).toList(growable: false);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge(icon: tone.icon, color: tone.foreground, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    live == null
                        ? 'Asking the helper…'
                        : live.isEnforcing
                        ? 'Locking ${live.lockedCount} app(s)'
                        : 'The lock is not enforcing',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(label: status.label, color: tone.foreground),
              ],
            ),
            const SizedBox(height: 10),
            if (live != null && live.watching)
              FactRow(
                icon: Icons.visibility_outlined,
                text:
                    'Watcher alive, pid ${live.watchPid}. It reacts to a '
                    'launch within a couple of seconds and re-checks every 5.',
              )
            else if (live != null)
              const FactRow(
                icon: Icons.visibility_off_outlined,
                text:
                    'No watcher process. The list and the passphrase are '
                    'saved, and nothing closes until it is running.',
              ),
            if (live != null)
              FactRow(
                icon: live.passphraseSet
                    ? Icons.key_outlined
                    : Icons.key_off_outlined,
                text: live.passphraseSet
                    ? 'Passphrase set · ${live.iterations} PBKDF2 rounds, '
                          'salted and stored at 0600. It cannot be read back.'
                    : 'No passphrase. The agent leaves every locked app alone '
                          'rather than closing it with nothing to reopen it.',
              ),
            if (apps.isNotEmpty)
              for (final app in apps)
                FactRow(
                  icon: Icons.apps_outlined,
                  text:
                      '${app.name} is open'
                      '${app.remaining(now) != null ? ' · locks after ${_left(app.remaining(now)!)} idle' : ', and would be closed'}',
                ),
            if (live != null && live.gap.isNotEmpty) ...[
              const SizedBox(height: 8),
              BlockedLine(text: live.gap),
            ],
            if (events.isNotEmpty) ...[
              const SizedBox(height: 12),
              const SectionLabel('Last moves'),
              for (final event in events)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${_clock(event.time)}  ${event.action}  '
                    '${event.detail.isEmpty ? event.bundleId : event.detail}',
                    style: AppTheme.mono(
                      theme.textTheme.bodySmall,
                    )?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PassphraseCard extends StatelessWidget {
  const _PassphraseCard({
    required this.info,
    required this.busy,
    required this.canEdit,
    required this.passA,
    required this.passB,
    required this.check,
    required this.minPassLength,
    required this.onSet,
    required this.onCheck,
    required this.onTest,
    required this.hasTarget,
    required this.openNote,
    required this.onShowNote,
  });

  final LockAgentInfo? info;
  final bool busy;
  final bool canEdit;
  final TextEditingController passA;
  final TextEditingController passB;
  final TextEditingController check;
  final int minPassLength;
  final VoidCallback onSet;
  final VoidCallback onCheck;
  final VoidCallback onTest;
  final bool hasTarget;
  final String? openNote;
  final ValueChanged<String> onShowNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final set = info?.passphraseSet ?? false;
    final typed = passA.text;
    final confirm = passB.text;
    final short = typed.length < minPassLength;
    final mismatch = typed != confirm;
    final setBlock = switch ((canEdit, busy, short || mismatch)) {
      (false, _, _) => 'There is no helper to hash it with.',
      (true, true, _) => 'App Lock is still on the last action.',
      (true, false, true) =>
        typed.isEmpty
            ? 'Type the passphrase twice.'
            : short
            ? 'Under $minPassLength characters is decoration, not a lock.'
            : 'The two fields have to agree.',
      (true, false, false) => null,
    };
    final checkBlock = switch ((canEdit, busy, check.text.isEmpty)) {
      (false, _, _) => 'There is no helper to check against.',
      (true, true, _) => 'App Lock is still on the last action.',
      (true, false, true) => 'Type something to check.',
      (true, false, false) => null,
    };
    final testBlock = hasTarget && !busy && set
        ? null
        : !set
        ? 'Set a passphrase first — the prompt has nothing to compare against.'
        : !hasTarget
        ? 'Nothing is locked, so there is no app to prompt for.'
        : 'App Lock is still on the last action.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionLabel(set ? 'Passphrase · set' : 'Passphrase · not set'),
            Text(
              set
                  ? 'The dialog asks for this phrase when a locked app tries '
                        'to open. The agent stores a salted hash, not the '
                        'words, so it can answer yes or no but cannot recover '
                        'them. A new phrase replaces the old; it does not open '
                        'an app that is already closed.'
                  : 'Pick the phrase you will type to open a locked app. The '
                        'agent keeps only a salted hash, so the words cannot be '
                        'read back or reset — forgetting it means uninstalling '
                        'the agent to get back in. Use at least '
                        '$minPassLength characters. Nothing is closed until '
                        'this is saved.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _PassField(
              field: passA,
              label: set ? 'New passphrase' : 'Passphrase',
              hint: 'At least $minPassLength characters',
            ),
            const SizedBox(height: 10),
            _PassField(field: passB, label: 'Type it again', hint: 'Confirm'),
            const SizedBox(height: 10),
            _PassField(
              field: check,
              label: 'Check a passphrase',
              hint: set ? 'Type a phrase to test' : 'Nothing stored yet',
              enabled: set,
            ),
            const SizedBox(height: 14),
            ActionBar(
              primary: BarAction(
                key: 'setpass',
                label: set ? 'Replace passphrase' : 'Save passphrase',
                icon: Icons.key_outlined,
                note:
                    'Sends it to toolshed-lockd on stdin — never an argument, '
                    'because ps shows argv to every process on the machine — '
                    'and stores only a random salt and a PBKDF2 hash in a 0600 '
                    'file. The Dart side never sees the hash and cannot show '
                    'you the phrase again.',
                onPressed: setBlock == null ? onSet : null,
                blocked: setBlock,
              ),
              secondary: [
                BarAction(
                  key: 'check',
                  label: 'Check it',
                  icon: Icons.fact_check_outlined,
                  tone: BarTone.outlined,
                  note:
                      'Asks the helper whether this phrase hashes to the '
                      'stored one. The answer is yes or no; the phrase is '
                      'discarded either way.',
                  onPressed: checkBlock == null ? onCheck : null,
                  blocked: checkBlock,
                ),
                BarAction(
                  key: 'prompt',
                  label: 'Test the prompt',
                  icon: Icons.chat_bubble_outline,
                  tone: BarTone.outlined,
                  note:
                      'Raises the real dialog for the first locked app, the '
                      'same window the watcher raises on a launch. A matching '
                      'phrase opens the app until it has been idle for the '
                      'unlock window; a wrong phrase leaves it closed. The '
                      'dialog waits a minute, then goes away unanswered — an '
                      'app should not be held closed by a dialog nobody is '
                      'looking at.',
                  onPressed: testBlock == null ? onTest : null,
                  blocked: testBlock,
                ),
              ],
              openNote: openNote,
              onShowNote: onShowNote,
            ),
          ],
        ),
      ),
    );
  }
}

class _PassField extends StatelessWidget {
  const _PassField({
    required this.field,
    required this.label,
    required this.hint,
    this.enabled = true,
  });

  final TextEditingController field;
  final String label;
  final String hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: field,
      obscureText: true,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        helperText: enabled ? null : 'Set a passphrase first',
      ),
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }
}

class _AppListCard extends StatelessWidget {
  const _AppListCard({
    required this.apps,
    required this.draft,
    required this.info,
    required this.busy,
    required this.canEdit,
    required this.query,
    required this.onQuery,
    required this.onCloseAll,
    required this.onToggle,
    required this.onUnlock,
    required this.onClose,
    required this.onRevoke,
  });

  final List<LockableApp> apps;
  final AppLockConfig draft;
  final LockAgentInfo? info;
  final bool busy;
  final bool canEdit;
  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onCloseAll;
  final void Function(LockableApp app, bool on) onToggle;
  final Future<void> Function(LockableApp app) onUnlock;
  final Future<void> Function(LockableApp app) onClose;
  final Future<void> Function(LockableApp app) onRevoke;

  static const _rowCap = 60;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final needle = query.trim().toLowerCase();
    final rows = [
      for (final app in apps)
        if (needle.isEmpty ||
            app.name.toLowerCase().contains(needle) ||
            app.bundleId.toLowerCase().contains(needle))
          app,
    ]..sort(_priority);
    final shown = rows.take(_rowCap).toList(growable: false);
    final open = [
      for (final app in apps)
        if (draft.isLocked(app.bundleId) && app.running) app,
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SectionLabel('Apps · ${draft.locked.length} locked'),
                ),
                if (open.isNotEmpty)
                  TextButton.icon(
                    onPressed: busy ? null : onCloseAll,
                    icon: const Icon(Icons.close_fullscreen_outlined, size: 18),
                    label: Text('Close all ${open.length} now'),
                  ),
              ],
            ),
            TextField(
              onChanged: onQuery,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Filter by name or bundle id',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Desktop apps only. Menu-bar extras and background agents have '
              'no window to close, and the system apps the agent never closes '
              '(Finder, the Dock, toolshed) are left off the list entirely.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (apps.isEmpty)
              Text(
                info == null
                    ? 'Asking the helper what is installed…'
                    : 'The helper answered with no apps, so it cannot see '
                          'LaunchServices. Rebuild it with `make lockd`.',
                style: theme.textTheme.bodySmall,
              ),
            for (final app in shown)
              _AppRow(
                app: app,
                draft: draft,
                now: now,
                busy: busy,
                canEdit: canEdit,
                onToggle: onToggle,
                onUnlock: onUnlock,
                onClose: onClose,
                onRevoke: onRevoke,
              ),
            if (rows.length > shown.length)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${rows.length - shown.length} more match. Keep typing — '
                  'this list stops at $_rowCap rows so the page stays scannable.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Locked and running first, then running, locked, alphabetical.
  static int _priority(LockableApp a, LockableApp b) {
    int rank(LockableApp app) => (app.locked && app.running
        ? 0
        : app.running
        ? 1
        : app.locked
        ? 2
        : 3);
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0
        ? byRank
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.draft,
    required this.now,
    required this.busy,
    required this.canEdit,
    required this.onToggle,
    required this.onUnlock,
    required this.onClose,
    required this.onRevoke,
  });

  final LockableApp app;
  final AppLockConfig draft;
  final DateTime now;
  final bool busy;
  final bool canEdit;
  final void Function(LockableApp app, bool on) onToggle;
  final Future<void> Function(LockableApp app) onUnlock;
  final Future<void> Function(LockableApp app) onClose;
  final Future<void> Function(LockableApp app) onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locked = draft.isLocked(app.bundleId);
    final guard = AppLockConfig.guardedBundleIds[app.bundleId];
    final left = app.remaining(now);
    final allowed = app.unlockedUntil != null && left != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: locked
            ? scheme.errorContainer.withValues(alpha: 0.22)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
      ),
      child: Row(
        children: [
          Checkbox(
            value: locked,
            onChanged: !canEdit || guard != null || busy
                ? null
                : (on) => onToggle(app, on ?? false),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.name.isEmpty ? app.bundleId : app.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  guard != null
                      ? 'Never closed by the agent — $guard.'
                      : app.bundleId,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: guard != null
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (app.running || allowed || !app.lockable)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        if (app.running)
                          TagChip(
                            label: 'pid ${app.pid ?? 0}',
                            color: scheme.tertiary,
                          ),
                        if (allowed)
                          TagChip(
                            label: 'locks after ${_left(left)}',
                            color: statusTone(
                              AgentState.running,
                              scheme,
                            ).foreground,
                          ),
                        if (!app.lockable && guard == null)
                          TagChip(label: 'refused', color: scheme.error),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (locked && app.running && !allowed)
            IconButton(
              tooltip: 'Close it now',
              icon: const Icon(Icons.close_fullscreen_outlined, size: 20),
              onPressed: busy ? null : () => onClose(app),
            ),
          if (locked && allowed)
            IconButton(
              tooltip: 'End the window now',
              icon: const Icon(Icons.timer_off_outlined, size: 20),
              onPressed: busy ? null : () => onRevoke(app),
            ),
          if (locked && !app.running && !allowed)
            IconButton(
              tooltip: 'Allow it open until it goes idle',
              icon: const Icon(Icons.lock_open_outlined, size: 20),
              onPressed: busy ? null : () => onUnlock(app),
            ),
        ],
      ),
    );
  }
}

class _RulesCard extends StatelessWidget {
  const _RulesCard({
    required this.draft,
    required this.busy,
    required this.canEdit,
    required this.onChanged,
    required this.onRevert,
  });

  final AppLockConfig draft;
  final bool busy;
  final bool canEdit;
  final ValueChanged<AppLockConfig> onChanged;
  final VoidCallback onRevert;

  static const _windows = <int>[1, 5, 15, 30, 60, 240];

  static String _windowLabel(int minutes) =>
      minutes >= 60 ? '${minutes ~/ 60} h' : '$minutes min';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final problems = draft.problems;
    final edit = canEdit && !busy ? onChanged : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: SectionLabel('Rules')),
                TextButton.icon(
                  onPressed: busy ? null : onRevert,
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('Undo my edits'),
                ),
              ],
            ),
            SwitchListTile(
              value: draft.enabled,
              onChanged: edit == null
                  ? null
                  : (on) => onChanged(draft.copyWith(enabled: on)),
              title: const Text('Lock is on'),
              subtitle: Text(
                draft.enabled
                    ? 'The watcher closes a locked app the moment it notices '
                          'the launch.'
                    : 'Paused. The list, the passphrase and the agent all stay '
                          'as they are; nothing is closed.',
                style: theme.textTheme.bodySmall,
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const FieldGroup('Lock again after this much inactivity'),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final minutes in _windows)
                  ChoiceChip(
                    label: Text(_windowLabel(minutes)),
                    selected: draft.unlockMinutes == minutes,
                    onSelected: edit == null
                        ? null
                        : (_) =>
                              onChanged(draft.copyWith(unlockMinutes: minutes)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'The passphrase keeps an app open while you are using it. Only '
              'time spent away from the app counts, so it is closed and asks '
              'again after ${_windowLabel(draft.unlockMinutes)} in the '
              'background.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (!_windows.contains(draft.unlockMinutes))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Saved as ${draft.unlockMinutes} min, which is between the '
                  'chips.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const FieldGroup('How hard a close is'),
            SwitchListTile(
              value: draft.forceQuit,
              onChanged: edit == null
                  ? null
                  : (on) => onChanged(draft.copyWith(forceQuit: on)),
              title: const Text('Force quit after three seconds'),
              subtitle: Text(
                draft.forceQuit
                    ? 'An app that ignores the quit request is killed. '
                          'Unsaved work in it is lost.'
                    : 'The app gets the same request ⌘Q sends, so it can put '
                          'up its own save dialog. One that refuses to quit '
                          'stays open until the next tick.',
                style: theme.textTheme.bodySmall,
              ),
              contentPadding: EdgeInsets.zero,
            ),
            if (problems.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final problem in problems) BlockedLine(text: problem),
            ],
          ],
        ),
      ),
    );
  }
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.app, required this.minutes});

  final LockableApp app;
  final int minutes;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final TextEditingController _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Open ${widget.app.name}'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'While you use it the watcher leaves it alone. After '
              '${widget.minutes} min in the background it closes it and asks '
              'for the passphrase again.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _field,
              obscureText: true,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Passphrase',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _field.text.isEmpty ? null : _submit,
          child: const Text('Open it'),
        ),
      ],
    );
  }

  void _submit() => Navigator.of(context).pop(_field.text);
}

String _clock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}:'
    '${time.second.toString().padLeft(2, '0')}';

String _left(Duration left) {
  if (left.inMinutes >= 60) {
    return '${(left.inMinutes / 60).toStringAsFixed(1)} h';
  }
  if (left.inMinutes >= 1) return '${left.inMinutes} min';
  return '${left.inSeconds}s';
}

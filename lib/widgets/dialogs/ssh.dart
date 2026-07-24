import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/app_state.dart';
import '../../services/rust_bridge.dart';
import '../polished_dropdown.dart';
import 'keyboard_safe_dialog.dart';

class SshDialog extends StatelessWidget {
  const SshDialog({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox();

  static void show(BuildContext context) {
    final app = context.read<AppState>();
    final hostCtrl = TextEditingController(text: app.sshHost);
    final portCtrl = TextEditingController(text: app.sshPort.toString());
    final userCtrl = TextEditingController(text: app.sshUser);
    final passCtrl = TextEditingController(text: app.sshPass);
    final keyCtrl = TextEditingController(text: app.sshIdentity);
    final hostFocus = FocusNode(debugLabel: 'ssh-host');
    final userFocus = FocusNode(debugLabel: 'ssh-user');
    final portFocus = FocusNode(debugLabel: 'ssh-port');
    final passFocus = FocusNode(debugLabel: 'ssh-password');
    final keyFocus = FocusNode(debugLabel: 'ssh-identity');
    var mode = app.sshMode;
    var testing = false;
    var result = ''; // 'ok' or error message

    Future<void> testConnection(
      void Function(void Function()) setState,
      BuildContext ctx,
    ) async {
      setState(() {
        testing = true;
        result = '';
      });
      try {
        if (hostCtrl.text.isEmpty) {
          setState(() {
            testing = false;
            result = 'Host is required';
          });
          return;
        }
        final settingsJson = jsonEncode({
          'host': hostCtrl.text,
          'port': int.tryParse(portCtrl.text) ?? 22,
          'user': userCtrl.text,
          'password': passCtrl.text,
          'identity_file': keyCtrl.text,
          'mode': mode
        });
        final resp = RustBridge.instance.sshT(settingsJson);
        final json = _tryJson(resp);
        if (!ctx.mounted) return;
        if (json is Map && json['ok'] == true) {
          setState(() {
            testing = false;
            result = 'ok';
          });
        } else {
          final error = json is Map ? json['error']?.toString() ?? resp : resp;
          setState(() {
            testing = false;
            result = error;
          });
          app.reportNetworkPermissionFailure(
            error,
            retry: () => testConnection(setState, ctx),
          );
        }
      } catch (e) {
        if (!ctx.mounted) return;
        setState(() {
          testing = false;
          result = '$e';
        });
        app.reportNetworkPermissionFailure(
          e,
          retry: () => testConnection(setState, ctx),
        );
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DialogResourceOwner(
        onDispose: () {
          hostCtrl.dispose();
          portCtrl.dispose();
          userCtrl.dispose();
          passCtrl.dispose();
          keyCtrl.dispose();
          hostFocus.dispose();
          userFocus.dispose();
          portFocus.dispose();
          passFocus.dispose();
          keyFocus.dispose();
        },
        child: StatefulBuilder(builder: (ctx, setState) {
          return KeyboardSafeDialog(
            maxWidth: 420,
            title: const Text('SSH Tunnel'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              if (testing)
                const Row(children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('Testing...')
                ]),
              if (!testing && result == 'ok')
                const Text('Connection OK',
                    style: TextStyle(color: Colors.green)),
              if (!testing && result.isNotEmpty && result != 'ok')
                SelectableText('Error: $result',
                    style: const TextStyle(fontSize: 13, color: Colors.red)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Mode',
                  style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const SizedBox(height: 6),
              PolishedDropdown<int>(
                key: const ValueKey('ssh-mode-dropdown'),
                id: 'ssh-mode',
                value: mode,
                leadingIcon: Icons.route_rounded,
                minimumMenuWidth: 260,
                options: const [
                  PolishedDropdownOption(
                    value: 0,
                    label: 'Disabled',
                    icon: Icons.block_rounded,
                  ),
                  PolishedDropdownOption(
                    value: 1,
                    label: 'Auto (direct first)',
                    icon: Icons.alt_route_rounded,
                  ),
                  PolishedDropdownOption(
                    value: 2,
                    label: 'Always SSH',
                    icon: Icons.vpn_lock_rounded,
                  ),
                ],
                onChanged: (value) => setState(() => mode = value),
              ),
              TextField(
                  key: const ValueKey('ssh-host'),
                  controller: hostCtrl,
                  focusNode: hostFocus,
                  decoration: const InputDecoration(
                      labelText: 'Host', hintText: 'ssh.example.com'),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => focusAndShowKeyboard(ctx, userFocus)),
              Row(children: [
                Expanded(
                    flex: 3,
                    child: TextField(
                        key: const ValueKey('ssh-user'),
                        controller: userCtrl,
                        focusNode: userFocus,
                        decoration: const InputDecoration(labelText: 'User'),
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        onSubmitted: (_) =>
                            focusAndShowKeyboard(ctx, passFocus))),
                const SizedBox(width: 8),
                Expanded(
                    flex: 1,
                    child: TextField(
                        key: const ValueKey('ssh-port'),
                        controller: portCtrl,
                        focusNode: portFocus,
                        decoration: const InputDecoration(labelText: 'Port'),
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) =>
                            focusAndShowKeyboard(ctx, passFocus))),
              ]),
              TextField(
                  key: const ValueKey('ssh-password'),
                  controller: passCtrl,
                  focusNode: passFocus,
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  onTap: () => focusAndShowKeyboard(ctx, passFocus),
                  onSubmitted: (_) => testConnection(setState, ctx)),
              Row(children: [
                Expanded(
                    child: TextField(
                        key: const ValueKey('ssh-identity'),
                        controller: keyCtrl,
                        focusNode: keyFocus,
                        decoration: const InputDecoration(
                            labelText: 'Identity File',
                            hintText: '~/.ssh/id_ed25519'))),
                const SizedBox(width: 4),
                OutlinedButton(
                    onPressed: () async {
                      final r = await FilePicker.platform.pickFiles();
                      if (r != null && r.files.single.path != null) {
                        keyCtrl.text = r.files.single.path!;
                      }
                    },
                    child: const Text('Browse')),
              ]),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              OutlinedButton(
                  onPressed:
                      testing ? null : () => testConnection(setState, ctx),
                  child: const Text('Test')),
              FilledButton(
                  onPressed: () {
                    app.setSshHost(hostCtrl.text);
                    app.setSshPort(int.tryParse(portCtrl.text) ?? 22);
                    app.setSshUser(userCtrl.text);
                    app.setSshPass(passCtrl.text);
                  app.setSshIdentity(keyCtrl.text);
                    app.sshMode = mode;
                    app.setSshTestResult(result == 'ok' && mode > 0);
                    app.setStatus(result == 'ok'
                        ? 'SSH test passed; tunnel will light up when used'
                        : 'SSH settings saved');
                    Navigator.pop(ctx);
                  },
                  child: const Text('Save')),
            ],
          );
        }),
      ),
    );
  }

  static dynamic _tryJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return s;
    }
  }
}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/app_state.dart';
import '../../services/rust_bridge.dart';
import '../dropdown_items.dart';

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
    var mode = app.sshMode;
    var testing = false;
    var result = ''; // 'ok' or error message

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
        final screenHeight = MediaQuery.of(ctx).size.height;
        final maxDialogHeight = screenHeight - bottomInset - 48;

        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: 400, maxHeight: maxDialogHeight.clamp(200, 600)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 20, 24, 0),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('SSH Tunnel',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w500))),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                            style: const TextStyle(
                                fontSize: 13, color: Colors.red)),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int>(
                        initialValue: mode,
                        decoration: const InputDecoration(labelText: 'Mode'),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface),
                        dropdownColor: Theme.of(context).colorScheme.surface,
                        selectedItemBuilder: (_) => const [
                          'Disabled',
                          'Auto (direct first)',
                          'Always SSH',
                        ]
                            .map((label) => Align(
                                alignment: Alignment.centerLeft,
                                child: Text(label)))
                            .toList(),
                        items: [
                          for (var index = 0; index < 3; index++)
                            DropdownMenuItem(
                              value: index,
                              child: separatedDropdownItem(
                                ctx,
                                isLast: index == 2,
                                child: Text(
                                  const [
                                    'Disabled',
                                    'Auto (direct first)',
                                    'Always SSH'
                                  ][index],
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface),
                                ),
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => mode = v);
                        },
                      ),
                      TextField(
                          controller: hostCtrl,
                          decoration: const InputDecoration(
                              labelText: 'Host', hintText: 'ssh.example.com')),
                      Row(children: [
                        Expanded(
                            flex: 3,
                            child: TextField(
                                controller: userCtrl,
                                decoration:
                                    const InputDecoration(labelText: 'User'))),
                        const SizedBox(width: 8),
                        Expanded(
                            flex: 1,
                            child: TextField(
                                controller: portCtrl,
                                decoration:
                                    const InputDecoration(labelText: 'Port'),
                                keyboardType: TextInputType.number)),
                      ]),
                      TextField(
                          controller: passCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Password'),
                          obscureText: true),
                      Row(children: [
                        Expanded(
                            child: TextField(
                                controller: keyCtrl,
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
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child:
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                        onPressed: testing
                            ? null
                            : () async {
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
                                  final resp =
                                      RustBridge.instance.sshT(settingsJson);
                                  final json = _tryJson(resp);
                                  if (json is Map && json['ok'] == true) {
                                    setState(() {
                                      testing = false;
                                      result = 'ok';
                                    });
                                  } else {
                                    setState(() {
                                      testing = false;
                                      result = json is Map
                                          ? json['error']?.toString() ?? resp
                                          : resp;
                                    });
                                  }
                                } catch (e) {
                                  setState(() {
                                    testing = false;
                                    result = '$e';
                                  });
                                }
                              },
                        child: const Text('Test')),
                    const SizedBox(width: 8),
                    FilledButton(
                        onPressed: () {
                          app.setSshHost(hostCtrl.text);
                          app.setSshPort(int.tryParse(portCtrl.text) ?? 22);
                          app.setSshUser(userCtrl.text);
                          app.setSshPass(passCtrl.text);
                          app.setSshIdentity(keyCtrl.text);
                          app.sshMode = mode;
                          app.setSshConnected(result == 'ok');
                          app.setStatus(result == 'ok'
                              ? 'SSH connected'
                              : 'SSH settings saved');
                          Navigator.pop(ctx);
                        },
                        child: const Text('Save')),
                  ]),
                ),
              ],
            ),
          ),
        );
      }),
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

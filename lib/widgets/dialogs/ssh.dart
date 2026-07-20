import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/app_state.dart';
import '../../services/rust_bridge.dart';

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
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => AlertDialog(
        title: const Text('SSH Tunnel'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (testing) const Row(children: [SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 8), Text('Testing...')]),
          if (!testing && result == 'ok') const Text('Connection OK', style: TextStyle(color: Colors.green)),
          if (!testing && result.isNotEmpty && result != 'ok') SelectableText('Error: $result', style: const TextStyle(fontSize: 13, color: Colors.red)),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            value: mode,
            decoration: const InputDecoration(labelText: 'Mode'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('Disabled')),
              DropdownMenuItem(value: 1, child: Text('Auto (direct first)')),
              DropdownMenuItem(value: 2, child: Text('Always SSH')),
            ],
            onChanged: (v) { if (v != null) setState(() => mode = v); },
          ),
          TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: 'Host', hintText: 'ssh.example.com')),
          Row(children: [
            Expanded(flex: 3, child: TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'User'))),
            const SizedBox(width: 8),
            Expanded(flex: 1, child: TextField(controller: portCtrl, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number)),
          ]),
          TextField(controller: passCtrl, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
          Row(children: [
            Expanded(child: TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: 'Identity File', hintText: '~/.ssh/id_ed25519'))),
            const SizedBox(width: 4),
            OutlinedButton(onPressed: () async {
              final r = await FilePicker.platform.pickFiles();
              if (r != null && r.files.single.path != null) {
                keyCtrl.text = r.files.single.path!;
              }
            }, child: const Text('Browse')),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          OutlinedButton(onPressed: testing ? null : () async {
            setState(() { testing = true; result = ''; });
            try {
              final settingsJson = '{"host":"${hostCtrl.text}","port":${int.tryParse(portCtrl.text)??22},"user":"${userCtrl.text}","password":"${passCtrl.text}","identity_file":"${keyCtrl.text}"}';
              final resp = RustBridge.instance.sshTest(settingsJson);
              final json = _tryJson(resp);
              if (json is Map && json['ok'] == true) {
                setState(() { testing = false; result = 'ok'; });
              } else {
                setState(() { testing = false; result = json is Map ? json['error']?.toString() ?? resp : resp; });
              }
            } catch (e) {
              setState(() { testing = false; result = '$e'; });
            }
          }, child: const Text('Test Connection')),
          FilledButton(onPressed: () {
            app.setSshHost(hostCtrl.text);
            app.setSshPort(int.tryParse(portCtrl.text)??22);
            app.setSshUser(userCtrl.text);
            app.setSshPass(passCtrl.text);
            app.setSshIdentity(keyCtrl.text);
            app.sshMode = mode;
            app.setSshConnected(result == 'ok');
            app.setStatus(result == 'ok' ? 'SSH connected' : 'SSH settings saved');
            Navigator.pop(ctx);
          }, child: const Text('Save')),
        ],
      )),
    );
  }

  static dynamic _tryJson(String s) { try { return jsonDecode(s); } catch (_) { return s; } }
}

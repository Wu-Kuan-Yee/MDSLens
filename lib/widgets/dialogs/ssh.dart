import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';

class SshDialog extends StatelessWidget {
  const SshDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox();
  }

  static void show(BuildContext context) {
    final app = context.read<AppState>();
    final hostCtrl = TextEditingController(text: app.sshHost);
    final userCtrl = TextEditingController(text: app.sshUser);
    final passCtrl = TextEditingController(text: app.sshPass);
    final keyCtrl = TextEditingController(text: app.sshIdentity);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('SSH Tunnel'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: 'Host')),
          Row(children: [
            Expanded(child: TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'User'))),
            const SizedBox(width: 8),
            SizedBox(width: 80, child: TextField(controller: TextEditingController(text: '${app.sshPort}'), decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number)),
          ]),
          TextField(controller: passCtrl, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
          TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: 'Identity File', hintText: '~/.ssh/id_ed25519')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          OutlinedButton(onPressed: () {
            // TODO: call Rust SSH test
          }, child: const Text('Test Connection')),
          FilledButton(onPressed: () {
            app.setSshHost(hostCtrl.text);
            app.setSshUser(userCtrl.text);
            app.setSshPass(passCtrl.text);
            app.setSshIdentity(keyCtrl.text);
            Navigator.pop(ctx);
          }, child: const Text('Save')),
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../services/rust_bridge.dart';

class LoginDialog extends StatelessWidget {
  const LoginDialog({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox();

  static void show(BuildContext context) {
    final app = context.read<AppState>();
    final apiCtrl = TextEditingController(text: app.loginApiUrl);
    final userCtrl = TextEditingController(text: app.loginUser);
    final passCtrl = TextEditingController(text: app.loginPass);
    var loading = false;
    var error = '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => AlertDialog(
        title: Text(loading ? 'Login — Connecting...' : 'Login — EAST API'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (error.isNotEmpty) SelectableText(error, style: const TextStyle(color: Colors.red, fontSize: 13)),
          if (error.isNotEmpty) const SizedBox(height: 8),
          if (loading)
            const Row(children: [SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 12), Text('Logging in...')])
          else ...[
            TextField(controller: apiCtrl, decoration: const InputDecoration(labelText: 'API URL')),
            TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'Username')),
            TextField(controller: passCtrl, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
          ],
        ]),
        actions: loading ? [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ] : [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () async {
            final url = apiCtrl.text.trim();
            final user = userCtrl.text.trim();
            final pass = passCtrl.text.trim();
            if (url.isEmpty || user.isEmpty) {
              setState(() => error = 'Fill API URL and Username');
              return;
            }
            setState(() { loading = true; error = ''; });
            try {
              final token = await _login(url, user, pass, app);
              app.setLoginApiUrl(url);
              app.setLoginUser(user);
              app.setLoginPass(pass);
              app.setLoggedIn(true, token);
              if (ctx.mounted) Navigator.pop(ctx);
              app.setStatus('Logged in as $user');
              app.fetchLatestShot();
            } catch (e) {
              setState(() { loading = false; error = 'Error: $e'; });
            }
          }, child: const Text('Login')),
        ],
      )),
    );
  }

  static Future<String> _login(String apiUrl, String user, String pass, AppState app) async {
    // Route through SSH tunnel if SSH is configured
    String effectiveUrl = apiUrl;
    if (app.sshMode > 0 && app.sshHost.isNotEmpty) {
      try {
        final settings = jsonEncode({
          'host': app.sshHost, 'port': app.sshPort,
          'user': app.sshUser, 'password': app.sshPass,
          'identity_file': app.sshIdentity,
          'mode': app.sshMode,
        });
        final resp = RustBridge.instance.prepareUrl(apiUrl, settings);
        if (resp.startsWith('http') && !resp.contains('"error"')) {
          effectiveUrl = resp;
          await Future.delayed(const Duration(milliseconds: 200)); // Give relay thread time to start
        } else {
          throw 'SSH prepare failed: $resp';
        }
      } catch (e) {
        throw 'SSH: $e';
      }
    }

    final url = '${effectiveUrl.replaceAll(RegExp(r'/$'), '')}/login';
    final uri = Uri.parse(url);
    final body = jsonEncode({'userName': user, 'password': pass});
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.set('Content-Type', 'application/json');
      request.write(body);
      final response = await request.close();
      final respBody = await response.transform(utf8.decoder).join();
      final json = jsonDecode(respBody);
      final code = json['code'];
      if (code == '20000' || code == 20000) {
        final token = json['data']?['token'];
        if (token != null) return token.toString();
        throw 'no token';
      }
      throw json['msg']?.toString() ?? 'unknown error';
    } finally {
      client.close();
    }
  }
}

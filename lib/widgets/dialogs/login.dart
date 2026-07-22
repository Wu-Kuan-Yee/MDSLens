import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';

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

    Future<void> doLogin(
        void Function(void Function()) setState, BuildContext ctx) async {
      final url = apiCtrl.text.trim();
      final user = userCtrl.text.trim();
      final pass = passCtrl.text.trim();
      if (url.isEmpty || user.isEmpty) {
        setState(() => error = 'Fill API URL and Username');
        return;
      }
      setState(() {
        loading = true;
        error = '';
      });
      try {
        await app.loginAndLoadLatest(
          apiUrl: url,
          user: user,
          password: pass,
        );
        if (ctx.mounted) Navigator.pop(ctx);
      } catch (e) {
        if (!ctx.mounted) return;
        setState(() {
          loading = false;
          error = 'Error: $e';
        });
      }
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
                title: Text(
                    loading ? 'Login — Connecting...' : 'Login — EAST API'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (error.isNotEmpty)
                    SelectableText(error,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 13)),
                  if (error.isNotEmpty) const SizedBox(height: 8),
                  if (loading)
                    const Row(children: [
                      SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('Logging in...')
                    ])
                  else ...[
                    TextField(
                        controller: apiCtrl,
                        decoration: const InputDecoration(labelText: 'API URL'),
                        onSubmitted: (_) => doLogin(setState, ctx)),
                    TextField(
                        controller: userCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Username'),
                        onSubmitted: (_) => doLogin(setState, ctx)),
                    TextField(
                        controller: passCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Password'),
                        obscureText: true,
                        onSubmitted: (_) => doLogin(setState, ctx)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Checkbox(
                        value: app.rememberLogin,
                        onChanged: (v) {
                          if (v != null) setState(() => app.rememberLogin = v);
                        },
                      ),
                      const Text('Remember Credentials',
                          style: TextStyle(fontSize: 13)),
                    ]),
                  ],
                ]),
                actions: loading
                    ? [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel')),
                      ]
                    : [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () => doLogin(setState, ctx),
                            child: const Text('Login')),
                      ],
              )),
    );
  }
}

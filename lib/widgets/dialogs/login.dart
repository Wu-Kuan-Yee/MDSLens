import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import 'keyboard_safe_dialog.dart';

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
    var notice = app.hasActiveSession ? 'Signed in' : 'Not signed in';

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
        notice = 'Connecting...';
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
          notice = 'Not signed in';
          error = 'Error: $e';
        });
      }
    }

    void doLogout(void Function(void Function()) setState) {
      app.logout();
      setState(() {
        loading = false;
        error = '';
        notice = 'Signed out';
      });
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => KeyboardSafeDialog(
                title: const Text('MdsScope Account'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Icon(
                      app.hasActiveSession
                          ? Icons.check_circle_rounded
                          : Icons.account_circle_outlined,
                      color: app.hasActiveSession
                          ? const Color(0xFF16A34A)
                          : Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(notice)),
                    if (loading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ]),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(error,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 13)),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('login-api-url'),
                    controller: apiCtrl,
                    enabled: !loading,
                    decoration: const InputDecoration(labelText: 'API URL'),
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => doLogin(setState, ctx),
                  ),
                  TextField(
                    key: const ValueKey('login-username'),
                    controller: userCtrl,
                    enabled: !loading,
                    decoration: const InputDecoration(labelText: 'Username'),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => doLogin(setState, ctx),
                  ),
                  TextField(
                    key: const ValueKey('login-password'),
                    controller: passCtrl,
                    enabled: !loading,
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                    onSubmitted: (_) => doLogin(setState, ctx),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Checkbox(
                      value: app.rememberLogin,
                      onChanged: loading
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() => app.rememberLogin = v);
                              }
                            },
                    ),
                    const Expanded(
                      child: Text('Remember Credentials',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ]),
                ]),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  OutlinedButton(
                    key: const ValueKey('login-dialog-logout'),
                    onPressed: loading || !app.hasActiveSession
                        ? null
                        : () => doLogout(setState),
                    child: const Text('Logout'),
                  ),
                  FilledButton(
                    key: const ValueKey('login-dialog-login'),
                    onPressed: loading ? null : () => doLogin(setState, ctx),
                    child: const Text('Login'),
                  ),
                ],
              )),
    ).whenComplete(() {
      apiCtrl.dispose();
      userCtrl.dispose();
      passCtrl.dispose();
    });
  }
}

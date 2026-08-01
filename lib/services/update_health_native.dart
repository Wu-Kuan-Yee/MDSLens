import 'dart:io';

const updateHealthArgument = '--mdslens-update-health=';
const updateHealthTokenArgument = '--mdslens-update-token=';
const updateCommitArgument = '--mdslens-update-commit=';

/// Reports that a replacement process reached the first usable Flutter frame
/// and completed its local startup work.  The native updater creates this
/// nonce-bound file and decides when it is safe to commit the replacement.
///
/// The file is deliberately written by the replacement process rather than
/// inferred from process liveness.  A process can remain alive while Flutter,
/// Rust FFI, configuration loading, or plugin initialization is still broken.
Future<void> acknowledgeUpdateHealth(List<String> arguments) async {
  String? path;
  String? token;
  for (final argument in arguments) {
    if (argument.startsWith(updateHealthArgument)) {
      path = argument.substring(updateHealthArgument.length);
    } else if (argument.startsWith(updateHealthTokenArgument)) {
      token = argument.substring(updateHealthTokenArgument.length);
    }
  }
  if (path == null || path.trim().isEmpty || token == null || token.isEmpty) {
    return;
  }

  final marker = File(path);
  try {
    // Never follow a symlink supplied through a launch argument.  The updater
    // creates an ordinary nonce-specific file, so a symlink here indicates a
    // tampered or stale transaction and must not be overwritten.
    if (await FileSystemEntity.type(
          marker.path,
          followLinks: false,
        ) ==
        FileSystemEntityType.link) {
      return;
    }
    if (!await marker.parent.exists()) return;
    await marker.writeAsString('$token\n', flush: true);
  } catch (_) {
    // Health reporting must never prevent a normal application launch.  The
    // updater will retain its rollback copy if this signal cannot be written.
  }
}

/// Commits a replacement transaction after the first usable Flutter frame and
/// local startup work are complete.  The native updater waits for this
/// nonce-bound marker before deleting the previous installation.
Future<void> acknowledgeUpdateCommit(List<String> arguments) async {
  String? path;
  String? token;
  for (final argument in arguments) {
    if (argument.startsWith(updateCommitArgument)) {
      path = argument.substring(updateCommitArgument.length);
    } else if (argument.startsWith(updateHealthTokenArgument)) {
      token = argument.substring(updateHealthTokenArgument.length);
    }
  }
  if (path == null || path.trim().isEmpty || token == null || token.isEmpty) {
    return;
  }

  final marker = File(path);
  try {
    if (await FileSystemEntity.type(
          marker.path,
          followLinks: false,
        ) ==
        FileSystemEntityType.link) {
      return;
    }
    if (!await marker.parent.exists()) return;
    await marker.writeAsString('$token\n', flush: true);
  } catch (_) {
    // A failed commit signal leaves the rollback copy available for recovery.
  }
}

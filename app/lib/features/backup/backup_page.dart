import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../catalog/tree_edit_prompts.dart';
import '../pin/pin_gate.dart';
import 'backup_codec.dart';
import 'backup_store.dart';

typedef BackupSavePicker = Future<String?> Function({required String suggestedName});
typedef BackupOpenPicker = Future<String?> Function();

class BackupPage extends StatefulWidget {
  const BackupPage({
    this.codec,
    this.store,
    this.pickSavePath,
    this.pickOpenPath,
    super.key,
  });

  final BackupCodec? codec;
  final BackupStore? store;
  final BackupSavePicker? pickSavePath;
  final BackupOpenPicker? pickOpenPath;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  String? _lastAt;
  String? _lastSource;
  var _busy = false;
  Object? _metaDb;

  BackupCodec get _codec => widget.codec ?? BackupCodec();
  BackupStore get _store => widget.store ?? const BackupStore();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final db = AppScope.of(context).db;
    if (identical(_metaDb, db)) return;
    _metaDb = db;
    _reloadMeta();
  }

  Future<void> _reloadMeta() async {
    final db = AppScope.of(context).db;
    try {
      final at = await db.settingsDao.getSetting(kLastBackupAtKey);
      final source = await db.settingsDao.getSetting(kLastBackupSourceKey);
      if (!mounted) return;
      setState(() {
        _lastAt = at;
        _lastSource = source;
      });
    } catch (_) {
      // Closed pre-restore connection; a later AppScope rebuild reloads.
    }
  }

  Future<String?> _savePath() async {
    if (widget.pickSavePath != null) {
      return widget.pickSavePath!(suggestedName: 'wired-parts-backup.wpbackup');
    }
    final location = await getSaveLocation(
      suggestedName: 'wired-parts-backup.wpbackup',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Wired Parts backup', extensions: ['wpbackup']),
      ],
    );
    return location?.path;
  }

  Future<String?> _openPath() async {
    if (widget.pickOpenPath != null) return widget.pickOpenPath!();
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Wired Parts backup', extensions: ['wpbackup']),
      ],
    );
    return file?.path;
  }

  Future<void> _export() async {
    if (_busy) return;
    final scope = AppScope.of(context);
    if (!await ensurePinUnlocked(context, scope.pin)) return;
    if (!mounted) return;
    final password = await _promptPassword(
      title: 'Encrypt backup',
      confirm: true,
    );
    if (password == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final path = await _savePath();
      if (path == null || !mounted) return;
      await scope.db.customStatement('PRAGMA wal_checkpoint(FULL);');
      final sqliteFile = await _store.sqliteFile();
      if (!await sqliteFile.exists()) {
        throw const BackupFormatException('No local database to export');
      }
      final payload = await _store.collect(
        sourceDeviceId: scope.deviceId,
        createdAt: DateTime.now().toUtc(),
        sqliteBytes: await sqliteFile.readAsBytes(),
      );
      final bytes = await _codec.encrypt(payload, password);
      await writeBytesAtomically(File(path), bytes);
      await scope.db.settingsDao.setSetting(
        kLastBackupAtKey,
        payload.createdAt.toIso8601String(),
      );
      await scope.db.settingsDao.setSetting(
        kLastBackupSourceKey,
        payload.sourceDeviceId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup saved')),
      );
      await _reloadMeta();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final scope = AppScope.of(context);
    if (!await ensurePinUnlocked(context, scope.pin)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final path = await _openPath();
      if (path == null || !mounted) return;
      final fileBytes = await File(path).readAsBytes();
      final header = BackupCodec.peekHeader(Uint8List.fromList(fileBytes));
      if (!mounted) return;
      final confirmed = await confirmAction(
        context,
        title: 'Restore this backup?',
        body:
            'Replaces all catalog, jobs, photos, and PIN on this device with the '
            'backup from ${header.sourceDeviceId} '
            '(${_formatStamp(header.createdAt.toIso8601String())}). Cannot undo.',
        confirmLabel: 'Restore',
      );
      if (!confirmed || !mounted) return;
      final password = await _promptPassword(title: 'Decrypt backup');
      if (password == null || !mounted) return;
      await scope.restoreFromBackup(fileBytes, password);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup restored')),
      );
      // Do not query the pre-restore connection here: restore closes it and
      // replaces AppScope. A failed meta read must not report Restore failed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _reloadMeta();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _promptPassword({
    required String title,
    bool confirm = false,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => _BackupPasswordDialog(title: title, confirm: confirm),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _lastAt == null
        ? 'No backup on this device yet'
        : '${_formatStamp(_lastAt!)} · source ${_lastSource ?? 'unknown'}';
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Last backup'),
            subtitle: Text(subtitle),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('Export encrypted backup'),
            subtitle: const Text('PIN if set, then a backup password'),
            enabled: !_busy,
            onTap: _export,
          ),
          ListTile(
            leading: const Icon(Icons.settings_backup_restore),
            title: const Text('Restore encrypted backup'),
            subtitle: const Text('Replaces this device with the backup shop'),
            enabled: !_busy,
            onTap: _restore,
          ),
        ],
      ),
    );
  }
}

/// Owns its controllers so they are not disposed while the dialog route is
/// still animating out (same pattern as the New Job dialog).
class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.title, this.confirm = false});

  final String title;
  final bool confirm;

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _password = TextEditingController();
  final _again = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _again.dispose();
    super.dispose();
  }

  void _submit() {
    final a = _password.text;
    if (a.isEmpty) return;
    if (widget.confirm && a != _again.text) return;
    Navigator.pop(context, a);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Backup password'),
            onSubmitted: widget.confirm ? null : (_) => _submit(),
          ),
          if (widget.confirm) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _again,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm password'),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

String _formatStamp(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return iso;
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $h:$min';
}

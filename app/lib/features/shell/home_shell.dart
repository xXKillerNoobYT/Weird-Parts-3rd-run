import 'package:flutter/material.dart';

import '../../app.dart';
import '../backup/backup_page.dart';
import '../backup/backup_store.dart';
import '../catalog/catalog_page.dart';
import '../catalog/tree_edit_prompts.dart';
import '../jobs/jobs_page.dart';
import '../maintenance/maintenance_page.dart';
import '../pin/pin_gate.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          JobsPage(),
          CatalogPage(),
          _MoreTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.work_outline),
            selectedIcon: Icon(Icons.work),
            label: 'Jobs',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Catalog',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz),
            selectedIcon: Icon(Icons.more_horiz),
            label: 'More',
          ),
        ],
      ),
    );
  }
}

class _MoreTab extends StatefulWidget {
  const _MoreTab();

  @override
  State<_MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<_MoreTab> {
  bool? _pinSet;
  bool _unlocked = false;
  var _didInitPin = false;
  String? _lastBackupAt;
  String? _lastBackupSource;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInitPin) return;
    _didInitPin = true;
    _refreshPinState();
  }

  Future<void> _refreshPinState() async {
    final scope = AppScope.of(context);
    final pin = scope.pin;
    final db = scope.db;
    final set = await pin.isPinSet();
    final at = await db.settingsDao.getSetting(kLastBackupAtKey);
    final source = await db.settingsDao.getSetting(kLastBackupSourceKey);
    if (!mounted) return;
    setState(() {
      _pinSet = set;
      _unlocked = pin.isUnlocked;
      _lastBackupAt = at;
      _lastBackupSource = source;
    });
  }

  Future<void> _setOrChangePin() async {
    final pin = AppScope.of(context).pin;
    final isSet = await pin.isPinSet();
    if (!mounted) return;

    if (isSet && !pin.isUnlocked) {
      final ok = await showPinGate(context, pin);
      if (!ok || !mounted) return;
    }

    final controller = TextEditingController();
    final confirmController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(isSet ? 'Change PIN' : 'Set PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                obscureText: true,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'New PIN'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Confirm PIN'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final a = controller.text.trim();
                final b = confirmController.text.trim();
                if (a.isEmpty || a != b) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    final value = controller.text.trim();
    controller.dispose();
    confirmController.dispose();
    if (saved != true || value.isEmpty) return;

    await pin.setPin(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(isSet ? 'PIN changed' : 'PIN set')),
    );
    await _refreshPinState();
  }

  Future<void> _lockCatalog() async {
    final pin = AppScope.of(context).pin;
    if (!await pin.isPinSet()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set a PIN first')),
      );
      return;
    }
    pin.lock();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Catalog locked')),
    );
    await _refreshPinState();
  }

  void _openBackup() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const BackupPage()))
        .then((_) {
      if (mounted) _refreshPinState();
    });
  }

  void _openMaintenance() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const MaintenancePage()),
    );
  }

  Future<void> _wipeAllData() async {
    final confirmed = await confirmAction(
      context,
      title: 'Wipe all local data?',
      body:
          'This deletes the catalog, jobs, photos, and PIN on this device and '
          'leaves an empty shop. Cannot undo.',
      confirmLabel: 'Wipe everything',
    );
    if (!confirmed || !mounted) return;
    if (!await ensurePinUnlocked(context, AppScope.of(context).pin)) return;
    if (!mounted) return;
    try {
      await AppScope.of(context).wipeLocalData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wipe failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinLabel = _pinSet == null
        ? 'Set / Change PIN'
        : (_pinSet! ? 'Change PIN' : 'Set PIN');
    final status = _pinSet == null
        ? ''
        : !_pinSet!
            ? 'No PIN set'
            : (_unlocked ? 'Unlocked' : 'Locked');

    final backupSubtitle = _lastBackupAt == null
        ? 'No backup on this device yet'
        : '${_formatBackupStamp(_lastBackupAt!)} · ${_lastBackupSource ?? 'unknown'}';

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.build_outlined),
            title: const Text('Maintenance'),
            subtitle: const Text('Types tree, brands, suppliers'),
            onTap: _openMaintenance,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('Backup & restore'),
            subtitle: Text(backupSubtitle),
            onTap: _openBackup,
          ),
          ListTile(
            leading: const Icon(Icons.pin_outlined),
            title: Text(pinLabel),
            subtitle: status.isEmpty ? null : Text(status),
            onTap: _setOrChangePin,
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Lock catalog'),
            subtitle: const Text('Require PIN for catalog edits'),
            onTap: _lockCatalog,
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('Reset / wipe all data'),
            subtitle: const Text('Empty shop — catalog, jobs, photos, PIN'),
            onTap: _wipeAllData,
          ),
        ],
      ),
    );
  }
}

String _formatBackupStamp(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return iso;
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $h:$min';
}

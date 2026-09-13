import 'package:drift/drift.dart';

import '../../core/new_id.dart';
import '../app_database.dart';
import '../tables/app_settings.dart';
import '../tables/device_profile.dart';

part 'settings_dao.g.dart';

@DriftAccessor(tables: [DeviceProfiles, AppSettings])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin {
  SettingsDao(super.db);

  Future<String> ensureDeviceId() async {
    final existing = await select(deviceProfiles).getSingleOrNull();
    if (existing != null) return existing.id;
    final id = newId();
    await into(deviceProfiles).insert(
      DeviceProfilesCompanion.insert(
        id: id,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    return id;
  }

  Future<void> setSetting(String key, String value) async {
    await into(appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: key, value: value),
    );
  }

  Future<String?> getSetting(String key) async {
    final row = await (select(appSettings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  /// Keep this install's device id after a restore (backup carries the source).
  Future<void> keepLocalDeviceId(String id) async {
    await delete(deviceProfiles).go();
    await into(deviceProfiles).insert(
      DeviceProfilesCompanion.insert(
        id: id,
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }
}

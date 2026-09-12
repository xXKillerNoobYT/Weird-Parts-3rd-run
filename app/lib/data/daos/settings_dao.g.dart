// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'settings_dao.dart';

// ignore_for_file: type=lint
mixin _$SettingsDaoMixin on DatabaseAccessor<AppDatabase> {
  $DeviceProfilesTable get deviceProfiles => attachedDatabase.deviceProfiles;
  $AppSettingsTable get appSettings => attachedDatabase.appSettings;
  SettingsDaoManager get managers => SettingsDaoManager(this);
}

class SettingsDaoManager {
  final _$SettingsDaoMixin _db;
  SettingsDaoManager(this._db);
  $$DeviceProfilesTableTableManager get deviceProfiles =>
      $$DeviceProfilesTableTableManager(
        _db.attachedDatabase,
        _db.deviceProfiles,
      );
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db.attachedDatabase, _db.appSettings);
}

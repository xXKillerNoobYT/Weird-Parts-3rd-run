import '../../core/pin_hasher.dart';
import '../../data/daos/settings_dao.dart';

class PinService {
  PinService(this._settings);

  final SettingsDao _settings;
  static const _key = 'editor_pin_hash';

  bool _unlocked = false;
  bool get isUnlocked => _unlocked;

  Future<bool> isPinSet() async => (await _settings.getSetting(_key)) != null;

  Future<void> setPin(String pin) async {
    await _settings.setSetting(_key, PinHasher.hashPin(pin));
    _unlocked = false;
  }

  Future<bool> unlock(String pin) async {
    final stored = await _settings.getSetting(_key);
    if (stored == null) {
      _unlocked = true;
      return true;
    }
    final ok = PinHasher.verify(pin, stored);
    _unlocked = ok;
    return ok;
  }

  void lock() => _unlocked = false;

  Future<void> requireUnlocked() async {
    if (!await isPinSet()) return;
    if (!_unlocked) {
      throw StateError('Catalog editor PIN required');
    }
  }
}

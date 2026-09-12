import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_database.dart';
import 'features/pin/pin_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase();
  final deviceId = await db.settingsDao.ensureDeviceId();
  final pin = PinService(db.settingsDao);

  runApp(
    WiredPartsApp(
      db: db,
      pin: pin,
      deviceId: deviceId,
    ),
  );
}

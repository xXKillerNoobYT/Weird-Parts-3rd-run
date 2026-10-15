import 'dart:io';
import 'dart:typed_data';

import 'package:wired_parts/features/installation/installation_security.dart';

final class JobTestStore
    implements InstallationSecureStore, RecoveryFilePublisher {
  final states = <String, ProtectedInstallationState>{};
  @override
  Future<ProtectedInstallationState?> readState(String namespace) async =>
      states[namespace];
  @override
  Future<String> compareAndSwapState(
    String namespace, {
    required String? expectedRevision,
    required String nextRevision,
    required Uint8List bytes,
  }) async {
    if (states[namespace]?.revision != expectedRevision) {
      throw StateError('CAS conflict');
    }
    states[namespace] = ProtectedInstallationState(
      nextRevision,
      Uint8List.fromList(bytes),
    );
    return nextRevision;
  }

  @override
  Future<void> writeRecoveryFileExclusive(
    String absolutePath,
    Uint8List bytes,
  ) async {
    final file = File(absolutePath);
    await file.create(exclusive: true);
    await file.writeAsBytes(bytes, flush: true);
  }
}

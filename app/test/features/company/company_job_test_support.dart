import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:wired_parts/features/installation/installation_security.dart';

final class JobTestStore
    implements InstallationSecureStore, RecoveryFilePublisher {
  final states = <String, ProtectedInstallationState>{};
  bool failNextCommandClear = false;
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
    if (failNextCommandClear &&
        jsonDecode(utf8.decode(bytes))['pendingCommand'] == null &&
        jsonDecode(utf8.decode(states[namespace]!.bytes))['pendingCommand'] !=
            null) {
      failNextCommandClear = false;
      throw StateError('command clear CAS interrupted');
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

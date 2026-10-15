import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

// Bounded, nonsecret engineering probe. CLI numbers do not establish native
// app responsiveness or approve a credential profile.
Future<void> main() async {
  final random = Random.secure();
  final input = List<int>.generate(20, (_) => random.nextInt(256));
  final salt = List<int>.generate(16, (_) => random.nextInt(256));

  for (final memory in <int>[19456, 32768]) {
    final algorithm = Argon2id(
      parallelism: 1,
      memory: memory,
      iterations: 2,
      hashLength: 32,
    );
    for (var sampleIndex = 0; sampleIndex < 3; sampleIndex++) {
      var peakRss = ProcessInfo.currentRss;
      var timerSamples = 0;
      final sampler = Timer.periodic(const Duration(milliseconds: 20), (_) {
        timerSamples++;
        peakRss = max(peakRss, ProcessInfo.currentRss);
      });
      final watch = Stopwatch()..start();
      final key = await algorithm.deriveKey(
        secretKey: SecretKey(input),
        nonce: salt,
      );
      await key.extractBytes();
      peakRss = max(peakRss, ProcessInfo.currentRss);
      watch.stop();
      sampler.cancel();
      stdout.writeln(
        'memoryKiB=$memory sample=$sampleIndex '
        'elapsedMs=${watch.elapsedMilliseconds} '
        'sampledPeakProcessRssMiB=${(peakRss / 1048576).toStringAsFixed(1)} '
        'timerSamples=$timerSamples',
      );
    }
  }

  stdout.writeln(
    'dart=${Platform.version.split(' ').first} '
    'os=${Platform.operatingSystem} '
    'processors=${Platform.numberOfProcessors}',
  );
}

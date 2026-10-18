import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_crypto.dart';

String digest(String text) => sha256.convert(utf8.encode(text)).toString();

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('details-admission-');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('frozen source bundle verifies inside copied container location', () {
    final paths = [
      'app/lib/data/app_database.dart',
      'app/lib/data/app_database.g.dart',
      'app/lib/features/company/company_join.dart',
      'app/lib/features/company/company_protocol.dart',
      'app/lib/features/company/company_membership.dart',
      'app/lib/features/company/company_created_job_sync.dart',
      'app/lib/features/company/company_job_details_section.dart',
      'app/lib/features/installation/installation_security.dart',
      'app/lib/features/job_line_commands/job_details.dart',
      'app/tool/native_nearby_test_commands.dart',
      'app/tool/native_nearby_test_fixture.dart',
      'app/integration_test/company_join_native_test.dart',
      'app/pubspec.yaml',
      'app/pubspec.lock',
    ];
    for (final path in paths) {
      final file = File(p.join(temp.path, 'source', path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('frozen\r\n');
    }
    final sourceHash = digest('frozen\n');
    final manifest = File(p.join(temp.path, 'manifest.json'));
    final value = {
      'format': 1,
      'kind': 'j116.details.source@1',
      'run': adapter.jobDetailsNativeRun,
      'revision': 'a' * 40,
      'tree': 'b' * 40,
      'adapterSha256': sourceHash,
      'productRevision': 'a' * 40,
      'sourceLfSha256': {for (final path in paths) path: sourceHash},
    };
    manifest.writeAsStringSync(jsonEncode(value));
    final manifestHash = digest(manifest.readAsStringSync());
    void validate({String? hash}) =>
        adapter.validateJobDetailsNativeSourceManifest(
          manifest: manifest,
          manifestSha256: hash ?? manifestHash,
          revision: 'a' * 40,
          tree: 'b' * 40,
          adapter: sourceHash,
          productRevision: 'a' * 40,
        );
    expect(validate, returnsNormally);
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(value),
    );
    expect(validate, throwsA(isA<NativeTestFailure>()));
    manifest.writeAsStringSync(jsonEncode(value));
    final edited = File(p.join(temp.path, 'source', paths.first));
    edited.writeAsStringSync('changed\n');
    expect(validate, throwsA(isA<NativeTestFailure>()));
    edited.writeAsStringSync('frozen\n');
    expect(validate, returnsNormally);
    final extra = File(p.join(temp.path, 'source', 'unexpected.dart'))
      ..writeAsStringSync('extra');
    expect(validate, throwsA(isA<NativeTestFailure>()));
    extra.deleteSync();
    expect(() => validate(hash: '0' * 64), throwsA(isA<NativeTestFailure>()));
    manifest.writeAsStringSync(
      jsonEncode({...value, 'run': adapter.createdJobNativeRun}),
    );
    expect(
      () => validate(hash: digest(manifest.readAsStringSync())),
      throwsA(isA<NativeTestFailure>()),
    );
  });

  test('details root rejects retired roots, unfinished state and absent checkpoint without writes', () {
    final nativeTemp = Directory(temp.resolveSymbolicLinksSync());
    final root = Directory(
      p.join(
        nativeTemp.path,
        'wired-parts-lan-company-${adapter.jobDetailsNativeRun}-sender',
      ),
    );
    adapter.JoinNativeRootAdmission admit(
      Directory target, {
      String path = '',
      String hash = '',
    }) => adapter.validateJobDetailsNativeRootAdmission(
      target,
      run: adapter.jobDetailsNativeRun,
      role: 'owner',
      revision: 'a' * 40,
      tree: 'b' * 40,
      adapter: 'c' * 64,
      productRevision: 'a' * 40,
      manifestSha256: 'd' * 64,
      checkpointPath: path,
      checkpointSha256: hash,
      temporaryDirectory: nativeTemp,
    );
    expect(admit(root).stage, adapter.JoinNativeRootStage.fresh);
    expect(root.existsSync(), isFalse);
    final retired = Directory(
      p.join(
        nativeTemp.path,
        'wired-parts-lan-company-${adapter.createdJobNativeRun}-sender',
      ),
    );
    expect(() => admit(retired), throwsA(isA<NativeTestFailure>()));
    final retiredDetails = Directory(
      p.join(nativeTemp.path, 'wired-parts-lan-company-j116-details-v1-sender'),
    )..createSync();
    final retiredEvidence = File(p.join(retiredDetails.path, 'preserved.json'))
      ..writeAsStringSync('preserved');
    expect(() => admit(retiredDetails), throwsA(isA<NativeTestFailure>()));
    expect(retiredEvidence.readAsStringSync(), 'preserved');
    root.createSync();
    final preserved = File(p.join(root.path, 'failed-evidence.json'))
      ..writeAsStringSync('preserved');
    expect(() => admit(root), throwsA(isA<NativeTestFailure>()));
    final checkpoint =
        File(p.join(root.path, 'join-details-checkpoint-1-1.json'))
          ..writeAsStringSync(
            jsonEncode({'format': 1, 'run': adapter.createdJobNativeRun}),
          );
    final before = checkpoint.readAsBytesSync();
    expect(
      () => admit(
        root,
        path: checkpoint.path,
        hash: sha256.convert(before).toString(),
      ),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(checkpoint.readAsBytesSync(), before);
    expect(preserved.readAsStringSync(), 'preserved');
  });

  test(
    'cold readback refuses changed details, family ACKs or immutable history',
    () {
      final evidence = <String, Object?>{
        'identity': {'device': 'a'},
        'counts': {'company_job_details': 4},
        'schema': 10,
        'jobHistorySha256': '1' * 64,
        'receiptSha256': '2' * 64,
        'ackCount': 2,
        'ackSha256': '3' * 64,
        'nameOperationCount': 0,
        'nameReceiptCountVerified': 0,
        'nameRecordsSha256': '4' * 64,
        'nameAckCount': 0,
        'nameAckSha256': '5' * 64,
        'nameViews': [],
        'detailsOperationCount': 4,
        'detailsReceiptCountVerified': 4,
        'detailsRecordsSha256': '6' * 64,
        'detailsAckCount': 4,
        'detailsAckSha256': '7' * 64,
        'detailsViews': [
          {
            'notes': {'hasConflict': true, 'lastAgreedValue': 'Gate 3'},
          },
        ],
        'confirmedPeerCounts': {'job': 1},
        'detailsReceiptVerification': 'typed-public-verifier',
        'nameReceiptVerification': 'typed-public-verifier',
        'receiptVerification': 'typed-public-verifier',
        'ackVerification': 'confirmedPeerCounts',
      };
      final checkpoint = <String, dynamic>{'detailsEvidence': evidence};
      expect(
        () => adapter.verifyJobDetailsNativeReadback(checkpoint, evidence),
        returnsNormally,
      );
      for (final change in <Map<String, Object?>>[
        {'detailsViews': []},
        {'detailsAckCount': 3},
        {'jobHistorySha256': '0' * 64},
        {'nameRecordsSha256': '0' * 64},
        {'detailsReceiptCountVerified': 3},
        {'receiptVerification': 'locked-not-performed'},
      ]) {
        expect(
          () => adapter.verifyJobDetailsNativeReadback(checkpoint, {
            ...evidence,
            ...change,
          }),
          throwsA(isA<NativeTestFailure>()),
        );
      }
    },
  );
}

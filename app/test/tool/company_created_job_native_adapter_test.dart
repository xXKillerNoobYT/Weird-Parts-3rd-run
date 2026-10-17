import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../integration_test/company_join_native_test.dart' as adapter;

final _revision = List.filled(40, 'a').join();
final _tree = List.filled(40, 'b').join();
final _adapterHash = List.filled(64, 'c').join();

void _validate({
  bool createdMode = true,
  String? run,
  String? revision,
  String? productRevision,
  String role = 'owner',
  String platform = 'windows',
}) => adapter.validateJoinNativeDefines(
  enabled: true,
  run: run ?? adapter.createdJobNativeRun,
  role: role,
  platform: platform,
  revision: revision ?? _revision,
  tree: _tree,
  adapter: _adapterHash,
  createdMode: createdMode,
  productRevision: productRevision ?? _revision,
);

void main() {
  test('created mode requires a fresh run and the exact full source pin', () {
    expect(() => _validate(), returnsNormally);
    expect(() => _validate(role: 'member', platform: 'macos'), returnsNormally);
    expect(() => _validate(run: adapter.joinNativeRun), throwsA(anything));
    expect(() => _validate(productRevision: _tree), throwsA(anything));
    expect(
      () => _validate(revision: 'short', productRevision: 'short'),
      throwsA(anything),
    );
    expect(
      () => _validate(
        revision: adapter.joinNativeProductRevision,
        productRevision: adapter.joinNativeProductRevision,
      ),
      throwsA(anything),
    );
    expect(() => _validate(role: 'member'), throwsA(anything));
  });

  test('legacy defaults retain their exact run and product pin', () {
    expect(
      () => adapter.validateJoinNativeDefines(
        enabled: true,
        run: adapter.joinNativeRun,
        role: 'owner',
        platform: 'windows',
        revision: _revision,
        tree: _tree,
        adapter: _adapterHash,
      ),
      returnsNormally,
    );
    expect(() => _validate(createdMode: false), throwsA(anything));
    expect(
      adapter.joinNativeNamespace(adapter.joinNativeRun, 'owner'),
      'synthetic.company.join.j60-join-v10.owner',
    );
    expect(
      adapter.joinNativeNamespace(
        adapter.createdJobNativeRun,
        'owner',
        createdMode: true,
      ),
      'synthetic.company.created.j61-created-v1.owner',
    );
    expect(
      () => adapter.joinNativeNamespace(
        adapter.joinNativeRun,
        'owner',
        createdMode: true,
      ),
      throwsA(anything),
    );
  });

  test('public UI completion remains pending until its button is released', () {
    adapter.CreatedJobNativeUiState state(
      String status, {
      bool busy = false,
      bool error = false,
    }) => adapter.createdJobNativeUiState(
      status: status,
      errorVisible: error,
      busy: busy,
    );
    expect(
      state('Checking Job sync permissions.'),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Exchanging Job holdings with the verified peer.'),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.', busy: true),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.'),
      adapter.CreatedJobNativeUiState.complete,
    );
    expect(
      state(
        'Confirmed sent 0, received 0. More Jobs pending. Pair again and retry Sync Now.',
      ),
      adapter.CreatedJobNativeUiState.incomplete,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.', error: true),
      adapter.CreatedJobNativeUiState.error,
    );
    expect(
      state(
        'Trusted peer authenticated. Verification alone does not exchange Jobs.',
      ),
      adapter.CreatedJobNativeUiState.idle,
    );
    expect(
      state('Unrecognized future product copy'),
      adapter.CreatedJobNativeUiState.unknown,
    );
  });

  test(
    'partial created fixtures cannot be adopted for an interruption retry',
    () {
      final root = Directory.systemTemp.createTempSync('j61-adapter-boundary-');
      addTearDown(() => root.deleteSync(recursive: true));
      bool validate() => adapter.validateJoinNativeExistingRoot(
        root,
        run: adapter.createdJobNativeRun,
        role: 'owner',
        revision: _revision,
        tree: _tree,
        adapter: _adapterHash,
        createdMode: true,
        productRevision: _revision,
      );
      expect(validate, throwsA(anything));
      final receipt = <String, Object?>{
        'format': 1,
        'passed': true,
        'run': adapter.createdJobNativeRun,
        'role': 'owner',
        'namespace': adapter.joinNativeNamespace(
          adapter.createdJobNativeRun,
          'owner',
          createdMode: true,
        ),
        'sourceRevision': _revision,
        'sourceTree': _tree,
        'adapterSha256': _adapterHash,
        'productRevision': _revision,
        'root': root.path,
        'locked': true,
        'mode': 'created-jobs',
        'schema': 8,
        'createdJobsComplete': false,
        'bothJobsRendered': true,
        'receiptCountVerifiedBeforeLock': 2,
        'identity': {
          for (final key in [
            'installation',
            'generation',
            'publicKeySha256',
            'storeGeneration',
            'company',
            'shop',
            'user',
            'device',
          ])
            key: key,
        },
      };
      final file = File(p.join(root.path, 'join-exercise.json'));
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate, throwsA(anything));
      receipt['createdJobsComplete'] = true;
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate(), isTrue);
      receipt['sourceTree'] = _revision;
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate, throwsA(anything));
    },
  );
}

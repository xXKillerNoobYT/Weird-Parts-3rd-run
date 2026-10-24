import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_job_name_test.dart' show canonicalNameTest;

void main() {
  test('five-field 32-shared-parent descriptor and ACK fit unchanged wire byte caps', () {
    const id = '00000000-0000-4000-8000-000000000001';
    final parents = List.generate(
      32,
      (i) => i.toRadixString(16).padLeft(64, '0'),
    );
    final command = PatchJobDetails(
      companyId: id,
      shopId: id,
      jobId: id,
      requestId: id,
      creationDigest: 'a' * 64,
      patch: const JobDetailsPatch(
        customer: SetField('C'),
        location: SetField('L'),
        jobNumber: SetField('J'),
        status: SetField(CompanyJobStatus.archived),
        notes: SetField('N'),
      ),
      observedHeads: {for (final f in JobDetailField.values) f: parents},
      resolvingFields: JobDetailField.values.toSet(),
    );
    final body = {
      'v': 1,
      'contract': 'job.details.patch@1',
      'company': id,
      'shop': id,
      'job': id,
      'request': id,
      'creation': 'a' * 64,
      'units': {
        for (final f in JobDetailField.values)
          f.name: {
            'value': switch (f) {
              JobDetailField.customer => 'C',
              JobDetailField.location => 'L',
              JobDetailField.jobNumber => 'J',
              JobDetailField.status => 'archived',
              JobDetailField.notes => 'N',
            },
            'parents': parents,
          },
      },
      'resolve': JobDetailField.values.map((f) => f.name).toList()..sort(),
      'generation': id,
      'installation': id,
      'device': id,
      'user': id,
      'command': command.commitment,
      'facts': 'a' * 64,
    };
    final row = CompanyJobDetail(
      companyId: id,
      shopId: id,
      jobId: id,
      originGeneration: id,
      requestId: id,
      operationCommitment: 'b' * 64,
      commandCommitment: command.commitment,
      operationBytes: canonicalNameTest({
        'body': body,
        'authorization': <String, Object?>{},
        'signature': 'candidate',
      }),
      receiptKey: 'c' * 64,
      receiptBytes: '{}',
      auditBytes: '{}',
      outgoing: true,
    );
    final local = CreatedJobHoldingsInventory.local([row]);
    final descriptor = local.page(0).single;
    expect(descriptor['fields'], hasLength(5));
    expect(descriptor['parents'], hasLength(32));
    expect(descriptor.containsKey('units'), isFalse);
    final descriptorBytes = utf8.encode(canonicalNameTest(descriptor)).length;
    final ackBytes = utf8
        .encode(
          canonicalNameTest({
            'body': {
              'v': 1,
              'kind': 'company.job.details.ack@1',
              'descriptor': descriptor,
              'receiver': id,
              'generation': id,
              'store': id,
              'receipt': 'd' * 64,
            },
            'signature': base64Encode(List.filled(64, 1)),
          }),
        )
        .length;
    expect(descriptorBytes, lessThanOrEqualTo(4096));
    expect(ackBytes, lessThanOrEqualTo(4096));
    debugPrint(
      'bounded details descriptor bytes=$descriptorBytes ACK bytes=$ackBytes',
    );
    final remote = CreatedJobHoldingsInventory.remote(local.meta);
    remote.acceptPage({
      'ordinal': 0,
      'digest': local.digest,
      'items': local.page(0),
      'confirmedStores': [null],
    });
    expect(remote.complete, isTrue);
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

import 'company_job_name_test.dart' show canonicalNameTest;

void main() {
  test('32 tagged lifecycle dependencies fit actual descriptor ACK and page budgets', () {
    const id = '00000000-0000-4000-8000-000000000001';
    final parents = List.generate(
      32,
      (i) => 'l/${i.toRadixString(16).padLeft(64, '0')}',
    );
    final records = List.generate(
      32,
      (i) => CompanyJobLifecycle(
        companyId: id,
        shopId: id,
        jobId: id,
        originGeneration: id,
        requestId: '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
        operationCommitment: i.toRadixString(16).padLeft(64, '0'),
        commandCommitment: 'a' * 64,
        operationBytes: canonicalNameTest({
          'body': {
            'contract': 'job.lifecycle.set@1',
            'creation': 'b' * 64,
            'parents': parents,
            'device': id,
            'installation': id,
          },
        }),
        receiptKey: 'c' * 64,
        receiptBytes: '{}',
        auditBytes: '{}',
        outgoing: true,
      ),
    );
    final local = CreatedJobHoldingsInventory.local(records);
    final remote = CreatedJobHoldingsInventory.remote(local.meta);
    for (var page = 0; page < local.pages; page++) {
      final items = local.page(page);
      final wire = {
        'ordinal': page,
        'digest': local.digest,
        'items': items,
        'confirmedStores': List.filled(items.length, null),
      };
      expect(
        utf8.encode(canonicalNameTest(wire)).length,
        lessThanOrEqualTo(33 * 1024),
      );
      for (final d in items) {
        final descriptorLength = utf8.encode(canonicalNameTest(d)).length;
        final ackLength = utf8
            .encode(
              canonicalNameTest({
                'body': {
                  'v': 1,
                  'kind': 'company.job.lifecycle.ack@1',
                  'descriptor': d,
                  'receiver': id,
                  'generation': id,
                  'store': id,
                  'receipt': 'd' * 64,
                },
                'signature': base64Encode(List.filled(64, 1)),
              }),
            )
            .length;
        expect(descriptorLength, lessThanOrEqualTo(4096));
        expect(ackLength, lessThanOrEqualTo(4096));
        if (page == 0 && identical(d, items.first)) {
          // ignore: avoid_print
          print(
            'lifecycle descriptor=$descriptorLength ACK=$ackLength pages=${local.pages}',
          );
        }
      }
      remote.acceptPage(wire);
    }
    expect(remote.complete, isTrue);
    expect(remote.count, 32);
  });
}

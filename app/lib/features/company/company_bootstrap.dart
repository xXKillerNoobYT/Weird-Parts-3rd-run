import 'dart:io';

import 'package:drift/drift.dart';

import '../../data/app_database.dart';
import '../installation/installation_security.dart';

final class CompanyBootstrapRefusal implements Exception {
  const CompanyBootstrapRefusal(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Read-only preflight. Create repeats this check after obtaining its SQLite
/// write lock, before any protected or database mutation.
final class CompanyBootstrap {
  static Future<void> preflightFreshShop(
    AppDatabase db, {
    Directory? photosDirectory,
  }) async {
    for (final table in <String>[
      'categories',
      'styles',
      'types',
      'devices',
      'brands',
      'suppliers',
      'parts',
      'part_devices',
      'brand_versions',
      'supplier_listings',
      'jobs',
      'company_jobs',
      'job_lines',
      'order_splits',
      'company_bootstrap_witnesses',
      'company_authority_facts',
      'job_line_baselines',
      'job_line_operations',
      'job_line_receipts',
      'job_line_audits',
      'job_line_outgoing',
      'job_line_conflicts',
    ]) {
      if ((await db.customSelect('SELECT 1 FROM $table LIMIT 1').get())
          .isNotEmpty) {
        throw const CompanyBootstrapRefusal(
          'Create Company requires a fresh empty shop',
        );
      }
    }
    final otherSettings = await db
        .customSelect(
          'SELECT 1 FROM app_settings WHERE key != ? LIMIT 1',
          variables: [Variable.withString(kInstallationBindingKey)],
        )
        .get();
    if (otherSettings.isNotEmpty) {
      throw const CompanyBootstrapRefusal(
        'Existing local settings require a separate legacy shop',
      );
    }
    if (photosDirectory != null && photosDirectory.existsSync()) {
      if (photosDirectory.listSync().isNotEmpty) {
        throw const CompanyBootstrapRefusal(
          'Existing photos require a separate legacy shop',
        );
      }
    }
  }
}

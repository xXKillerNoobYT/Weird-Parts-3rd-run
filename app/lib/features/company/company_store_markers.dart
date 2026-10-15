import '../../data/app_database.dart';
import '../installation/installation_security.dart';

const priorCompanyMarkerTables = [
  'company_authority_facts',
  'job_line_baselines',
  'job_line_operations',
  'job_line_receipts',
  'job_line_audits',
  'job_line_outgoing',
  'job_line_conflicts',
];

const companyMarkerTables = [
  ...priorCompanyMarkerTables,
  'company_bootstrap_witnesses',
  'company_jobs',
];

/// Query failures are deliberately propagated: only a complete empty scan
/// proves that a shop can use legacy routes without company authority.
Future<bool> hasCompanyStoreMarkers(AppDatabase db) async {
  for (final table in companyMarkerTables) {
    if ((await db.customSelect('SELECT 1 FROM $table LIMIT 1').get())
        .isNotEmpty) {
      return true;
    }
  }
  return false;
}

/// Serialize every legacy business mutation with company activation. The
/// no-op update takes SQLite's write lock before checking the markers, and
/// keeps that lock through the caller's mutation in the same transaction.
Future<T> legacyBusinessWrite<T>(AppDatabase db, Future<T> Function() write) {
  return db.transaction(() async {
    await db.customStatement(
      'UPDATE app_settings SET value = value WHERE key = ?',
      [kInstallationBindingKey],
    );
    if (await hasCompanyStoreMarkers(db)) {
      throw StateError(
        'This shop belongs to a company. Legacy edits are unavailable.',
      );
    }
    return write();
  });
}

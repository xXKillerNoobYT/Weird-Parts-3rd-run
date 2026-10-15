import '../../data/app_database.dart';

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

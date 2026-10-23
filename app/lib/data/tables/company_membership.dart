import 'package:drift/drift.dart';

class CompanyMembershipCertificates extends Table {
  TextColumn get grantId => text()();
  TextColumn get companyId => text()();
  TextColumn get proofCommitment => text().unique()();
  TextColumn get proofBytes => text()();
  TextColumn get issuerDeviceId => text()();
  IntColumn get issuerSequence => integer()();
  @override
  Set<Column> get primaryKey => {grantId};
  @override
  List<Set<Column>> get uniqueKeys => [
    {issuerDeviceId, issuerSequence},
  ];
}

class CompanyJoinRequests extends Table {
  TextColumn get requestId => text()();
  TextColumn get side => text()();
  TextColumn get requestCommitment => text()();
  TextColumn get requestBytes => text()();
  TextColumn get recipientInstallation => text()();
  TextColumn get recipientGeneration => text()();
  TextColumn get recipientKey => text()();
  TextColumn get certificateCommitment => text()();
  TextColumn get stage => text()();
  @override
  Set<Column> get primaryKey => {requestId};
}

class CompanyJoinEvents extends Table {
  TextColumn get requestId => text()();
  IntColumn get ordinal => integer()();
  TextColumn get kind => text()();
  TextColumn get evidenceBytes => text()();
  @override
  Set<Column> get primaryKey => {requestId, ordinal};
}

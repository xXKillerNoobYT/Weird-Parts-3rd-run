import 'package:drift/drift.dart';

class CompanyBootstrapWitnesses extends Table {
  TextColumn get companyId => text()();
  TextColumn get bootstrapId => text()();
  TextColumn get factsCommitment => text()();
  TextColumn get packageId => text()();
  TextColumn get packageDigest => text().nullable()();
  TextColumn get status => text()();

  @override
  Set<Column> get primaryKey => {companyId};
}

class CompanyAuthorityFacts extends Table {
  TextColumn get companyId => text()();
  TextColumn get commitment => text()();
  TextColumn get signedBytes => text()();
  @override
  Set<Column> get primaryKey => {companyId, commitment};
}

class JobLineBaselines extends Table {
  TextColumn get companyId => text()();
  TextColumn get lineId => text()();
  TextColumn get shopId => text()();
  TextColumn get baselineId => text()();
  TextColumn get baselineBytes => text()();
  TextColumn get projectionBytes => text()();
  @override
  Set<Column> get primaryKey => {companyId, lineId};
}

class JobLineOperations extends Table {
  TextColumn get companyId => text()();
  TextColumn get originGeneration => text()();
  TextColumn get requestId => text()();
  TextColumn get lineId => text()();
  TextColumn get commitment => text()();
  TextColumn get operationBytes => text()();
  BoolColumn get admitted => boolean()();
  @override
  Set<Column> get primaryKey => {companyId, originGeneration, requestId};
}

class JobLineReceipts extends Table {
  TextColumn get receiptKey => text()();
  TextColumn get companyId => text()();
  TextColumn get operationCommitment => text()();
  TextColumn get commandCommitment => text()();
  TextColumn get receiptBytes => text()();
  @override
  Set<Column> get primaryKey => {receiptKey};
}

class JobLineAudits extends Table {
  TextColumn get receiptKey => text()();
  TextColumn get auditBytes => text()();
  @override
  Set<Column> get primaryKey => {receiptKey};
}

class JobLineOutgoing extends Table {
  TextColumn get companyId => text()();
  TextColumn get originGeneration => text()();
  TextColumn get requestId => text()();
  TextColumn get operationCommitment => text()();
  @override
  Set<Column> get primaryKey => {companyId, originGeneration, requestId};
}

class JobLineConflicts extends Table {
  TextColumn get conflictId => text()();
  TextColumn get companyId => text()();
  TextColumn get lineId => text()();
  TextColumn get unit => text()();
  TextColumn get alternativesBytes => text()();
  @override
  Set<Column> get primaryKey => {conflictId};
}

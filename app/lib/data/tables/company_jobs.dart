import 'package:drift/drift.dart';

class CompanyJobs extends Table {
  TextColumn get jobId => text()();
  TextColumn get companyId => text()();
  TextColumn get shopId => text()();
  TextColumn get originGeneration => text()();
  TextColumn get requestId => text()();
  TextColumn get operationCommitment => text()();
  TextColumn get commandCommitment => text()();
  TextColumn get operationBytes => text()();
  TextColumn get projectionBytes => text()();
  TextColumn get receiptKey => text().unique()();
  TextColumn get receiptBytes => text()();
  TextColumn get auditBytes => text()();
  BoolColumn get outgoing => boolean()();

  @override
  Set<Column> get primaryKey => {jobId};

  @override
  List<Set<Column>> get uniqueKeys => [
    {companyId, originGeneration, requestId},
  ];
}

class CompanyJobPeerAcks extends Table {
  TextColumn get companyId => text()();
  TextColumn get originGeneration => text()();
  TextColumn get requestId => text()();
  TextColumn get peerDeviceId => text()();
  TextColumn get operationDigest => text()();
  TextColumn get ackBytes => text()();
  @override
  Set<Column> get primaryKey => {
    companyId,
    originGeneration,
    requestId,
    peerDeviceId,
  };
}

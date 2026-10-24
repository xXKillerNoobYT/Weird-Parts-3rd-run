import '../../data/app_database.dart';

abstract interface class PartWriteCompanion {
  void validatePhotoOperation();
  void photoReferenceCommitted();
  Future<void> beforePhotoReferenceWrite(AppDatabase db, String partId);
  Future<void> afterPhotoReferenceWrite(AppDatabase db, String partId);
}

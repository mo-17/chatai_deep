import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

export 'package:sqflite/sqflite.dart';

DatabaseFactory get databaseFactoryFfi => databaseFactoryFfiWeb;
void sqfliteFfiInit() => configureDatabasePlatform();
void configureDatabasePlatform() {
  databaseFactory = databaseFactoryFfiWeb;
}

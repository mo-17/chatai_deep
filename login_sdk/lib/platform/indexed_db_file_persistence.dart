import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'persistent_memory_file_system.dart';

class IndexedDbFilePersistence implements BrowserFilePersistence {
  IndexedDbFilePersistence(this.database);
  final web.IDBDatabase database;
  static Future<IndexedDbFilePersistence> open() async {
    final request = web.window.indexedDB.open('chatai_browser_files_v1', 1);
    request.onupgradeneeded = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      if (!database.objectStoreNames.contains('files')) {
        database.createObjectStore('files');
      }
    }).toJS;
    await _request(request);
    return IndexedDbFilePersistence(request.result as web.IDBDatabase);
  }

  static Future<void> _request(web.IDBRequest request) {
    final done = Completer<void>();
    request.onsuccess = ((web.Event _) => done.complete()).toJS;
    request.onerror = ((web.Event _) {
      done.completeError(StateError(
          '浏览器文件存储不可用：${request.error?.message ?? 'IndexedDB error'}'));
    }).toJS;
    return done.future;
  }

  @override
  Future<Map<String, Uint8List?>> load() async {
    final transaction = database.transaction('files'.toJS, 'readonly');
    final request = transaction.objectStore('files').getAll();
    await _request(request);
    final records = <String, Uint8List?>{};
    for (final value in (request.result as JSArray<JSString>).toDart) {
      final record = jsonDecode(value.toDart) as Map<String, dynamic>;
      records[record['path'] as String] = record['bytes'] == null
          ? null
          : base64Decode(record['bytes'] as String);
    }
    return records;
  }

  @override
  Future<void> commit(Map<String, Uint8List?> writes, Set<String> deletes) {
    final transaction = database.transaction('files'.toJS, 'readwrite');
    final done = Completer<void>();
    transaction.oncomplete = ((web.Event _) => done.complete()).toJS;
    void failure(web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError(
            '浏览器文件写入失败：${transaction.error?.message ?? 'IndexedDB transaction aborted'}'));
      }
    }

    transaction.onerror = failure.toJS;
    transaction.onabort = failure.toJS;
    final store = transaction.objectStore('files');
    for (final path in deletes) {
      store.delete(path.toJS);
    }
    for (final entry in writes.entries) {
      store.put(
          jsonEncode({
            'path': entry.key,
            'bytes': entry.value == null ? null : base64Encode(entry.value!)
          }).toJS,
          entry.key.toJS);
    }
    return done.future;
  }
}

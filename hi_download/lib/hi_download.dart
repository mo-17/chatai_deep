import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

typedef DownLoadListener = void Function(int total, int received, bool done);

class HiDownLoad {
  int _total = 0, _received = 0;

  Future<String> download(
      {required String downLoadUrl,
      required String fileName,
      required DownLoadListener listener}) async {
    debugPrint('start download.');
    var uri = Uri.parse(downLoadUrl);
    var request = http.Request('GET', uri);
    // request.headers.addAll(hiHeaders());
    var response = await http.Client().send(request);
    _total = response.contentLength ?? 0;
    var path = (await getApplicationDocumentsDirectory()).path;
    final file = File('$path/$fileName');
    final writeFile = file.openSync(mode: FileMode.write);
    //采用stream避免内存占用，提升性能
    response.stream.listen((value) {
      writeFile.writeFromSync(value);
      _received += value.length;
      listener(_total, _received, false);
      debugPrint('progress:${_received / _total}');
    }).onDone(() async {
      await writeFile.close();
      listener(_total, _received, true);
      debugPrint('---done---');
    });
    return file.absolute.path;
  }
}

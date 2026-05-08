import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hi_download/hi_download.dart';

class HiDownLoadPage extends StatefulWidget {
  const HiDownLoadPage({Key? key}) : super(key: key);

  @override
  State<HiDownLoadPage> createState() => _HiDownLoadPageState();
}

class _HiDownLoadPageState extends State<HiDownLoadPage> {
  get _download =>
      ElevatedButton(onPressed: _doDownLoad, child: const Text('下载'));
  File? imageFile;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载文件并展示'),
      ),
      body: Column(
        children: [_download, if (imageFile != null) Image.file(imageFile!)],
      ),
    );
  }

  void _doDownLoad() async {
    String? path;
    path = await HiDownLoad().download(
        downLoadUrl: 'https://www.devio.org/img/bg-flutter-new.jpg',
        fileName: 'bg-flutter-new.jpg',
        listener: (int total, int received, bool done) {
          if (done) {
            setState(() {
              imageFile = File(path!);
            });
          }
        });
    debugPrint('path:$path');
  }
}

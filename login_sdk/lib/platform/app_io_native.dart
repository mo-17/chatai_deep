import 'dart:io';

export 'dart:io';

File appFile(String path) => File(path);
File appFileFromUri(Uri uri) => File.fromUri(uri);
Directory appDirectory(String path) => Directory(path);
Directory get appTemporaryDirectory => Directory.systemTemp;
Future<FileSystemEntityType> appFileType(String path,
        {bool followLinks = true}) =>
    FileSystemEntity.type(path, followLinks: followLinks);
Future<void> initializeBrowserFileSystem() async {}

import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/story_room_image_service.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('story-room-image-');
  });

  tearDown(() async {
    LoginSdkConfig.reset();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('saveEvent 隐式账号在异步 resolver 切号后 fail closed', () async {
    final authStorage = await _installAccount('account-a');
    final encoded = base64Encode([1, 2, 3]);

    await expectLater(
      StoryRoomImageService.saveEvent(
        StreamEvent.image('data:image/png;base64,$encoded'),
        directoryResolver: () async {
          await authStorage.writeProfile(
            token: 'token-b',
            userName: 'user-b',
            extras: const {'accountHash': 'account-b'},
          );
          return tempDir;
        },
      ),
      throwsA(isA<LoginAccountChangedException>()),
    );
    for (final account in ['account-a', 'account-b']) {
      final directory = Directory(
        '${tempDir.path}/generated_images/accounts/'
        '${AccountResourceScope.tokenFor(account)}',
      );
      expect(directory.existsSync(), isFalse);
    }
  });

  test('规范化 URL 图片事件并保存到应用相册', () async {
    final source = StoryRoomImageService.normalize(
      StreamEvent.image(' HTTPS://img.example/cover.jpg?token=1 '),
    );

    expect(source?.kind, StoryRoomImageSourceKind.url);
    expect(source?.value, 'https://img.example/cover.jpg?token=1');
    expect(source?.extension, '.jpg');

    final client = MockClient((request) async {
      expect(request.url.toString(), source!.value);
      return http.Response.bytes([1, 2, 3], 200);
    });
    final saved = await StoryRoomImageService.saveEvent(
      StreamEvent.image(' HTTPS://img.example/cover.jpg?token=1 '),
      filename: '../房间/cover?.jpg',
      directoryResolver: () async => tempDir,
      client: client,
      accountHash: 'guest',
    );

    expect(
      saved?.path,
      endsWith(
        '/generated_images/accounts/'
        '${AccountResourceScope.tokenFor('guest')}/cover.jpg',
      ),
    );
    expect(await File(saved!.path).readAsBytes(), [1, 2, 3]);
  });

  test('规范化 base64 图片事件并保存', () async {
    final encoded = base64Encode([4, 5, 6]);
    final saved = await StoryRoomImageService.saveEvent(
      StreamEvent.image('data:image/PNG;base64,$encoded'),
      now: DateTime(2026, 7, 10, 12, 30, 1),
      directoryResolver: () async => tempDir,
      accountHash: 'guest',
    );

    expect(saved?.source, 'data:image/png;base64,$encoded');
    expect(saved?.sourceKind, StoryRoomImageSourceKind.dataUri);
    expect(await File(saved!.path).readAsBytes(), [4, 5, 6]);
  });

  test('规范化本地路径图片并保存', () async {
    final local = File('${tempDir.path}/local.webp');
    await local.writeAsBytes([7, 8]);

    final source =
        StoryRoomImageService.normalize(StreamEvent.image(local.path));
    expect(source?.kind, StoryRoomImageSourceKind.localPath);
    expect(source?.suggestedFilename, 'local.webp');

    final saved = await StoryRoomImageService.saveEvent(
      StreamEvent.image(local.path),
      directoryResolver: () async => tempDir,
      accountHash: 'guest',
    );
    expect(saved?.source, local.path);
    expect(await File(saved!.path).readAsBytes(), [7, 8]);
  });

  test('安全文件名只保留图片文件名且阻断路径穿越', () {
    expect(
      StoryRoomImageSource.safeFilename('../房间/cover?.jpg'),
      'cover.jpg',
    );
    expect(
      StoryRoomImageSource.safeFilename('..', extension: '.webp'),
      'generated_image.webp',
    );
    expect(StoryRoomImageSource.safeFilename('plain'), 'plain.png');
  });

  test('保存图片后可写入并从 StoryMessageModel / DAO 往返读取', () async {
    final saved = await StoryRoomImageService.saveEvent(
      StreamEvent.image(
        'data:image/png;base64,${base64Encode([9, 10])}',
      ),
      filename: 'message.png',
      directoryResolver: () async => tempDir,
      accountHash: 'guest',
    );
    final message = StoryMessageModel(
      roomId: 1,
      speakerRole: StoryParticipantRole.assistant,
      speakerName: '画师',
      content: '一张图',
    );
    saved!.attachTo(message);
    message.citationUrls = ['https://example.com/source'];

    final encoded = message.toJson();
    final decoded = StoryMessageModel.fromJson(encoded);
    expect(decoded.imagePaths, [saved.path]);
    expect(decoded.imageSources, [saved.source]);
    expect(decoded.citationUrls, ['https://example.com/source']);

    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final dao = await StoryRoomDao.create(HiDBManager.test(db));
    final roomId = await dao.saveRoom(StoryRoomModel(title: '图片房间'));
    message.roomId = roomId;
    await dao.saveMessage(message);
    final stored = (await dao.getMessages(roomId)).single;
    expect(stored.imagePaths, [saved.path]);
    expect(stored.imageSources, [saved.source]);
    expect(stored.citationUrls, ['https://example.com/source']);
  });
}

Future<_MemoryTokenStorage> _installAccount(String accountHash) async {
  final storage = _MemoryTokenStorage();
  await storage.writeProfile(
    token: 'token-a',
    userName: 'user-a',
    extras: {'accountHash': accountHash},
  );
  LoginSdkConfig.install(LoginSdkConfig(
    baseUrl: 'localhost:3000',
    headerProvider: () async => const {},
    syncHeaders: () => const {},
    routes: LoginRoutes.imooc,
    responseAdapter: ImoocResponseAdapter(),
    storage: storage,
    onLogoutNavigate: () {},
  ));
  return storage;
}

final class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;

  @override
  Future<void> clear() async => _profile = null;

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  Map<String, dynamic>? readProfileSync() =>
      _profile == null ? null : Map<String, dynamic>.from(_profile!);

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    _profile = {
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      ...extras,
    };
  }
}

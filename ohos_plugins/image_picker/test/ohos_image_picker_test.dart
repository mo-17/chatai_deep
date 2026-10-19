import 'package:chatai_ohos_image_picker/ohos_image_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.hzb.flutter_ai/image_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('通用恢复调用不读取其他账号/会话的草稿', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'retrieveLostData');
      expect(call.arguments, isNull);
      return null;
    });
    expect((await OhosImagePicker().getLostData()).isEmpty, isTrue);
  });
  test('注册到现有 image_picker 接口并传递相册缩放选项', () async {
    final original = ImagePickerPlatform.instance;
    addTearDown(() => ImagePickerPlatform.instance = original);
    OhosImagePicker.registerWith();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickImage');
      expect(call.arguments['source'], 'gallery');
      expect(call.arguments['maxWidth'], 512);
      expect(call.arguments['quality'], 80);
      return {
        'path': '/cache/avatar.png',
        'name': 'avatar.png',
        'mimeType': 'image/png',
      };
    });
    final picked = await ImagePickerPlatform.instance.getImageFromSource(
      source: ImageSource.gallery,
      options: const ImagePickerOptions(maxWidth: 512, imageQuality: 80),
    );
    expect(picked!.path, '/cache/avatar.png');
    expect(picked.mimeType, 'image/png');
  });
  test('拍照前置选项、取消与错误分别传递', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments['source'], 'camera');
      expect(call.arguments['frontCamera'], true);
      return null;
    });
    expect(
      await OhosImagePicker().getImageFromSource(
        source: ImageSource.camera,
        options: const ImagePickerOptions(
          preferredCameraDevice: CameraDevice.front,
        ),
      ),
      isNull,
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'permission'),
    );
    await expectLater(
      OhosImagePicker().getImageFromSource(source: ImageSource.gallery),
      throwsA(isA<PlatformException>()),
    );
  });
  test('选项或原生结果无效时拒绝继续', () async {
    await expectLater(
      OhosImagePicker().getImageFromSource(
        source: ImageSource.gallery,
        options: const ImagePickerOptions(maxWidth: -1),
      ),
      throwsArgumentError,
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'path': 'file://uri'},
    );
    await expectLater(
      OhosImagePicker().getImageFromSource(source: ImageSource.gallery),
      throwsFormatException,
    );
  });
  test('多图选项传入系统通道、限制单批数量并保留顺序去重', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickImages');
      expect(call.arguments['source'], 'gallery');
      expect(call.arguments['limit'], 10);
      expect(call.arguments['maxWidth'], 512);
      return [
        for (final name in ['a', 'b', 'a'])
          {
            'path': '/cache/$name.png',
            'name': '$name.png',
            'mimeType': 'image/png',
          },
      ];
    });
    final files = await OhosImagePicker().getMultiImageWithOptions(
      options: const MultiImagePickerOptions(
        imageOptions: ImageOptions(maxWidth: 512),
        limit: 20,
      ),
    );
    expect(files.map((f) => f.path), ['/cache/a.png', '/cache/b.png']);
  });
  test('多选取消返回空集合，异常结果或无效选项被拒绝', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await OhosImagePicker().getMultiImageWithOptions(), isEmpty);
    await expectLater(
      OhosImagePicker().getMultiImageWithOptions(
        options: const MultiImagePickerOptions(limit: 1),
      ),
      throwsArgumentError,
    );
    for (final rows in [
      [1],
      [
        {'path': '/cache/../a', 'name': 'a', 'mimeType': 'image/png'},
      ],
      List.generate(
        11,
        (_) => {'path': '/cache/a', 'name': 'a', 'mimeType': 'image/png'},
      ),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => rows);
      await expectLater(
        OhosImagePicker().getMultiImageWithOptions(),
        throwsFormatException,
      );
    }
  });
}

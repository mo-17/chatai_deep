import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/assistant_conversation_avatar_resolver.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('approved assistant switch is applied and DAO-persistable', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final dao = await ConversationListDao.create(HiDBManager.test(db));
    final conversation = ConversationModel(cid: 501, icon: '')
      ..title = '切换助手'
      ..updateAt = 501
      ..voiceStyle = 'female';
    final assistant = AssistantModel(
      id: 71,
      name: '星核创作者',
      avatarType: AvatarAssetService.assetType,
      avatarValue: StarcoreIconAssets.assistantCreatorId,
      defaultVoiceStyle: 'bright',
    );

    AssistantConversationAvatarResolver.applySwitch(
      conversation,
      assistant,
    );
    await dao.saveConversation(conversation);
    final stored = (await dao.getConversationList()).single;

    expect(stored.assistantId, 71);
    expect(stored.avatarType, AvatarAssetService.assetType);
    expect(stored.avatarValue, StarcoreIconAssets.assistantCreatorId);
    expect(stored.voiceStyle, 'bright');
  });

  test('unknown asset cannot persist as a conversation avatar or encode',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final dao = await ConversationListDao.create(HiDBManager.test(db));
    final conversation = ConversationModel(cid: 502, icon: '')
      ..title = '未知头像'
      ..updateAt = 502
      ..avatarType = AvatarAssetService.assetType
      ..avatarValue = StarcoreIconAssets.assistantExplorerId;
    final assistant = AssistantModel(
      id: 72,
      name: '未知头像',
      emoji: '',
      avatarType: AvatarAssetService.assetType,
      avatarValue: 'starcore_unknown',
    );

    AssistantConversationAvatarResolver.applySwitch(
      conversation,
      assistant,
    );
    await dao.saveConversation(conversation);
    final stored = (await dao.getConversationList()).single;

    expect(stored.assistantId, 72);
    expect(stored.avatarType, isNull);
    expect(stored.avatarValue, isNull);
    expect(
      AssistantConversationAvatarResolver.nextMessageAvatar(assistant),
      isNull,
    );
  });

  test('next-message protocol is nullable and only encodes approved assets',
      () {
    final approved = AssistantModel(
      name: '星核向导',
      avatarType: AvatarAssetService.assetType,
      avatarValue: StarcoreIconAssets.assistantExplorerId,
    );
    final unknown = AssistantModel(
      name: '未知头像',
      emoji: '',
      avatarType: AvatarAssetService.assetType,
      avatarValue: 'starcore_unknown',
    );

    expect(
      AssistantConversationAvatarResolver.nextMessageAvatar(approved),
      '${StarcoreIconAssets.messageAssetPrefix}'
      '${StarcoreIconAssets.assistantExplorerId}',
    );
    expect(
      AssistantConversationAvatarResolver.nextMessageAvatar(unknown),
      isNull,
    );
    expect(
      AssistantConversationAvatarResolver.nextMessageAvatar(null),
      isNull,
    );
  });

  test('switching assistants leaves stored message avatars unchanged',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final storage = HiDBManager.test(db);
    final messageDao = await MessageDao.create(storage, cid: 503);
    final existing = MessageModel(
      ownerType: OwnerType.receiver,
      ownerName: '旧向导',
      avatar: '${StarcoreIconAssets.messageAssetPrefix}'
          '${StarcoreIconAssets.assistantExplorerId}',
      content: '旧消息',
      createdAt: 1,
    );
    await messageDao.saveMessageWithBlocks(existing);
    final conversation = ConversationModel(cid: 503, icon: '');
    final nextAssistant = AssistantModel(
      id: 73,
      name: '星核创作者',
      avatarType: AvatarAssetService.assetType,
      avatarValue: StarcoreIconAssets.assistantCreatorId,
    );

    AssistantConversationAvatarResolver.applySwitch(
      conversation,
      nextAssistant,
    );
    final stored = (await messageDao.getAllMessage()).single;

    expect(stored.avatar, existing.avatar);
    expect(
      AssistantConversationAvatarResolver.nextMessageAvatar(nextAssistant),
      '${StarcoreIconAssets.messageAssetPrefix}'
      '${StarcoreIconAssets.assistantCreatorId}',
    );
  });
}

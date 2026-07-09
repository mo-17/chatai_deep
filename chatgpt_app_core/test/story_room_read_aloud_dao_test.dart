import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('旧酒馆表自动补齐音色列，并在保存消息时写入角色音色快照', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute(
        'create table tb_story_room (id integer primary key autoincrement, title text, mode text, replyMode text, maxAutoReplies integer, publicContext text, modelProviderId text, modelId text, temperature real, maxOutputTokens integer, createdAt integer, updatedAt integer)');
    await db.execute(
        'create table tb_story_participant (id integer primary key autoincrement, roomId integer not null, assistantId integer, role text, name text, prompt text, avatarType text, avatarValue text, sortOrder integer, enabled integer, createdAt integer, updatedAt integer)');
    await db.execute(
        'create table tb_story_message (id integer primary key autoincrement, roomId integer not null, speakerId integer, speakerRole text, speakerName text, speakerAvatarType text, speakerAvatarValue text, content text, createdAt integer)');

    final dao = await StoryRoomDao.create(HiDBManager.test(db));
    final roomId = await dao.saveRoom(StoryRoomModel(title: '音色兼容'));
    final participant = StoryParticipantModel(
      roomId: roomId,
      role: StoryParticipantRole.assistant,
      name: '风香',
      voiceStyle: TtsVoiceStyle.deep.id,
    );
    await dao.saveParticipant(participant);
    await dao.saveMessage(StoryMessageModel(
      roomId: roomId,
      speakerId: participant.id,
      speakerRole: participant.role,
      speakerName: participant.name,
      content: '低沉地说。',
    ));

    expect((await dao.getParticipants(roomId)).single.voiceStyle,
        TtsVoiceStyle.deep.id);
    expect((await dao.getMessages(roomId)).single.speakerVoiceStyle,
        TtsVoiceStyle.deep.id);
  });
}

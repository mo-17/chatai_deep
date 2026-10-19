import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/sync/local_sync_service.dart';
import 'package:chatgpt_app_core/sync/cloud_sync_client.dart';
import '../../login_sdk/test/support/memory_token_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final credentialPath=Platform.environment['CHATAI_LIVE_CREDENTIALS'];
  test('two isolated clients sync through trusted production TLS and preserve equal-time conflicts',() async {
    final origin=BackendConst.buildUri('/');
    expect(origin.scheme,'https');expect(origin.host,'kushui.shop');expect(origin.port,443);
    final file=File(credentialPath!);expect(file.statSync().mode&0x3f,0);
    final credentials=jsonDecode(await file.readAsString()) as Map;
    expect(credentials['baseUrl'],'https://kushui.shop');
    final previous=LoginSdkConfig.instance;
    final previousHttp=HttpOverrides.current;
    final storage=MemoryTokenStorage();
    final directory=await Directory.systemTemp.createTemp('chatai-two-clients-');
    final databases=<Database>[];
    final clients=<CloudSyncClient>[];
    LoginSdkConfig.install(previous.copyWith(storage:storage));
    HttpOverrides.global=null;
    try {
      final result=await AuthDaoBridge.instance.loginByPassword(channel:'email',identifier:credentials['email'],password:credentials['password']);
      final attempt=LoginDao.beginAuthAttempt();
      await LoginDao.saveAuthTokenForAttempt(result.token,attempt:attempt,userName:result.extra['userName'],extras:result.extra);
      final account=LoginDao.getAccountHash()!;
      Future<(HiDBManager,CloudSyncClient)> client(String name) async {
        final db=await databaseFactoryFfi.openDatabase('${directory.path}/$name.sqlite');databases.add(db);
        final manager=HiDBManager.test(db);
        final client=CloudSyncClient(localSync:LocalSyncService(manager,accountHash:account),cursorStore:MemorySyncCursorStore(deviceId:'p0p1-$name'));
        clients.add(client);return (manager,client);
      }
      final (a,clientA)=await client('a');final (b,clientB)=await client('b');
      final daoA=await ConversationListDao.create(a);
      final daoB=await ConversationListDao.create(b);
      final now=DateTime.now().millisecondsSinceEpoch;
      final cid=now*10+7;
      await daoA.saveConversation(ConversationModel(cid:cid,icon:'QA',title:'P0P1 temporary sync A',updateAt:now));
      await clientA.syncOnce();await clientB.syncOnce();
      expect((await daoB.getConversationList()).single.title,'P0P1 temporary sync A');
      final bRow=(await daoB.getConversationList()).single;
      bRow.title='P0P1 temporary sync B';await daoB.saveConversation(bRow);
      await b.db.update('tb_conversation_list',{'updateAt':now+100},where:'cid=?',whereArgs:[cid]);
      await clientB.syncOnce();await clientA.syncOnce();
      expect((await daoA.getConversationList()).single.title,'P0P1 temporary sync B');
      await a.db.update('tb_conversation_list',{'title':'P0P1 offline local A','updateAt':now+200},where:'cid=?',whereArgs:[cid]);
      await b.db.update('tb_conversation_list',{'title':'P0P1 offline local B','updateAt':now+200},where:'cid=?',whereArgs:[cid]);
      await clientB.syncOnce();
      final conflict=await clientA.syncOnce();
      expect(conflict.hasConflict,true);
      expect((await daoA.getConversationList()).single.title,'P0P1 offline local A');
      expect((await daoB.getConversationList()).single.title,'P0P1 offline local B');
    } finally {
      for(final client in clients)client.close();
      for(final db in databases)await db.close();
      await directory.delete(recursive:true);
      AuthDaoBridge.client.dispose();await storage.clear();LoginSdkConfig.install(previous);HttpOverrides.global=previousHttp;
    }
  },skip:credentialPath==null,timeout:const Timeout(Duration(minutes:2)));
}

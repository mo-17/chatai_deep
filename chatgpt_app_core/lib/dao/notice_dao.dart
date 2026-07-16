import 'dart:convert';

import 'package:chatgpt_app_core/dao/hi_api_cache.dart';
import 'package:chatgpt_app_core/model/notice_model.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/header_util.dart';

typedef HitCache<T> = Function(T cache);

///更多课程
class NoticeDao {
  ///过期时间设置为1小时
  static const expireTime = 60 * 60 * 1000;

  ///https://api.devio.org/uapi/notice/banner?pageIndex=1&pageSize=100
  static noticeList(
      {int pageIndex = 1,
      int pageSize = 100,
      HitCache<NoticeModel>? hitCache}) async {
    final paramsMap = <String, String>{
      'pageIndex': pageIndex.toString(),
      'pageSize': pageSize.toString(),
    };
    final uri = BackendConst.buildUri('uapi/notice/banner', paramsMap);
    //处理缓存
    _handleCache(hitCache, uri);
    final response = await http
        .get(uri, headers: hiHeaders())
        .timeout(const Duration(seconds: 15));
    const utf8decoder = Utf8Decoder();
    final bodyString = utf8decoder.convert(response.bodyBytes);
    if (response.statusCode == 200) {
      final result = json.decode(bodyString);
      if (result['code'] == 0 && result['data'] != null) {
        final data = result['data'];
        //更新缓存
        HiAPICache.getInstance().setCache(uri.toString(), jsonEncode(data));
        return NoticeModel.fromJson(result['data']);
      } else {
        throw Exception(bodyString);
      }
    } else {
      throw Exception(bodyString);
    }
  }

  ///处理缓存
  static void _handleCache(HitCache<NoticeModel>? hitCache, Uri uri) {
    if (hitCache != null) {
      final cacheString =
          HiAPICache.getInstance().getCache(uri.toString(), expire: expireTime);
      if (cacheString != null) {
        hitCache(NoticeModel.fromJson(json.decode(cacheString)));
      }
    }
  }
}

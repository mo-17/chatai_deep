import 'dart:convert';

import 'package:chatgpt_flutter/model/apk_model.dart';
import 'package:chatgpt_flutter/util/hi_const.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/header_util.dart';
import 'package:package_info_plus/package_info_plus.dart';

class ApkUpdateDao {
  //  https://api.devio.org/uapi/checkUpdate?cid=321&version=1.0
  static checkUpdate() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    //获取APP版本号
    String version = packageInfo.version;
    Map<String, String> paramsMap = {};
    paramsMap['cid'] = '321';
    paramsMap['version'] = version;
    var uri = Uri.http(BackendConst.host, 'uapi/checkUpdate', paramsMap);
    final response = await http.get(uri, headers: hiHeaders());
    Utf8Decoder utf8decoder = const Utf8Decoder();
    String bodyString = utf8decoder.convert(response.bodyBytes);
    if (response.statusCode == 200) {
      var result = json.decode(bodyString);
      if (result['code'] == 0 && result['data'] != null) {
        return ApkModel.fromJson(result['data']);
      } else {
        throw Exception(bodyString);
      }
    } else {
      throw Exception(bodyString);
    }
  }
}

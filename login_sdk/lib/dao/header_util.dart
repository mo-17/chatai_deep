import 'package:login_sdk/dao/login_dao.dart';

///接口所需请求header信息，auth-token可从问答区获取
Map<String, String> hiHeaders() {
  return {
    "auth-token": 'YOUR_COURSE_AUTH_TOKEN',
    "course-flag": 'fg',
    'boarding-pass': LoginDao.getBoardingPass() ?? ""
  };
}

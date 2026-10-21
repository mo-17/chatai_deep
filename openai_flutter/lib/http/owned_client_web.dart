import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

// 浏览器网络遵守同源/CORS；不能配置操作系统 HTTP 代理。
http.Client createOwnedAIClient(String? proxy) => BrowserClient();

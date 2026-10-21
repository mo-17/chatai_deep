import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createOwnedAIClient(String? proxy) {
  final client = HttpClient();
  if (proxy != null && proxy.trim().isNotEmpty) {
    client.findProxy = (_) => 'PROXY $proxy';
  }
  return IOClient(client);
}

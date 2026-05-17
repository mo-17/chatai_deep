import 'package:flutter/material.dart';
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';

import 'mock_sse_server.dart';

late final int _mockPort;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final mock = MockSseServer();
  _mockPort = await mock.start(port: 0);
  // ignore: avoid_print
  print('[example] mock SSE server on 127.0.0.1:$_mockPort');
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'openai_flutter example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF10A37F)),
        useMaterial3: true,
      ),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _inputCtrl = TextEditingController(text: 'Hello, who are you?');
  final List<_Msg> _messages = [];
  bool _streaming = false;
  String _streamingBuffer = '';

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _streaming) return;
    _inputCtrl.clear();

    setState(() {
      _messages.add(_Msg(role: 'user', content: text));
      _streaming = true;
      _streamingBuffer = '';
    });

    // 使用本地 mock。换成真实 OpenAI 时把 chatUrl 改为
    // 'https://api.openai.com/v1/chat/completions'，apiKey 换成真 key。
    final config = AIConfigBuilder(
      apiKey: 'mock-key',
      chatUrl: 'http://127.0.0.1:$_mockPort/v1/chat/completions',
    );

    final completion = AICompletion(config);
    final history = _messages.map((m) => {'role': m.role, 'content': m.content}).toList();

    try {
      await for (final token in completion.createChatStream(
        model: 'gpt-3.5-turbo',
        messages: history,
        maxTokens: null,
      )) {
        if (!mounted) return;
        setState(() => _streamingBuffer += token);
      }
      if (mounted) {
        setState(() {
          _messages.add(_Msg(role: 'assistant', content: _streamingBuffer));
          _streaming = false;
          _streamingBuffer = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(_Msg(role: 'assistant', content: '[error] $e'));
          _streaming = false;
          _streamingBuffer = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = [
      ..._messages,
      if (_streaming) _Msg(role: 'assistant', content: _streamingBuffer, streaming: true),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('openai_flutter · streaming demo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _streaming ? null : () => setState(_messages.clear),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _hintBar(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: all.length,
                itemBuilder: (_, i) => _bubble(all[i]),
              ),
            ),
            _inputBar(),
          ],
        ),
      ),
    );
  }

  Widget _hintBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: const Color(0xFFE8F5E9),
      child: Text(
        'Mock SSE server on 127.0.0.1:$_mockPort — replies are simulated, no API key needed.',
        style: TextStyle(fontSize: 11, color: Colors.green.shade900),
      ),
    );
  }

  Widget _bubble(_Msg m) {
    final isUser = m.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFFDCF8C6) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x14000000)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isUser ? 'You' : 'Assistant',
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 4),
            Text(m.content.isEmpty && m.streaming ? '…' : m.content),
          ],
        ),
      ),
    );
  }

  Widget _inputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0x1A000000))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: _streaming ? 'streaming…' : 'Ask anything…',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
              ),
            ),
          ),
          IconButton.filled(
            icon: _streaming
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send),
            onPressed: _streaming ? null : _send,
          ),
        ],
      ),
    );
  }
}

class _Msg {
  final String role;
  final String content;
  final bool streaming;
  _Msg({required this.role, required this.content, this.streaming = false});
}

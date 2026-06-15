import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'chat_message example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F3460)),
        useMaterial3: true,
      ),
      home: const ChatDemoPage(),
    );
  }
}

class ChatDemoPage extends StatefulWidget {
  const ChatDemoPage({super.key});

  @override
  State<ChatDemoPage> createState() => _ChatDemoPageState();
}

class _ChatDemoPageState extends State<ChatDemoPage> {
  late final ChatController _controller;
  final _inputCtrl = TextEditingController();
  int _counter = 0;

  // mock 历史消息
  final _seed = <MessageModel>[
    MessageModel(
      ownerType: OwnerType.receiver,
      ownerName: 'Bot',
      content: 'Welcome! Type a message below — I will echo it after a short delay.',
      createdAt: DateTime.now().millisecondsSinceEpoch - 60000,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _controller = ChatController(
      initialMessageList: _seed,
      itemScrollController: ItemScrollController(),
      itemPositionsListener: ItemPositionsListener.create(),
      timePellet: 60,
    );
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    _inputCtrl.clear();

    // 1) 立刻插入用户消息
    _controller.addMessage(MessageModel(
      ownerType: OwnerType.sender,
      ownerName: 'Me',
      content: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));

    // 2) 1.2s 后 bot 回复（模拟异步响应）
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      _controller.addMessage(MessageModel(
        ownerType: OwnerType.receiver,
        ownerName: 'Bot',
        content: 'You said: "$text"  (#${++_counter})',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    });
  }

  void _loadMore() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _controller.loadMoreData([
      MessageModel(
        ownerType: OwnerType.receiver,
        ownerName: 'Bot',
        content: 'Older message #${DateTime.now().microsecond}',
        createdAt: now - 600000,
      ),
      MessageModel(
        ownerType: OwnerType.sender,
        ownerName: 'Me',
        content: 'Another archived line',
        createdAt: now - 605000,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('chat_message · example'),
        actions: [
          IconButton(
            tooltip: 'Prepend older messages',
            icon: const Icon(Icons.history),
            onPressed: _loadMore,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Container(
                color: const Color(0xFFF5F5F7),
                child: ChatList(
                  chatController: _controller,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  onBubbleTap: (msg, _) =>
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Tapped: ${msg.content}'),
                    duration: const Duration(milliseconds: 800),
                  )),
                ),
              ),
            ),
            _inputBar(),
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
                hintText: 'Type a message…',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          IconButton.filled(
            icon: const Icon(Icons.send),
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}

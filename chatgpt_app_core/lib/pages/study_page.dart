import 'package:chatgpt_app_core/pages/story_room_list_page.dart';
import 'package:flutter/material.dart';

/// 创作模式入口：复用原「学习」Tab，承载酒馆/小说创作房间。
class StudyPage extends StatelessWidget {
  const StudyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const StoryRoomListPage();
  }
}

import 'package:flutter/material.dart';
import 'voice_conversation_controller.dart';

class VoiceConversationPanel extends StatelessWidget {
  final VoiceConversationController controller;
  final VoidCallback onClose;
  const VoiceConversationPanel(
      {super.key, required this.controller, required this.onClose});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final c = controller;
          final label = switch (c.phase) {
            VoiceConversationPhase.idle => '连续语音对话',
            VoiceConversationPhase.preparing => '正在准备麦克风…',
            VoiceConversationPhase.listening => '正在听你说话',
            VoiceConversationPhase.thinking => '正在回答',
            VoiceConversationPhase.speaking => '正在播报',
            VoiceConversationPhase.paused => '已暂停',
            VoiceConversationPhase.error => '本轮已暂停',
            VoiceConversationPhase.ended => '已结束',
          };
          return SafeArea(
              top: false,
              child: Container(
                key: const ValueKey('voice_conversation_panel'),
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    border: Border(
                        top:
                            BorderSide(color: Theme.of(context).dividerColor))),
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(c.phase == VoiceConversationPhase.listening
                              ? Icons.mic
                              : Icons.headphones),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(label,
                                  style:
                                      Theme.of(context).textTheme.titleMedium)),
                          IconButton(
                              tooltip: '结束语音对话',
                              onPressed: onClose,
                              icon: const Icon(Icons.close)),
                        ]),
                        if (c.phase == VoiceConversationPhase.idle)
                          const Text(
                              '说完一句会自动发送给当前 AI。系统语音识别可能联网，AI 请求计入当前服务额度。外放时轮流收音，避免回声；连接通话耳机后可开启说话打断。'),
                        if (c.audioRoute != null && !c.active)
                          SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              value: c.handsFree,
                              title: const Text('耳机说话打断'),
                              onChanged: c.enableHandsFree),
                        if (c.heard.isNotEmpty)
                          Text('你：${c.heard}',
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                        if (c.reply.isNotEmpty)
                          Text('AI：${c.reply}',
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                        if (c.note.isNotEmpty)
                          Text(c.note,
                              key: const ValueKey('voice_conversation_note')),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          if (!c.active &&
                              c.phase != VoiceConversationPhase.ended)
                            FilledButton.icon(
                                onPressed: () => c.start(),
                                icon: const Icon(Icons.mic),
                                label: Text(
                                    c.phase == VoiceConversationPhase.idle
                                        ? '开始语音对话'
                                        : '继续对话')),
                          if (c.active)
                            OutlinedButton.icon(
                                onPressed: () => c.pause(),
                                icon: const Icon(Icons.pause),
                                label: const Text('暂停')),
                          if (c.phase == VoiceConversationPhase.speaking)
                            FilledButton.icon(
                                onPressed: () => c.interrupt(),
                                icon: const Icon(Icons.record_voice_over),
                                label: const Text('打断并说话')),
                        ]),
                      ],
                    )),
              ));
        },
      );
}

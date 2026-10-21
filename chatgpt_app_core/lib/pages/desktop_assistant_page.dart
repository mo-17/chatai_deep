import 'package:flutter/material.dart';
import '../platform/desktop_quick_assistant.dart';

class DesktopAssistantPage extends StatelessWidget {
  const DesktopAssistantPage({super.key});
  @override
  Widget build(BuildContext context) {
    final service=DesktopQuickAssistant.instance;
    return Scaffold(appBar:AppBar(title:const Text('桌面快捷助手')),body:ListenableBuilder(listenable:service,builder:(context,_)=>ListView(padding:const EdgeInsets.all(16),children:[
      SwitchListTile(title:const Text('启用全局快捷键和托盘'),subtitle:const Text('启用后关闭窗口会驻留托盘，可从托盘菜单退出'),value:service.enabled,onChanged:(value)=>service.configure(value)),
      const ListTile(title:Text('Ctrl + Shift + 空格'),subtitle:Text('显示或隐藏艾普窗口')),
      const ListTile(title:Text('Ctrl + Shift + O'),subtitle:Text('框选截图，保存到 OCR 任务中心；上传前仍需确认')),
      const Padding(padding:EdgeInsets.all(12),child:Text('截图仅在你点击或按快捷键后发生。macOS 首次使用可能需要在系统设置中授予屏幕录制权限。')),
      if(service.error!=null) Padding(padding:const EdgeInsets.all(12),child:Text(service.error!)),
      Wrap(spacing:12,runSpacing:8,children:[FilledButton.icon(onPressed:service.capture,icon:const Icon(Icons.screenshot_monitor),label:const Text('截图 OCR')),
        OutlinedButton(onPressed:service.openTasks,child:const Text('打开 OCR 任务中心'))]),
    ])));
  }
}

import 'dart:io';

import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter/material.dart';

class AssistantAvatar extends StatelessWidget {
  final AssistantModel? assistant;
  final String emoji;
  final String? avatarType;
  final String? avatarValue;
  final double radius;

  const AssistantAvatar({
    super.key,
    required this.assistant,
    this.radius = 20,
  })  : emoji = '',
        avatarType = null,
        avatarValue = null;

  const AssistantAvatar.raw({
    super.key,
    required this.emoji,
    this.avatarType,
    this.avatarValue,
    this.radius = 20,
  }) : assistant = null;

  @override
  Widget build(BuildContext context) {
    final type = avatarType ?? assistant?.avatarType;
    final value = (avatarValue ?? assistant?.avatarValue)?.trim() ?? '';
    if (type == AvatarAssetService.imageType && value.isNotEmpty) {
      final file = File(value);
      if (file.existsSync()) {
        return CircleAvatar(
          radius: radius,
          backgroundImage: FileImage(file),
        );
      }
    }
    final fallback = emoji.isNotEmpty ? emoji : (assistant?.emoji ?? '🤖');
    return CircleAvatar(
      radius: radius,
      child: Text(
        fallback.trim().isEmpty ? '🤖' : fallback.trim(),
        style: TextStyle(fontSize: radius),
      ),
    );
  }
}

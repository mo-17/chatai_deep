import 'package:chat_message/models/message_model.dart';
import 'package:flutter/widgets.dart';

typedef MessageAvatarBuilder = Widget? Function(
  BuildContext context,
  MessageModel message,
  double avatarSize,
);

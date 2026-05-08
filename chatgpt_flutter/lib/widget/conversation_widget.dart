import 'package:chat_message/util/wechat_date_format.dart';
import 'package:chatgpt_flutter/model/conversation_model.dart';
import 'package:chatgpt_flutter/util/hi_dialog.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/padding_extension.dart';

///定义一个带有ConversationModel参数的回调

typedef ConversationCallBack = Function(ConversationModel model);
typedef ConversationStickCallBack = Function(ConversationModel model,
    {required bool isStick});

class ConversationWidget extends StatelessWidget {
  final ConversationModel model;
  final ConversationCallBack? onPressed;
  final ConversationCallBack? onDelete;
  final ConversationStickCallBack? onStick;

  const ConversationWidget(
      {Key? key,
      required this.model,
      this.onPressed,
      this.onDelete,
      this.onStick})
      : super(key: key);

  get _item => Container(
        padding: const EdgeInsets.only(left: 10, right: 10),
        color: _itemBackgroundColor,
        height: 76,
        child: Row(
          children: [_icon, 10.paddingWidth, _rightLayout],
        ),
      );

  get _itemBackgroundColor =>
      model.stickTime > 0 ? Colors.grey.withOpacity(0.2) : Colors.white;

  bool get _hasValidIcon => model.icon.isNotEmpty &&
      Uri.tryParse(model.icon)?.hasScheme == true;

  Widget get _aiFallback => ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Container(
          height: 50,
          width: 50,
          color: const Color(0xFF2E7D32),
          alignment: Alignment.center,
          child: const Text('AI',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ),
      );

  get _icon => _hasValidIcon
      ? ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Image.network(
            model.icon,
            height: 50,
            width: 50,
            headers: {
              if (LoginDao.getBoardingPass() != null)
                'Authorization': 'Bearer ${LoginDao.getBoardingPass()}',
            },
            errorBuilder: (_, __, ___) => _aiFallback,
            loadingBuilder: (_, child, progress) {
              if (progress == null) return child;
              return _aiFallback;
            },
          ),
        )
      : _aiFallback;

  get _rightLayout => Expanded(
          child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              5.paddingHeight,
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                      child: Text(
                    model.title ?? "",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18),
                  )),
                  Text(
                    WechatDateFormat.format(model.updateAt ?? 0),
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
                  )
                ],
              ),
              Text(
                '[${model.messageCount}条对话] ${model.lastMessage}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              )
            ],
          ),
          Divider(
            height: 1,
            color: Colors.grey.withOpacity(0.6),
          )
        ],
      ));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (onPressed != null) onPressed!(model);
      },
      onLongPress: () => _showPopMenu(context),
      child: _item,
    );
  }

  ///在item下方弹框，难点如何找到要弹框的坐标位置
  _showPopMenu(BuildContext context) {
    var isStick = model.stickTime > 0 ? true : false;
    var showStick = isStick ? "取消置顶" : "置顶";
    HiDialog.showPopMenu(context, offsetX: -50, items: [
      PopupMenuItem(
        child: Text(showStick),
        onTap: () {
          if (onStick != null) onStick!(model, isStick: !isStick);
        },
      ),
      PopupMenuItem(
        child: const Text('删除'),
        onTap: () {
          if (onDelete != null) onDelete!(model);
        },
      )
    ]);
  }
}

///会话上线文管理
class ConversationContextHelper implements IConversationContext {
  List<ConversationModel> conversationList = [];
  int length = 0;

  @override
  add(ConversationModel model) {
    conversationList.add(model);
    length += model.question.length;
    length += model.answer.length;
    length += 6; //Q:\nA:
  }

  @override
  String getPromptContext(String prompt) {
    //build query with conversation history
    // e.g.  Q: xxx
    //       A: xxx
    //       Q: xxx
    var sb = StringBuffer();
    for (var model in conversationList) {
      if (sb.length > 0) sb.write('\n');
      sb.write('Q:');
      sb.write(model.question);
      sb.write('\n');
      sb.write('A:');
      sb.write(model.answer);
    }
    sb.write('\n');
    sb.write('Q:');
    sb.write(prompt);
    return sb.toString();
  }
}

abstract class IConversationContext {
  add(ConversationModel model);

  ///获取带有上下文的会话信息
  String getPromptContext(String prompt);
}

class ConversationModel {
  final String question;
  final String answer;

  ConversationModel(this.question, this.answer);
}

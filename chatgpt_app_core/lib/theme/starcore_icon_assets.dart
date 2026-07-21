abstract final class StarcoreIconAssets {
  static const packageName = 'chatgpt_app_core';
  static const assistantExplorerId = 'starcore_explorer';
  static const assistantCreatorId = 'starcore_creator';
  static const messageAssetPrefix = 'asset:';

  static const navChatDefault = 'assets/icons/starcore/nav-chat-default.svg';
  static const navChatSelected = 'assets/icons/starcore/nav-chat-selected.svg';
  static const navCreateDefault =
      'assets/icons/starcore/nav-create-default.svg';
  static const navCreateSelected =
      'assets/icons/starcore/nav-create-selected.svg';
  static const toolWebSearch = 'assets/icons/starcore/tool-web-search.svg';
  static const toolKnowledgeSearch =
      'assets/icons/starcore/tool-knowledge-search.svg';
  static const assistantExplorer =
      'assets/icons/starcore/assistant-explorer.png';
  static const assistantCreator = 'assets/icons/starcore/assistant-creator.png';

  static String? assistantAssetFor(String? id) => switch (id?.trim()) {
        assistantExplorerId => assistantExplorer,
        assistantCreatorId => assistantCreator,
        _ => null,
      };

  static String messageAvatarFor(String id) => '$messageAssetPrefix$id';

  static String? parseMessageAvatar(String? value) {
    final normalized = value?.trim() ?? '';
    if (!normalized.startsWith(messageAssetPrefix)) return null;
    final id = normalized.substring(messageAssetPrefix.length);
    return assistantAssetFor(id) == null ? null : id;
  }
}

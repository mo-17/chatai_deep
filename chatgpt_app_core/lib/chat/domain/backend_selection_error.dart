/// 后端选择失败是配置问题，固定文案不包含服务端正文或私密连接字段。
const backendSelectionMessages = <String, String>{
  'model_ambiguous': '同名模型属于多个服务商，请明确选择服务商和模型',
  'model_unavailable': '所选模型已删除或停用，请重新选择',
  'provider_unavailable': '所选服务商不可用，请联系管理员或重新选择',
  'catalog_not_public': '服务器未开放模型目录，请联系管理员或明确配置服务商和模型',
  'invalid_backend_selection': '后端模型选择格式无效，请重新选择服务商和模型',
  'backend_scope_changed': '账号、后端来源或恢复状态已变化，请重新开始请求',
};
bool isBackendSelectionError(String code) =>
    backendSelectionMessages.containsKey(code);

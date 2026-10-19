import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/assistant_operation_scope.dart';
import 'package:chatgpt_app_core/widget/backend_selection_picker.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'dart:async';

import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_conversation_factory.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/pages/account_usage_page.dart';
import 'package:chatgpt_app_core/pages/agent_task_center_page.dart';
import 'package:chatgpt_app_core/pages/ai_health_check_page.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:chatgpt_app_core/widget/ai_readiness_card.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';

import '../db/hi_db_manager.dart';
import '../widget/conversation_widget.dart';

typedef ConversationSearchPageBuilder = Widget Function(
  BuildContext context,
  ConversationListDao? dao,
  int? projectId,
  bool uncategorized,
  String scopeLabel,
);

class ConversationListPage extends StatefulWidget {
  final ConversationSearchPageBuilder? searchPageBuilder;
  final bool skipInitialLoad;

  const ConversationListPage({
    super.key,
    this.searchPageBuilder,
    this.skipInitialLoad = false,
  });

  @override
  State<ConversationListPage> createState() => _ConversationListPageState();
}

class _ConversationListPageState extends State<ConversationListPage>
    with AutomaticKeepAliveClientMixin {
  List<ConversationModel> conversationList = [];
  List<ConversationModel> stickConversationList = [];
  List<ProjectModel> projectList = [];
  late ConversationListDao conversationListDao;
  late ProjectDao projectDao;
  final _imagePicker = ImagePicker();
  final _observedRuns = <ConversationGenerationRun>{};
  int _summaryRevision = -1;
  bool _listReady = false, _refreshQueued = false;
  int _listLoadGeneration = 0;
  int _projectLoadGeneration = 0;
  String? _listAccount;
  int? _selectedProjectId;
  bool _uncategorizedOnly = false;
  static const _projectColors = <int>[
    0xFF2E7D32,
    0xFF1565C0,
    0xFF6A1B9A,
    0xFFC62828,
    0xFFEF6C00,
    0xFF455A64,
  ];

  get _dataCount => conversationList.length + stickConversationList.length;

  Widget get _listView => RefreshIndicator(
        onRefresh: _refreshData,
        child: _dataCount == 0
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.45,
                    child: AppVisualEmptyState(
                      animeKey: const ValueKey('conversation_list_empty_state'),
                      icon: Icons.forum_outlined,
                      title: _emptyText,
                      message: '选一个助手或新建空白会话，开始你的下一段对话。',
                      classic: Center(
                        child: Text(
                          _emptyText,
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: _dataCount,
                itemBuilder: (BuildContext context, int index) =>
                    _conversationWidget(index),
              ),
      );

  String get _emptyText {
    if (_selectedProjectId != null || _uncategorizedOnly) {
      return '这个项目还没有会话';
    }
    return '还没有会话，点右上角新建';
  }

  @override
  void initState() {
    super.initState();
    ConversationGenerationService.instance.addListener(_generationChanged);
    if (widget.skipInitialLoad) return;
    _doInit();
    // 备份导入后重新加载（页面 keepAlive 常驻，不会再走 initState）。
    BackupService.restoreTick.addListener(_onRestore);
    // 转发写入/新建会话后刷新（同样因 keepAlive 不会自动重载）。
    AppEvents.conversationsChanged.addListener(_onRestore);
  }

  @override
  void dispose() {
    ConversationGenerationService.instance.removeListener(_generationChanged);
    for (final run in _observedRuns) {
      run.removeListener(_runStatusChanged);
    }
    _observedRuns.clear();
    BackupService.restoreTick.removeListener(_onRestore);
    AppEvents.conversationsChanged.removeListener(_onRestore);
    super.dispose();
  }

  void _runStatusChanged() {
    if (mounted) setState(() {});
  }

  void _generationChanged() {
    if (!mounted) return;
    final service = ConversationGenerationService.instance;
    final account = HiDBManager.getAccountHash();
    final current = service.runs
        .where((r) =>
            r.scope.account == account && r.scope.identityCurrent && r.busy)
        .toSet();
    for (final run in _observedRuns.difference(current)) {
      run.removeListener(_runStatusChanged);
    }
    for (final run in current.difference(_observedRuns)) {
      run.addListener(_runStatusChanged);
    }
    _observedRuns
      ..clear()
      ..addAll(current);
    if (_summaryRevision != service.summaryRevision) {
      _summaryRevision = service.summaryRevision;
      _queueSummaryRefresh();
    }
    setState(() {});
  }

  void _queueSummaryRefresh() {
    if (!_listReady || _refreshQueued) return;
    _refreshQueued = true;
    final revision = _summaryRevision;
    scheduleMicrotask(() async {
      try {
        if (mounted && _listAccount == HiDBManager.getAccountHash()) {
          await _reloadData();
        }
      } catch (_) {
        // 保留上次已读列表，下一次提交事件或手动刷新可重试。
      } finally {
        _refreshQueued = false;
        if (mounted && _summaryRevision != revision) {
          _queueSummaryRefresh();
        }
      }
    });
  }

  void _onRestore() {
    unawaited(_reloadData());
  }

  @override
  void setState(VoidCallback fn) {
    if (!mounted) {
      //fix 热重启/热加载 build被连续执行两次，_doInit执行setState时页面已经销毁的问题
      return;
    }
    super.setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final readiness = context.watch<AIReadinessProvider?>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('艾普'),
        centerTitle: true,
        actions: [
          IconButton(
            key: const ValueKey('conversation_list_agent_task_center'),
            tooltip: 'Agent 任务中心',
            icon: const Icon(Icons.assignment_outlined),
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const AgentTaskCenterPage()),
            ),
          ),
          IconButton(
            key: const ValueKey('conversation_list_global_search'),
            onPressed: _openSearch,
            tooltip: '搜索会话',
            icon: const Icon(Icons.search),
          ),
          IconButton(
            onPressed: _createProject,
            tooltip: '新建项目',
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            onPressed: _createConversation,
            tooltip: '新建会话',
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          _projectBar,
          if (readiness?.showProactiveCard == true)
            Flexible(
                child: SingleChildScrollView(
                    child: AIReadinessCard(
              state: readiness!.state,
              onRetry: () => unawaited(_refreshReadiness()),
              onConfigure: () => unawaited(_openAISettings()),
              onVerify: () => unawaited(_openAIHealthCheck()),
              onLogin: () => unawaited(LoginDao.logOut()),
              onDismiss: () => unawaited(_dismissReadinessCard()),
              onTrial: () => Navigator.push<void>(context,
                  MaterialPageRoute(builder: (_) => const AccountUsagePage())),
            ))),
          Expanded(child: _listView),
        ],
      ),
    );
  }

  Future<void> _openAISettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const AISettingsPage()),
    );
    if (!mounted) return;
    await _markReadinessCompletedIfReady();
  }

  Future<void> _openAIHealthCheck() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const AiHealthCheckPage()),
    );
    if (!mounted) return;
    await _markReadinessCompletedIfReady();
  }

  Future<void> _refreshReadiness() async {
    final readiness = context.read<AIReadinessProvider?>();
    if (readiness == null) return;
    try {
      await readiness.refresh();
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, 'AI 状态检查失败：$error');
    }
  }

  Future<void> _dismissReadinessCard() async {
    final readiness = context.read<AIReadinessProvider?>();
    if (readiness == null) return;
    try {
      await readiness.dismiss();
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '稍后提醒设置未保存：$error');
    }
  }

  Future<void> _markReadinessCompletedIfReady() async {
    final readiness = context.read<AIReadinessProvider?>();
    if (readiness == null || readiness.state.status != AIReadyStatus.ready) {
      return;
    }
    try {
      await readiness.markCompleted();
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, 'AI 引导状态未保存：$error');
    }
  }

  Widget get _projectBar {
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 52,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: visual.isAnime
          ? BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.78),
              border: Border(
                bottom: BorderSide(color: scheme.outlineVariant),
              ),
            )
          : null,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _filterChip(
            label: '全部',
            selected: _selectedProjectId == null && !_uncategorizedOnly,
            onSelected: () => _selectProject(null, uncategorized: false),
          ),
          _filterChip(
            label: '未分类',
            selected: _uncategorizedOnly,
            onSelected: () => _selectProject(null, uncategorized: true),
          ),
          for (final project in projectList)
            _filterChip(
              label:
                  '${project.icon.isEmpty ? '📁' : project.icon} ${project.name} ${project.conversationCount}',
              selected: _selectedProjectId == project.id && !_uncategorizedOnly,
              color: Color(project.color),
              onSelected: () => _selectProject(project.id),
              onLongPress: () => _showProjectActions(project),
            ),
        ],
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
    Color? color,
    VoidCallback? onLongPress,
  }) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onLongPress: onLongPress,
          child: ChoiceChip(
            label: Text(label),
            selected: selected,
            avatar: color == null
                ? null
                : CircleAvatar(backgroundColor: color, radius: 5),
            onSelected: (_) => onSelected(),
          ),
        ),
      );

  ///创建新的会话。先选助手（阶段七）：没有任何助手时选择器零打扰直接放行。
  void _createConversation() async {
    final originalProject = _currentProject;
    final backend =
        context.read<AISettingsProvider>().settings.mode == AIMode.backend;
    final project = backend && originalProject != null
        ? ProjectModel.fromJson(originalProject.toJson())
        : originalProject;
    final projectId = _uncategorizedOnly ? null : _selectedProjectId;
    final identity = backend ? AiCatalogIdentity.capture() : null;
    final scope = backend
        ? AssistantOperationScope.capture(pageIsCurrent: () => mounted)
        : null;
    bool seedCurrent() =>
        !backend ||
        (identity!.current &&
            scope!.isCurrent &&
            _listAccount == identity.account &&
            projectId == (_uncategorizedOnly ? null : _selectedProjectId) &&
            (project == null ||
                jsonEncode(project.toJson()) ==
                    jsonEncode(_currentProject?.toJson())));
    if (!seedCurrent()) return;
    void checkSeed() {
      if (!mounted || !seedCurrent()) {
        throw const BackendSelectionEditorExpired();
      }
    }

    ProjectBackendSelectionSnapshot? expectedSeed;
    if (backend && project != null) {
      try {
        expectedSeed = await projectDao.backendSelectionSnapshot(project,
            validate: checkSeed);
      } catch (_) {
        if (mounted && seedCurrent()) {
          HiDialog.showSnackBar(context, '原项目已变化，请重新新建会话');
        }
        return;
      }
      if (!mounted || !seedCurrent()) return;
    }
    final pick = await showAssistantPicker(context,
        selectedId: project?.defaultAssistantId);
    if (pick == null || !mounted || !seedCurrent()) return; // 用户取消/原seed失效
    final cid = DateTime.now().millisecondsSinceEpoch;
    final avatar = AiCatalogDao.avatarUrl();
    final assistant = pick.assistant;
    final opening = await _chooseAssistantOpening(assistant);
    if (opening == null || !mounted || !seedCurrent()) return;
    if (expectedSeed != null) {
      try {
        await projectDao.verifyBackendSeedChecked(project!, expectedSeed,
            validate: checkSeed);
      } catch (_) {
        if (mounted && seedCurrent()) {
          HiDialog.showSnackBar(context, '原项目已变化，请重新新建会话');
        }
        return;
      }
      if (!mounted || !seedCurrent()) return;
    }
    _jumpToConversation(
        AssistantConversationFactory.create(
            cid: cid,
            icon: avatar,
            assistant: assistant,
            projectId: backend
                ? projectId
                : (_uncategorizedOnly ? null : _selectedProjectId),
            modelProviderId: project?.defaultProviderId,
            modelId: project?.defaultModelId,
            backendSelection: project?.backendSelection,
            webSearchEnabled: project?.defaultUseWebSearch,
            toolIds: project?.defaultToolIds),
        initialAssistantOpening: opening);
  }

  Future<String?> _chooseAssistantOpening(AssistantModel? assistant) async {
    final candidates =
        AssistantConversationFactory.openingMessageCandidates(assistant);
    if (candidates.length <= 1) {
      return candidates.isEmpty ? '' : candidates.first;
    }
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择开场白'),
        children: [
          for (var i = 0; i < candidates.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, candidates[i]),
              child: Text(
                candidates[i],
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('不使用开场白'),
          ),
        ],
      ),
    );
  }

  ProjectModel? get _currentProject {
    if (_uncategorizedOnly || _selectedProjectId == null) return null;
    final matches = projectList.where((p) => p.id == _selectedProjectId);
    return matches.isEmpty ? null : matches.first;
  }

  _conversationWidget(int pos) {
    ConversationModel model;
    if (pos < stickConversationList.length) {
      model = stickConversationList[pos];
    } else {
      model = conversationList[pos - stickConversationList.length];
    }
    final tile = ConversationWidget(
      model: model,
      onPressed: _jumpToConversation,
      onDelete: _onDelete,
      onMoveProject: _moveToProject,
      onAvatar: _editConversationAvatar,
      onStick: _onStick,
    );
    final run = ConversationGenerationService.instance
        .lookup(HiDBManager.getAccountHash(), model.cid);
    if (run == null || !run.busy) return tile;
    return Column(children: [
      tile,
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
                child: Text(
                    run.persistencePending
                        ? '回复待保存'
                        : run.confirmation != null
                            ? '等待确认'
                            : run.progress,
                    key: ValueKey('ordinary_list_status_${model.cid}'))),
            TextButton(
                onPressed: () => run.persistencePending
                    ? run.retryPersistence()
                    : run.stop('已从会话列表停止'),
                child: Text(run.persistencePending ? '重试保存' : '停止'))
          ]))
    ]);
  }

  void _doInit() async {
    _listAccount = HiDBManager.getAccountHash();
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    conversationListDao = await ConversationListDao.create(storage);
    projectDao = await ProjectDao.create(storage);
    if (!mounted || _listAccount != HiDBManager.getAccountHash()) return;
    _listReady = true;
    _generationChanged();
    _loadProjects();
    _loadStickData();
    _loadData();
  }

  int pageIndex = 1;

  Future<List<ConversationModel>> _loadStickData() async {
    final list = await conversationListDao.getStickConversationList(
        projectId: _selectedProjectId, uncategorized: _uncategorizedOnly);
    setState(() {
      stickConversationList = list;
    });
    return list;
  }

  Future<List<ConversationModel>> _loadData({loadMore = false}) async {
    if (loadMore) {
      pageIndex++;
    } else {
      pageIndex = 1;
    }
    final generation = ++_listLoadGeneration;
    final account = _listAccount;
    final list = await conversationListDao.getConversationList(
        pageIndex: pageIndex,
        projectId: _selectedProjectId,
        uncategorized: _uncategorizedOnly);
    if (!mounted ||
        generation != _listLoadGeneration ||
        account != HiDBManager.getAccountHash()) {
      return list;
    }
    AILogger.log('conversation list count:${list.length}');
    if (loadMore) {
      setState(() {
        conversationList.addAll(list);
      });
    } else {
      setState(() {
        conversationList = list;
      });
    }
    return list;
  }

  Future<List<ProjectModel>> _loadProjects() async {
    final generation = ++_projectLoadGeneration;
    final account = _listAccount;
    final identity = AiCatalogIdentity.capture();
    final list = await projectDao.getProjects(withCounts: true);
    if (!mounted ||
        generation != _projectLoadGeneration ||
        account != HiDBManager.getAccountHash() ||
        !identity.current) {
      return list;
    }
    setState(() {
      projectList = list;
    });
    return list;
  }

  Future<void> _refreshData() async {
    final startedAt = DateTime.now();
    await _reloadData();
    const minIndicatorDuration = Duration(milliseconds: 700);
    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed < minIndicatorDuration) {
      await Future.delayed(minIndicatorDuration - elapsed);
    }
  }

  Future<void> _reloadData() async {
    await Future.wait([
      _loadProjects(),
      _loadStickData(),
      _loadData(),
    ]);
  }

  Future<void> _openSearch() async {
    final result = await Navigator.push<ConversationSearchSelection>(
      context,
      MaterialPageRoute(
        builder: (ctx) =>
            widget.searchPageBuilder?.call(
              ctx,
              widget.skipInitialLoad ? null : conversationListDao,
              _selectedProjectId,
              _uncategorizedOnly,
              _searchScopeLabel,
            ) ??
            ConversationSearchPage(
              dao: conversationListDao,
              projectId: _selectedProjectId,
              uncategorized: _uncategorizedOnly,
              scopeLabel: _searchScopeLabel,
            ),
      ),
    );
    if (!mounted || result == null) return;
    _jumpToConversation(
      result.conversation,
      initialTargetCreatedAt: result.targetMessageCreatedAt,
    );
  }

  String get _searchScopeLabel {
    if (_uncategorizedOnly) return '未分类';
    final project = _currentProject;
    if (project != null) return project.name;
    return '全部会话';
  }

  void _selectProject(int? projectId, {bool uncategorized = false}) {
    setState(() {
      _selectedProjectId = projectId;
      _uncategorizedOnly = uncategorized;
    });
    _loadStickData();
    _loadData();
  }

  void _jumpToConversation(ConversationModel model,
      {int? initialTargetCreatedAt, String initialAssistantOpening = ''}) {
    NavigatorUtil.push(
        context,
        ConversationPage(
            conversationModel: model,
            initialAssistantOpening: initialAssistantOpening,
            initialTargetCreatedAt: initialTargetCreatedAt,
            conversationUpdate: (_) => _reloadData())).then((_) {
      // 从对话详情页返回后立即更新，DB 操作已通过 async factory 保证表就绪
      if (mounted) unawaited(_reloadData());
    });
  }

  @override
  bool get wantKeepAlive => true;

  _onDelete(ConversationModel model) async {
    final account = HiDBManager.getAccountHash();
    await AgentTaskExecutor.instance.forget(AgentTaskKey(account, model.cid));
    if (!mounted || account != HiDBManager.getAccountHash()) return;
    await AvatarAssetService.deleteConversationAvatar(model.avatarValue);
    await conversationListDao.deleteConversation(model);
    if (!mounted) return;
    conversationList.remove(model);
    //fix 置顶消息无法删除问题
    stickConversationList.remove(model);
    setState(() {});
    _loadProjects();
  }

  _onStick(ConversationModel model, {required bool isStick}) async {
    final result =
        await conversationListDao.updateStickTime(model, isStick: isStick);
    //操作失败
    if (result <= 0) {
      return;
    }
    if (isStick) {
      //从之前的列表中移除
      conversationList.remove(model);
      if (!stickConversationList.contains(model)) {
        //加入到新的列表
        stickConversationList.insert(0, model);
      }
    } else {
      stickConversationList.remove(model);
      if (!conversationList.contains(model)) {
        conversationList.insert(0, model); //也可根据需要，根据条件model插入到其他位置
      }
    }
    //刷新
    setState(() {});
  }

  Future<void> _moveToProject(ConversationModel model) async {
    const uncategorizedValue = -1;
    final target = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('未分类'),
              trailing:
                  model.projectId == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, uncategorizedValue),
            ),
            for (final project in projectList)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(project.color),
                  radius: 10,
                  child:
                      Text(project.icon, style: const TextStyle(fontSize: 10)),
                ),
                title: Text(project.name),
                trailing: model.projectId == project.id
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(ctx, project.id),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (target == null) return;
    await conversationListDao.updateProjectId(
        model, target == uncategorizedValue ? null : target);
    _loadProjects();
    _loadStickData();
    _loadData();
  }

  Future<void> _createProject() async {
    final draft = await _askProjectDraft(title: '新建项目');
    if (draft == null) return;
    final project = ProjectModel(
        name: draft.name,
        icon: draft.icon,
        color: draft.color,
        sortOrder: projectList.length);
    await projectDao.saveProject(project);
    await _loadProjects();
    _selectProject(project.id);
  }

  Future<void> _renameProject(ProjectModel project) async {
    final draft = await _askProjectDraft(title: '编辑项目', project: project);
    if (draft == null) return;
    project
      ..name = draft.name
      ..icon = draft.icon
      ..color = draft.color;
    await projectDao.saveProject(project);
    _loadProjects();
  }

  Future<({String name, String icon, int color})?> _askProjectDraft({
    required String title,
    ProjectModel? project,
  }) {
    final nameController = TextEditingController(text: project?.name ?? '');
    final iconController = TextEditingController(
        text: project?.icon.isNotEmpty == true ? project!.icon : '📁');
    var selectedColor = project?.color ?? _projectColors.first;
    return showDialog<({String name, String icon, int color})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isAnime = AppVisualTheme.of(ctx).isAnime;
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '项目名称'),
                  maxLength: 24,
                ),
                TextField(
                  controller: iconController,
                  decoration: const InputDecoration(
                    labelText: '图标',
                    hintText: '📁',
                  ),
                  maxLength: 2,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 10,
                    runSpacing: isAnime ? 8 : 0,
                    children: [
                      for (var index = 0;
                          index < _projectColors.length;
                          index++)
                        Semantics(
                          button: true,
                          selected: selectedColor == _projectColors[index],
                          label: '项目颜色 ${index + 1}',
                          child: SizedBox.square(
                            dimension: isAnime ? 44 : 30,
                            child: InkWell(
                              borderRadius:
                                  BorderRadius.circular(isAnime ? 22 : 16),
                              onTap: () => setDialogState(
                                () => selectedColor = _projectColors[index],
                              ),
                              child: Center(
                                child: CircleAvatar(
                                  radius: 15,
                                  backgroundColor: Color(_projectColors[index]),
                                  child: selectedColor == _projectColors[index]
                                      ? const Icon(Icons.check,
                                          color: Colors.white, size: 18)
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                  onPressed: () {
                    final name = nameController.text.trim();
                    final icon = iconController.text.trim();
                    if (name.isEmpty) {
                      Navigator.pop(ctx);
                      return;
                    }
                    Navigator.pop(ctx, (
                      name: name,
                      icon: icon.isEmpty ? '📁' : icon,
                      color: selectedColor
                    ));
                  },
                  child: const Text('保存')),
            ],
          );
        },
      ),
    );
  }

  void _showProjectActions(ProjectModel project) {
    HiDialog.showPopMenu(context, offsetX: -50, items: [
      PopupMenuItem(
        child: const Text('重命名'),
        onTap: () => _renameProject(project),
      ),
      PopupMenuItem(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('默认模型'),
          if (context.read<AISettingsProvider>().settings.mode ==
              AIMode.backend)
            Text(
                backendSelectionLabel(project.backendSelection,
                    legacyModelId: project.defaultModelId,
                    followLabel: '新会话跟随助手 / 全局'),
                style: Theme.of(context).textTheme.bodySmall),
        ]),
        onTap: () => _setProjectDefaultModel(project),
      ),
      PopupMenuItem(
        child: const Text('默认助手'),
        onTap: () => _setProjectDefaultAssistant(project),
      ),
      PopupMenuItem(
        child: const Text('默认联网搜索'),
        onTap: () => _setProjectDefaultWebSearch(project),
      ),
      PopupMenuItem(
        child: const Text('默认工具集'),
        onTap: () => _setProjectDefaultTools(project),
      ),
      PopupMenuItem(
        child: const Text('项目知识库'),
        onTap: () => _setProjectKnowledge(project),
      ),
      PopupMenuItem(
        child: const Text('删除项目'),
        onTap: () => _deleteProject(project),
      ),
    ]);
  }

  Future<void> _setProjectDefaultAssistant(ProjectModel project) async {
    final pick = await showAssistantPicker(context,
        selectedId: project.defaultAssistantId);
    if (!mounted || pick == null) return;
    project.defaultAssistantId = pick.assistant?.id;
    await projectDao.saveProject(project);
    await _loadProjects();
    if (mounted) {
      HiDialog.showSnackBar(
          context,
          pick.assistant == null
              ? '项目默认助手：不使用助手'
              : '项目默认助手：${pick.assistant!.name}');
    }
  }

  Future<void> _setProjectDefaultModel(ProjectModel project) async {
    final settings = context.read<AISettingsProvider>().settings;
    if (settings.mode == AIMode.backend) {
      await _setProjectBackendSelection(project);
      return;
    }
    final picked = await _pickProjectLocalModel(project, settings);
    if (!mounted || picked == null) return;
    project
      ..defaultProviderId = picked.providerId
      ..defaultModelId = picked.modelId;
    await projectDao.saveProject(project);
    await _loadProjects();
    if (!mounted) return;
    HiDialog.showSnackBar(context,
        picked.modelId == null ? '项目默认模型：跟随全局' : '项目默认模型：${picked.modelId}');
  }

  Future<void> _setProjectDefaultWebSearch(ProjectModel project) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('项目默认联网搜索'),
        children: [
          ListTile(
            title: const Text('跟随全局设置'),
            trailing: project.defaultUseWebSearch == null
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(ctx, -1),
          ),
          ListTile(
            title: const Text('默认开启'),
            trailing: project.defaultUseWebSearch == true
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(ctx, 1),
          ),
          ListTile(
            title: const Text('默认关闭'),
            trailing: project.defaultUseWebSearch == false
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(ctx, 0),
          ),
        ],
      ),
    );
    if (!mounted || picked == null) return;
    project.defaultUseWebSearch = picked < 0 ? null : picked == 1;
    await projectDao.saveProject(project);
    await _loadProjects();
    if (!mounted) return;
    final label = picked < 0 ? '跟随全局' : (picked == 1 ? '默认开启' : '默认关闭');
    HiDialog.showSnackBar(context, '项目默认联网搜索：$label');
  }

  Future<void> _setProjectDefaultTools(ProjectModel project) async {
    final selected = <String>{...?project.defaultToolIds};
    final result =
        await showModalBottomSheet<({bool follow, List<String> tools})>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.auto_fix_normal_outlined),
                title: const Text('跟随助手工具集'),
                trailing: project.defaultToolIds == null
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(ctx, (follow: true, tools: <String>[])),
              ),
              const Divider(height: 1),
              for (final tool in ToolRegistry.catalog)
                CheckboxListTile(
                  value: selected.contains(tool.id),
                  title: Text(tool.label),
                  subtitle: Text(tool.description),
                  onChanged: (checked) {
                    setSheetState(() {
                      if (checked == true) {
                        selected.add(tool.id);
                      } else {
                        selected.remove(tool.id);
                      }
                    });
                  },
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                      ctx, (follow: false, tools: selected.toList())),
                  child: const Text('保存工具集'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (result == null) return;
    project.defaultToolIds = result.follow ? null : result.tools;
    await projectDao.saveProject(project);
    await _loadProjects();
    if (!mounted) return;
    HiDialog.showSnackBar(
        context, result.follow ? '项目默认工具集：跟随助手' : '项目默认工具集已保存');
  }

  Future<void> _setProjectKnowledge(ProjectModel project) async {
    final dao = await KnowledgeDao.create(conversationListDao.storage);
    final docs = await dao.getDocuments();
    if (!mounted) return;
    if (docs.isEmpty) {
      HiDialog.showSnackBar(context, '知识库还没有文档');
      return;
    }
    final selected = (await dao.getProjectDocIds(project.id!)).toSet();
    if (!mounted) return;
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                leading: Icon(Icons.library_books_outlined),
                title: Text('项目知识库'),
                subtitle: Text('勾选后，项目内会话会优先检索这些文档'),
              ),
              const Divider(height: 1),
              for (final doc in docs)
                CheckboxListTile(
                  value: selected.contains(doc.id),
                  title: Text(doc.title),
                  subtitle: Text('${doc.chunkCount} 个片段'),
                  onChanged: (checked) {
                    final id = doc.id;
                    if (id == null) return;
                    setSheetState(() {
                      if (checked == true) {
                        selected.add(id);
                      } else {
                        selected.remove(id);
                      }
                    });
                  },
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, <int>[]),
                      child: const Text('清空绑定'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () =>
                          Navigator.pop(ctx, selected.toList(growable: false)),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || result == null) return;
    await dao.setProjectDocIds(project.id!, result);
    if (!mounted) return;
    final count = result.length;
    HiDialog.showSnackBar(context, count == 0 ? '项目知识库已清空' : '已绑定 $count 个文档');
  }

  Future<({String? providerId, String? modelId})?> _pickProjectLocalModel(
      ProjectModel project, AISettings settings) {
    return showModalBottomSheet<({String? providerId, String? modelId})>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('跟随全局设置'),
              trailing: project.defaultModelId == null
                  ? const Icon(Icons.check)
                  : null,
              onTap: () =>
                  Navigator.pop(ctx, (providerId: null, modelId: null)),
            ),
            const Divider(height: 1),
            for (final provider in settings.enabledProviders) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(provider.name,
                    style: Theme.of(ctx).textTheme.labelLarge),
              ),
              for (final model in provider.models)
                ListTile(
                  dense: true,
                  title: Text(model.name),
                  subtitle: model.id == model.name ? null : Text(model.id),
                  trailing: project.defaultProviderId == provider.id &&
                          project.defaultModelId == model.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(
                      ctx, (providerId: provider.id, modelId: model.id)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _setProjectBackendSelection(ProjectModel project) async {
    final identity = AiCatalogIdentity.capture();
    final scope = AssistantOperationScope.capture(pageIsCurrent: () => mounted);
    void checkContext() {
      scope.verify();
      if (!_listReady ||
          !identity.current ||
          !identity.authenticated ||
          identity.account != _listAccount ||
          context.read<AISettingsProvider>().settings.mode != AIMode.backend) {
        throw const BackendSelectionEditorExpired();
      }
    }

    void check() {
      checkContext();
      if (!projectList.any((p) =>
          p.id == project.id &&
          jsonEncode(p.toJson()) == jsonEncode(project.toJson()))) {
        throw const ProjectBackendSelectionStale();
      }
    }

    try {
      check();
      final snapshot =
          await projectDao.backendSelectionSnapshot(project, validate: check);
      if (!mounted) return;
      check();
      final picked = await pickBackendSelection(context,
          identity: identity,
          selected: project.backendSelection,
          legacyModelId: project.defaultModelId,
          followLabel: '新会话跟随助手 / 全局');
      if (picked == null) return;
      check();
      final saved = await scope.runStable(() =>
          projectDao.saveBackendSelectionChecked(project, picked, snapshot,
              validate: check));
      checkContext();
      project.backendSelection = saved.backendSelection;
      project.updatedAt = saved.updatedAt;
      await _loadProjects();
      if (!mounted || !scope.isCurrent || !identity.current) return;
      HiDialog.showSnackBar(context, '已保存项目新会话后端选择；已有会话保持原选择');
    } catch (_) {
      if (mounted && _listAccount == identity.account && identity.current) {
        HiDialog.showSnackBar(context, '原项目或编辑环境已变化，请重新打开项目选择');
      }
    }
  }

  Future<void> _deleteProject(ProjectModel project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除项目'),
        content: Text('删除「${project.name}」后，项目内会话会移动到未分类。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await projectDao.deleteProject(project.id!);
    if (_selectedProjectId == project.id) {
      _selectedProjectId = null;
      _uncategorizedOnly = false;
    }
    _loadProjects();
    _loadStickData();
    _loadData();
  }

  Future<void> _editConversationAvatar(ConversationModel model) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: const Text('设置表情头像'),
              onTap: () => Navigator.pop(ctx, 'emoji'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('恢复默认头像'),
              onTap: () => Navigator.pop(ctx, 'reset'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'emoji') {
      await _setConversationEmoji(model);
    } else if (action == 'image') {
      await _setConversationImage(model);
    } else if (action == 'reset') {
      await AvatarAssetService.deleteConversationAvatar(model.avatarValue);
      await conversationListDao.updateAvatar(model, null, null);
      setState(() {});
    }
  }

  Future<void> _setConversationEmoji(ConversationModel model) async {
    final controller = TextEditingController(
        text: model.avatarType == 'emoji' ? model.avatarValue ?? '' : '');
    final emoji = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置表情头像'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：💡'),
          maxLength: 2,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                Navigator.pop(ctx, value.isEmpty ? null : value);
              },
              child: const Text('保存')),
        ],
      ),
    );
    if (!mounted || emoji == null) return;
    await AvatarAssetService.deleteConversationAvatar(model.avatarValue);
    await conversationListDao.updateAvatar(model, 'emoji', emoji);
    setState(() {});
  }

  Future<void> _setConversationImage(ConversationModel model) async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 70,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (!mounted || picked == null) return;
      final oldPath = model.avatarValue;
      final avatarPath = await AvatarAssetService.saveConversationAvatar(
          sourcePath: picked.path, cid: model.cid);
      await conversationListDao.updateAvatar(
          model, AvatarAssetService.imageType, avatarPath);
      if (oldPath != avatarPath) {
        await AvatarAssetService.deleteConversationAvatar(oldPath);
      }
      setState(() {});
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取头像失败：$e');
    }
  }
}

class ConversationSearchPage extends StatefulWidget {
  final ConversationListDao? dao;
  final int? projectId;
  final bool uncategorized;
  final String scopeLabel;
  final Future<List<ConversationSearchResult>> Function(
    String query, {
    int? projectId,
    bool uncategorized,
    int? assistantId,
    String? modelId,
    int? updatedAfter,
    int? updatedBefore,
  })? searchConversations;
  final Future<List<FavoriteSearchResult>> Function(String query)?
      searchFavorites;

  const ConversationSearchPage({
    super.key,
    required this.dao,
    required this.projectId,
    required this.uncategorized,
    required this.scopeLabel,
    this.searchConversations,
    this.searchFavorites,
  });

  @override
  State<ConversationSearchPage> createState() => _ConversationSearchPageState();
}

class ConversationSearchSelection {
  final ConversationModel conversation;
  final int? targetMessageCreatedAt;

  const ConversationSearchSelection({
    required this.conversation,
    this.targetMessageCreatedAt,
  });
}

class _ConversationSearchPageState extends State<ConversationSearchPage> {
  final _controller = TextEditingController();
  List<ConversationSearchResult> _results = const [];
  List<FavoriteSearchResult> _favoriteResults = const [];
  bool _loading = false;
  String? _errorText;
  int? _assistantId;
  String? _modelId;
  int? _updatedAfter;
  int? _updatedBefore;
  int _searchSeq = 0;
  bool _searchAllConversations = false;
  final Set<String> _expandedConversationHits = {};

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String value) async {
    final seq = ++_searchSeq;
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _favoriteResults = const [];
        _loading = false;
        _errorText = null;
        _expandedConversationHits.clear();
      });
      return;
    }
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final conversations = widget.searchConversations == null
          ? await widget.dao!.searchConversations(
              query,
              projectId: _effectiveProjectId,
              uncategorized: _effectiveUncategorized,
              assistantId: _assistantId,
              modelId: _modelId,
              updatedAfter: _updatedAfter,
              updatedBefore: _updatedBefore,
            )
          : await widget.searchConversations!(
              query,
              projectId: _effectiveProjectId,
              uncategorized: _effectiveUncategorized,
              assistantId: _assistantId,
              modelId: _modelId,
              updatedAfter: _updatedAfter,
              updatedBefore: _updatedBefore,
            );
      final favorites = await (widget.searchFavorites ??
              (String q) async {
                final favoriteDao =
                    await FavoriteDao.create(widget.dao!.storage);
                return favoriteDao.searchFavoriteResults(
                  q,
                  projectId: _effectiveProjectId,
                  uncategorized: _effectiveUncategorized,
                );
              })
          .call(query);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = conversations;
        _favoriteResults = favorites;
        _loading = false;
        _expandedConversationHits.clear();
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = const [];
        _favoriteResults = const [];
        _loading = false;
        _errorText = '搜索失败：$e';
        _expandedConversationHits.clear();
      });
    }
  }

  String _hitKey(ConversationSearchResult item) =>
      '${item.conversation.cid}:${item.targetMessageCreatedAt ?? item.sourceLabel}:${item.snippet}';

  bool get _hasFilters =>
      _assistantId != null ||
      _modelId?.trim().isNotEmpty == true ||
      _updatedAfter != null ||
      _updatedBefore != null;

  bool get _hasScopedSearch => widget.projectId != null || widget.uncategorized;

  int? get _effectiveProjectId =>
      _searchAllConversations ? null : widget.projectId;

  bool get _effectiveUncategorized =>
      _searchAllConversations ? false : widget.uncategorized;

  String get _effectiveScopeLabel =>
      _searchAllConversations ? '全部会话' : widget.scopeLabel;

  List<({String title, List<ConversationSearchResult> items})>
      get _conversationResultGroups {
    final titleHits = <ConversationSearchResult>[];
    final recentHits = <ConversationSearchResult>[];
    final historyHits = <ConversationSearchResult>[];
    final otherHits = <ConversationSearchResult>[];
    for (final item in _results) {
      switch (item.sourceLabel) {
        case '标题':
          titleHits.add(item);
        case '最近消息':
          recentHits.add(item);
        case '历史消息':
          historyHits.add(item);
        default:
          otherHits.add(item);
      }
    }
    return [
      if (titleHits.isNotEmpty) (title: '标题命中', items: titleHits),
      if (recentHits.isNotEmpty) (title: '最近消息命中', items: recentHits),
      if (historyHits.isNotEmpty) (title: '历史消息命中', items: historyHits),
      if (otherHits.isNotEmpty) (title: '其它匹配', items: otherHits),
    ];
  }

  Future<void> _rerunSearchIfNeeded() async {
    if (_controller.text.trim().isNotEmpty) {
      await _search(_controller.text);
    }
  }

  void _setSearchAllConversations(bool value) {
    if (_searchAllConversations == value) return;
    setState(() => _searchAllConversations = value);
    _rerunSearchIfNeeded();
  }

  Future<void> _editFilters() async {
    final modelController = TextEditingController(text: _modelId ?? '');
    var assistantId = _assistantId;
    var updatedAfter = _updatedAfter;
    var updatedBefore = _updatedBefore;
    final now = DateTime.now();
    final picked = await showModalBottomSheet<
        ({
          int? assistantId,
          String? modelId,
          int? updatedAfter,
          int? updatedBefore
        })>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text('筛选', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: modelController,
                decoration: const InputDecoration(
                  labelText: '模型 ID',
                  hintText: '例如 gpt-4o',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('全部时间'),
                    selected: updatedAfter == null && updatedBefore == null,
                    onSelected: (_) => setSheetState(() {
                      updatedAfter = null;
                      updatedBefore = null;
                    }),
                  ),
                  FilterChip(
                    label: const Text('最近 7 天'),
                    selected: updatedAfter ==
                            now
                                .subtract(const Duration(days: 7))
                                .millisecondsSinceEpoch &&
                        updatedBefore == null,
                    onSelected: (_) => setSheetState(() {
                      updatedAfter = now
                          .subtract(const Duration(days: 7))
                          .millisecondsSinceEpoch;
                      updatedBefore = null;
                    }),
                  ),
                  FilterChip(
                    label: const Text('最近 30 天'),
                    selected: updatedAfter ==
                            now
                                .subtract(const Duration(days: 30))
                                .millisecondsSinceEpoch &&
                        updatedBefore == null,
                    onSelected: (_) => setSheetState(() {
                      updatedAfter = now
                          .subtract(const Duration(days: 30))
                          .millisecondsSinceEpoch;
                      updatedBefore = null;
                    }),
                  ),
                  FilterChip(
                    label: const Text('7 天前'),
                    selected: updatedAfter == null &&
                        updatedBefore ==
                            now
                                .subtract(const Duration(days: 7))
                                .millisecondsSinceEpoch,
                    onSelected: (_) => setSheetState(() {
                      updatedAfter = null;
                      updatedBefore = now
                          .subtract(const Duration(days: 7))
                          .millisecondsSinceEpoch;
                    }),
                  ),
                  FilterChip(
                    label: const Text('30 天前'),
                    selected: updatedAfter == null &&
                        updatedBefore ==
                            now
                                .subtract(const Duration(days: 30))
                                .millisecondsSinceEpoch,
                    onSelected: (_) => setSheetState(() {
                      updatedAfter = null;
                      updatedBefore = now
                          .subtract(const Duration(days: 30))
                          .millisecondsSinceEpoch;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.smart_toy_outlined),
                title:
                    Text(assistantId == null ? '不限助手' : '助手 ID：$assistantId'),
                trailing: TextButton(
                  onPressed: () async {
                    final pick = await showAssistantPicker(context,
                        selectedId: assistantId);
                    if (pick == null || !ctx.mounted) return;
                    setSheetState(() => assistantId = pick.assistant?.id);
                  },
                  child: const Text('选择'),
                ),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, (
                      assistantId: null,
                      modelId: null,
                      updatedAfter: null,
                      updatedBefore: null,
                    )),
                    child: const Text('清空'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      final model = modelController.text.trim();
                      Navigator.pop(ctx, (
                        assistantId: assistantId,
                        modelId: model.isEmpty ? null : model,
                        updatedAfter: updatedAfter,
                        updatedBefore: updatedBefore,
                      ));
                    },
                    child: const Text('应用'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    modelController.dispose();
    if (!mounted || picked == null) return;
    setState(() {
      _assistantId = picked.assistantId;
      _modelId = picked.modelId;
      _updatedAfter = picked.updatedAfter;
      _updatedBefore = picked.updatedBefore;
    });
    if (_controller.text.trim().isNotEmpty) {
      await _search(_controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAnime = AppVisualTheme.of(context).isAnime;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: const ValueKey('conversation_search_input'),
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索$_effectiveScopeLabel',
            border: InputBorder.none,
          ),
          onSubmitted: _search,
        ),
        actions: [
          IconButton(
            key: const ValueKey('conversation_search_filter'),
            tooltip: '筛选',
            onPressed: _editFilters,
            icon: Icon(
                _hasFilters ? Icons.filter_alt : Icons.filter_alt_outlined),
          ),
          IconButton(
            key: const ValueKey('conversation_search_submit'),
            tooltip: '搜索',
            onPressed: () => _search(_controller.text),
            icon: const Icon(Icons.search),
          ),
        ],
        bottom: _hasScopedSearch
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        FilterChip(
                          key:
                              const ValueKey('conversation_search_scope_local'),
                          label: Text(widget.scopeLabel),
                          selected: !_searchAllConversations,
                          onSelected: (_) => _setSearchAllConversations(false),
                        ),
                        FilterChip(
                          key: const ValueKey('conversation_search_scope_all'),
                          label: const Text('全部会话'),
                          selected: _searchAllConversations,
                          onSelected: (_) => _setSearchAllConversations(true),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : null,
      ),
      body: _loading
          ? const Center(
              key: ValueKey('conversation_search_loading'),
              child: CircularProgressIndicator(),
            )
          : _errorText != null
              ? isAnime
                  ? AppVisualEmptyState(
                      key: const ValueKey('conversation_search_error'),
                      animeKey:
                          const ValueKey('conversation_search_error_anime'),
                      icon: Icons.cloud_off_rounded,
                      title: '搜索失败',
                      message: _errorText,
                      action: FilledButton.icon(
                        onPressed: () => _search(_controller.text),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重试'),
                      ),
                    )
                  : Center(
                      key: const ValueKey('conversation_search_error'),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _errorText!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    )
              : _results.isEmpty && _favoriteResults.isEmpty
                  ? AppVisualEmptyState(
                      key: const ValueKey('conversation_search_empty'),
                      animeKey:
                          const ValueKey('conversation_search_empty_anime'),
                      icon: _controller.text.trim().isEmpty
                          ? Icons.manage_search_rounded
                          : Icons.search_off_rounded,
                      title: _controller.text.trim().isEmpty
                          ? '输入关键词搜索'
                          : '没有找到相关内容',
                      message: _controller.text.trim().isEmpty
                          ? '可以搜索标题、历史消息和收藏内容。'
                          : '换个关键词，或调整右上角的筛选条件。',
                      classic: Center(
                        child: Text(
                          _controller.text.trim().isEmpty
                              ? '输入关键词搜索'
                              : '没有找到相关内容',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                    )
                  : ListView(
                      key: const ValueKey('conversation_search_results'),
                      children: [
                        if (_results.isNotEmpty)
                          Padding(
                            key: const ValueKey(
                                'conversation_search_conversations'),
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('会话',
                                    style:
                                        Theme.of(context).textTheme.labelLarge),
                                const SizedBox(height: 2),
                                Text(
                                  '按标题、最近消息、历史消息相关性分组；同组内保留置顶和更新时间排序',
                                  key: const ValueKey(
                                      'conversation_search_sort_summary'),
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: isAnime
                                            ? scheme.onSurfaceVariant
                                            : Colors.grey[600],
                                      ),
                                ),
                              ],
                            ),
                          ),
                        for (final group in _conversationResultGroups) ...[
                          Padding(
                            key: ValueKey(
                                'conversation_search_group_${group.title}'),
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                            child: Text(
                              '${group.title}（${group.items.length}）',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                    color: isAnime
                                        ? scheme.onSurfaceVariant
                                        : Colors.grey[700],
                                  ),
                            ),
                          ),
                          for (final item in group.items) ...[
                            ListTile(
                              title: Text(item.conversation.title ?? '(未命名会话)'),
                              subtitle: _ConversationHitSubtitle(
                                item: item,
                                query: _controller.text,
                                expanded: _expandedConversationHits
                                    .contains(_hitKey(item)),
                                onToggle: item.messageSnippets.length <= 1
                                    ? null
                                    : () {
                                        final key = _hitKey(item);
                                        setState(() {
                                          if (!_expandedConversationHits
                                              .add(key)) {
                                            _expandedConversationHits
                                                .remove(key);
                                          }
                                        });
                                      },
                                onSelectHit: (createdAt) => Navigator.pop(
                                  context,
                                  ConversationSearchSelection(
                                    conversation: item.conversation,
                                    targetMessageCreatedAt: createdAt,
                                  ),
                                ),
                              ),
                              trailing: item.targetMessageCreatedAt == null
                                  ? const Icon(Icons.chevron_right)
                                  : const Tooltip(
                                      message: '定位到命中消息',
                                      child: Icon(Icons.my_location_outlined),
                                    ),
                              onTap: () => Navigator.pop(
                                context,
                                ConversationSearchSelection(
                                  conversation: item.conversation,
                                  targetMessageCreatedAt:
                                      item.targetMessageCreatedAt,
                                ),
                              ),
                            ),
                            const Divider(height: 1),
                          ],
                        ],
                        if (_favoriteResults.isNotEmpty)
                          Padding(
                            key:
                                const ValueKey('conversation_search_favorites'),
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                            child: Text('收藏',
                                style: Theme.of(context).textTheme.labelLarge),
                          ),
                        for (final item in _favoriteResults) ...[
                          ListTile(
                            leading: const Icon(Icons.star_border),
                            title: Text(item.favorite.ownerName ?? '收藏'),
                            subtitle: _HighlightedText(
                              text: _favoriteSnippet(item),
                              query: _controller.text,
                              maxLines: 3,
                            ),
                            trailing: item.cid == null
                                ? IconButton(
                                    tooltip: '复制',
                                    icon: const Icon(Icons.copy),
                                    onPressed: () async {
                                      await Clipboard.setData(ClipboardData(
                                          text: item.favorite.content));
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(const SnackBar(
                                              content: Text('收藏内容已复制')));
                                    },
                                  )
                                : const Icon(Icons.chevron_right),
                            onTap: item.cid == null
                                ? null
                                : () => Navigator.pop(
                                      context,
                                      ConversationSearchSelection(
                                        conversation: ConversationModel(
                                          cid: item.cid!,
                                          icon: '',
                                          title: item.conversationTitle,
                                        ),
                                      ),
                                    ),
                          ),
                          const Divider(height: 1),
                        ],
                      ],
                    ),
    );
  }
}

String _favoriteSnippet(FavoriteSearchResult item) {
  if (item.cid == null) return item.favorite.content;
  final title = item.conversationTitle?.trim();
  final displayTitle =
      title == null || title.isEmpty ? '会话 ${item.cid}' : title;
  return '来自「$displayTitle」 · ${item.favorite.content}';
}

class _ConversationHitSubtitle extends StatelessWidget {
  final ConversationSearchResult item;
  final String query;
  final bool expanded;
  final VoidCallback? onToggle;
  final ValueChanged<int>? onSelectHit;

  const _ConversationHitSubtitle({
    required this.item,
    required this.query,
    required this.expanded,
    this.onToggle,
    this.onSelectHit,
  });

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final extraHits = item.messageHits.skip(1).toList(growable: false);
    final text = item.sourceLabel.isEmpty
        ? item.snippet
        : '${item.sourceLabel} · ${item.snippet}';
    if (extraHits.isEmpty) {
      return _HighlightedText(text: text, query: query, maxLines: 2);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _HighlightedText(text: text, query: query, maxLines: 2),
        if (expanded)
          ...extraHits.map(
            (hit) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                key: ValueKey(
                  'conversation_search_hit_${item.conversation.cid}_${hit.createdAt}',
                ),
                borderRadius: BorderRadius.circular(visual.isAnime ? 12 : 6),
                onTap: hit.createdAt == null || onSelectHit == null
                    ? null
                    : () => onSelectHit!(hit.createdAt!),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: visual.isAnime ? 10 : 2,
                    horizontal: visual.isAnime ? 4 : 0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _HighlightedText(
                          text: '历史消息 · ${hit.snippet}',
                          query: query,
                          maxLines: 2,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.my_location_outlined,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key:
                ValueKey('conversation_search_expand_${item.conversation.cid}'),
            style: visual.isAnime
                ? TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  )
                : TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
            onPressed: onToggle,
            icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
            label: Text(expanded ? '收起命中片段' : '展开 ${extraHits.length} 处命中'),
          ),
        ),
      ],
    );
  }
}

class _HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  final int maxLines;

  const _HighlightedText({
    required this.text,
    required this.query,
    required this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    final style = DefaultTextStyle.of(context).style;
    if (q.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis);
    }
    final lower = text.toLowerCase();
    final needle = q.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final index = lower.indexOf(needle, start);
      if (index < 0) break;
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(TextSpan(
        text: text.substring(index, index + q.length),
        style: style.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ));
      start = index + q.length;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return RichText(
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: style, children: spans),
    );
  }
}

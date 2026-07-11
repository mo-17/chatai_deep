import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/pages/story_persona_edit_page.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:flutter/material.dart';

/// 账号级 Persona 列表，也可作为选择 Persona 的页面使用。
class StoryPersonaListPage extends StatefulWidget {
  final bool selectionMode;
  final StoryPersonaDao? dao;
  final List<StoryPersonaModel>? initialPersonas;

  const StoryPersonaListPage({
    super.key,
    this.selectionMode = false,
    this.dao,
    this.initialPersonas,
  });

  @override
  State<StoryPersonaListPage> createState() => _StoryPersonaListPageState();
}

class _StoryPersonaListPageState extends State<StoryPersonaListPage> {
  StoryPersonaDao? _dao;
  List<StoryPersonaModel> _personas = const [];
  Object? _loadError;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _dao = widget.dao;
    final initialPersonas = widget.initialPersonas;
    if (initialPersonas != null) {
      _personas = List<StoryPersonaModel>.of(initialPersonas);
      _loading = false;
    } else {
      _load();
    }
  }

  Future<StoryPersonaDao> _createDao() async {
    final storage = await HiDBManager.instance(
      dbName: HiDBManager.getAccountHash(),
    );
    return StoryPersonaDao.create(storage);
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final dao = _dao ??= await _createDao();
      final personas = await dao.getPersonas();
      if (!mounted) return;
      setState(() {
        _personas = personas;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _openEditor([StoryPersonaModel? persona]) async {
    final dao = _dao;
    if (dao == null) return;
    final saved = await Navigator.of(context).push<StoryPersonaModel>(
      MaterialPageRoute<StoryPersonaModel>(
        builder: (_) => StoryPersonaEditPage(
          persona: persona,
          dao: dao,
        ),
      ),
    );
    if (saved == null || !mounted) return;
    final index = _personas.indexWhere(
      (item) => item.personaKey == saved.personaKey,
    );
    setState(() {
      if (index < 0) {
        _personas = [..._personas, saved];
      } else {
        final personas = List<StoryPersonaModel>.of(_personas);
        personas[index] = saved;
        _personas = personas;
      }
    });
  }

  Future<void> _deletePersona(StoryPersonaModel persona) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除 Persona？'),
        content: Text('确定删除“${persona.name}”吗？此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final id = persona.id;
    if (id == null) {
      HiDialog.showSnackBar(context, 'Persona 尚未保存');
      return;
    }
    try {
      final deleted = await _dao!.deletePersona(id);
      if (!mounted) return;
      if (deleted) {
        setState(() {
          _personas = _personas
              .where((item) => item.personaKey != persona.personaKey)
              .toList();
        });
      } else {
        HiDialog.showSnackBar(context, 'Persona 已不存在');
      }
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '删除失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('story_persona_list_page'),
      appBar: AppBar(
        title: Text(widget.selectionMode ? '选择 Persona' : 'Persona'),
        actions: [
          IconButton(
            key: const ValueKey('story_persona_add'),
            tooltip: '新建 Persona',
            onPressed: _loading ? null : () => _openEditor(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _loading || _loadError != null
          ? null
          : FloatingActionButton(
              key: const ValueKey('story_persona_empty_add'),
              tooltip: '新建 Persona',
              onPressed: () => _openEditor(),
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Persona 加载失败'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('story_persona_retry'),
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_personas.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline, size: 44),
              const SizedBox(height: 12),
              const Text('还没有 Persona'),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('story_persona_empty_add_button'),
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add),
                label: const Text('新建 Persona'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: _personas.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) => _buildPersonaTile(_personas[index]),
    );
  }

  Widget _buildPersonaTile(StoryPersonaModel persona) {
    final emoji = persona.avatarType == 'image' ? '🙂' : persona.avatarValue;
    return ListTile(
      key: ValueKey('story_persona_item_${persona.personaKey}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: AssistantAvatar.raw(
        emoji: emoji,
        avatarType: persona.avatarType,
        avatarValue: persona.avatarValue,
        radius: 24,
      ),
      title: Text(
        persona.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: persona.description.trim().isEmpty
          ? null
          : Text(
              persona.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.selectionMode)
            IconButton(
              key: ValueKey('story_persona_edit_${persona.personaKey}'),
              tooltip: '编辑 Persona',
              onPressed: () => _openEditor(persona),
              icon: const Icon(Icons.edit_outlined),
            ),
          IconButton(
            key: ValueKey('story_persona_delete_${persona.personaKey}'),
            tooltip: '删除 Persona',
            onPressed: () => _deletePersona(persona),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      onTap: () {
        if (widget.selectionMode) {
          Navigator.of(context).pop(persona);
        } else {
          _openEditor(persona);
        }
      },
    );
  }
}

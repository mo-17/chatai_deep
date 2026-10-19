import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:chatgpt_app_core/widget/story_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class StoryPersonaEditPage extends StatefulWidget {
  final StoryPersonaModel? persona;
  final StoryPersonaDao? dao;
  final ImagePicker? imagePicker;

  const StoryPersonaEditPage({
    super.key,
    this.persona,
    this.dao,
    this.imagePicker,
  });

  @override
  State<StoryPersonaEditPage> createState() => _StoryPersonaEditPageState();
}

class _StoryPersonaEditPageState extends State<StoryPersonaEditPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _emojiController;
  late final ImagePicker _imagePicker;
  String _avatarType = 'emoji';
  String _avatarValue = '🙂';
  String? _pendingImagePath;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final persona = widget.persona;
    final isImage = persona?.avatarType == AvatarAssetService.imageType;
    _nameController = TextEditingController(text: persona?.name ?? '');
    _descriptionController =
        TextEditingController(text: persona?.description ?? '');
    _emojiController = TextEditingController(
      text: isImage
          ? '🙂'
          : (persona?.avatarValue.trim().isEmpty ?? true)
              ? '🙂'
              : persona!.avatarValue,
    );
    _avatarType = persona?.avatarType.trim().isEmpty ?? true
        ? 'emoji'
        : persona!.avatarType;
    _avatarValue = persona?.avatarValue.trim().isEmpty ?? true
        ? _emojiController.text
        : persona!.avatarValue;
    _imagePicker = widget.imagePicker ?? ImagePicker();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _emojiController.dispose();
    super.dispose();
  }

  Future<StoryPersonaDao> _createDao() async {
    final storage = await HiDBManager.instance(
      dbName: HiDBManager.getAccountHash(),
    );
    return StoryPersonaDao.create(storage);
  }

  Future<StoryPersonaDao> _resolveDao() async {
    final dao = widget.dao;
    if (dao != null) return dao;
    return _createDao();
  }

  Future<void> _pickAvatar() async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (!mounted || picked == null) return;
      setState(() {
        _pendingImagePath = picked.path;
        _avatarType = AvatarAssetService.imageType;
        _avatarValue = picked.path;
      });
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '图片选择失败：$error');
    }
  }

  void _useEmojiAvatar() {
    setState(() {
      _pendingImagePath = null;
      _avatarType = 'emoji';
      _avatarValue = _emojiController.text.trim().isEmpty
          ? '🙂'
          : _emojiController.text.trim();
    });
  }

  StoryPersonaModel _draftModel() {
    final persona = widget.persona;
    final emoji = _emojiController.text.trim().isEmpty
        ? '🙂'
        : _emojiController.text.trim();
    return StoryPersonaModel(
      id: persona?.id,
      personaKey: persona?.personaKey,
      name: _nameController.text.trim(),
      description: _descriptionController.text,
      avatarType: _avatarType,
      avatarValue:
          _avatarType == AvatarAssetService.imageType ? _avatarValue : emoji,
      createdAt: persona?.createdAt,
      updatedAt: persona?.updatedAt,
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final description = _descriptionController.text;
    if (name.isEmpty) {
      HiDialog.showSnackBar(context, '请输入 Persona 名称');
      return;
    }
    if (name.length > StoryPersonaLimits.maxNameLength) {
      HiDialog.showSnackBar(
          context, '名称不能超过 ${StoryPersonaLimits.maxNameLength} 个字符');
      return;
    }
    if (description.length > StoryPersonaLimits.maxDescriptionLength) {
      HiDialog.showSnackBar(
        context,
        '简介不能超过 ${StoryPersonaLimits.maxDescriptionLength} 个字符',
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final dao = await _resolveDao();
      final model = _draftModel();
      final pendingImagePath = _pendingImagePath;
      if (pendingImagePath != null) {
        // 由 DAO 把相册临时路径复制到应用托管目录并写入 Persona。
        await dao.savePersonaAvatar(model, sourcePath: pendingImagePath);
      } else {
        await dao.savePersona(model);
      }
      if (!mounted) return;
      Navigator.of(context).pop(model);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        HiDialog.showSnackBar(context, '保存失败：$error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final emoji = _emojiController.text.trim().isEmpty
        ? '🙂'
        : _emojiController.text.trim();
    final hasImage = _avatarType == AvatarAssetService.imageType &&
        _avatarValue.trim().isNotEmpty;
    return Scaffold(
      key: const ValueKey('story_persona_edit_page'),
      appBar: AppBar(
        title: Text(widget.persona == null ? '新建 Persona' : '编辑 Persona'),
        actions: [
          IconButton(
            key: const ValueKey('story_persona_save'),
            tooltip: '保存 Persona',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: StoryAdaptiveSurface(
        animeKey: const ValueKey('anime_story_persona_editor_surface'),
        animeMargin: const EdgeInsets.all(12),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    AssistantAvatar.raw(
                      emoji: emoji,
                      avatarType: _avatarType,
                      avatarValue: _avatarValue,
                      radius: 38,
                    ),
                    IconButton.filled(
                      key: const ValueKey('story_persona_pick_avatar'),
                      tooltip: '从相册选择图片头像',
                      onPressed: _saving ? null : _pickAvatar,
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: kStoryMinTouchTarget,
                        height: kStoryMinTouchTarget,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasImage ? '图片头像' : 'Emoji 头像',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const ValueKey('story_persona_emoji'),
                        controller: _emojiController,
                        maxLength: 8,
                        textInputAction: TextInputAction.done,
                        onChanged: (_) {
                          if (!hasImage) setState(() {});
                        },
                        decoration: InputDecoration(
                          labelText: 'Emoji',
                          hintText: '🙂',
                          border: storyInputBorder(context),
                          counterText: '',
                          isDense: true,
                        ),
                      ),
                      if (hasImage)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('story_persona_use_emoji'),
                            onPressed: _saving ? null : _useEmojiAvatar,
                            icon: const Icon(Icons.emoji_emotions_outlined),
                            label: const Text('改用 Emoji'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            TextField(
              key: const ValueKey('story_persona_name'),
              controller: _nameController,
              maxLength: StoryPersonaLimits.maxNameLength,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '名称',
                hintText: '例如：冷静的编辑',
                border: storyInputBorder(context),
                prefixIcon: const Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('story_persona_description'),
              controller: _descriptionController,
              minLines: 4,
              maxLines: 8,
              maxLength: StoryPersonaLimits.maxDescriptionLength,
              decoration: InputDecoration(
                labelText: '简介',
                hintText: '描述这个 Persona 的语气、背景或使用场景',
                border: storyInputBorder(context),
                alignLabelWithHint: true,
                prefixIcon: const Padding(
                  padding: EdgeInsets.only(bottom: 72),
                  child: Icon(Icons.notes_outlined),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '名称和简介会按当前账号保存。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

# Starcore Runtime UI Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the approved Starcore assets in `chatgpt_app_core` and use them for anime-only navigation, assistant avatars, conversation avatars, and web/knowledge tool glyphs while preserving every classic-theme fallback.

**Architecture:** A pure asset catalog plus one SVG renderer owns package-qualified paths and fallbacks. `chat_message` gains a generic avatar-builder hook without depending on shared core; shared core implements the anime-aware Starcore builder and propagates stable `asset:` ids through assistants and normal conversations. Tool ids remain application metadata, while their visual mapping stays in the UI layer.

**Tech Stack:** Dart 3, Flutter/FVM, `flutter_svg 2.3.0`, Provider, `flutter_test`, package assets, existing `chat_message` and `chatgpt_app_core` path packages.

## Global Constraints

- The design source of truth remains `docs/design-assets/starcore-guide/`; runtime copies must be byte-identical to the six SVG and two assistant PNG masters.
- Declare `flutter_svg: ^2.3.0` directly in `chatgpt_app_core/pubspec.yaml`; never rely on its current transitive lock entry.
- Every package asset load must pass `package: 'chatgpt_app_core'`.
- Starcore navigation, assistant, and tool visuals render only when `AppVisualTheme.of(context).isAnime` is true; classic visuals and colors remain unchanged.
- Only Chat/Create navigation and `web_search`/`knowledge_search` tools receive approved SVGs; do not invent icons for the other destinations or tools.
- Persist assistant presets as `avatarType='asset'` plus stable ids `starcore_explorer` or `starcore_creator`; do not persist package paths and do not migrate SQLite.
- Never delete an `asset` id through `AvatarAssetService.deleteAssistantAvatar`; only managed local image paths are deletable.
- `ToolBlock.toolId` is a call instance id; choose a tool glyph from `block.toolName`.
- Preserve at least 44dp interactive targets and exclude decorative SVG semantics so labels are announced once.
- Story-room persona avatar propagation is outside this plan; unknown asset types there continue to fall back to emoji.
- Write and observe every focused failing test before production changes, then commit each task separately.

---

### Task 1: Package the approved assets and add the shared renderer

**Files:**
- Create: `chatgpt_app_core/assets/icons/starcore/assistant-creator.png`
- Create: `chatgpt_app_core/assets/icons/starcore/assistant-explorer.png`
- Create: `chatgpt_app_core/assets/icons/starcore/nav-chat-default.svg`
- Create: `chatgpt_app_core/assets/icons/starcore/nav-chat-selected.svg`
- Create: `chatgpt_app_core/assets/icons/starcore/nav-create-default.svg`
- Create: `chatgpt_app_core/assets/icons/starcore/nav-create-selected.svg`
- Create: `chatgpt_app_core/assets/icons/starcore/tool-knowledge-search.svg`
- Create: `chatgpt_app_core/assets/icons/starcore/tool-web-search.svg`
- Create: `chatgpt_app_core/lib/theme/starcore_icon_assets.dart`
- Create: `chatgpt_app_core/lib/widget/starcore_svg_icon.dart`
- Create: `chatgpt_app_core/test/starcore_runtime_icons_test.dart`
- Modify: `chatgpt_app_core/pubspec.yaml:10-61`
- Modify: `chatgpt_app_core/pubspec.lock`

**Interfaces:**
- Consumes: the approved files under `docs/design-assets/starcore-guide/` and Flutter's package asset bundle.
- Produces: `StarcoreIconAssets`, `StarcoreSvgIcon`, and eight package-qualified runtime assets for all later tasks.

- [ ] **Step 1: Write the failing asset-catalog and renderer tests**

Create `starcore_runtime_icons_test.dart` with catalog assertions and a real asset pump:

```dart
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/widget/starcore_svg_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Starcore assistant ids map only to approved package assets', () {
    expect(
      StarcoreIconAssets.assistantAssetFor(
        StarcoreIconAssets.assistantExplorerId,
      ),
      StarcoreIconAssets.assistantExplorer,
    );
    expect(
      StarcoreIconAssets.assistantAssetFor(
        StarcoreIconAssets.assistantCreatorId,
      ),
      StarcoreIconAssets.assistantCreator,
    );
    expect(StarcoreIconAssets.assistantAssetFor('unknown'), isNull);
    expect(
      StarcoreIconAssets.parseMessageAvatar('asset:starcore_explorer'),
      StarcoreIconAssets.assistantExplorerId,
    );
  });

  testWidgets('approved SVG resolves from the shared-core package',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StarcoreSvgIcon(
            assetName: StarcoreIconAssets.navChatDefault,
            fallback: Icon(Icons.chat_bubble_outline),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('starcore-svg-nav-chat-default')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing SVG renders the supplied Material fallback',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StarcoreSvgIcon(
          assetName: 'assets/icons/starcore/missing.svg',
          fallback: Icon(Icons.extension_off, key: ValueKey('svg-fallback')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('svg-fallback')), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/starcore_runtime_icons_test.dart
```

Expected: compilation fails because `StarcoreIconAssets` and `StarcoreSvgIcon` do not exist.

- [ ] **Step 3: Copy the approved masters and declare the direct dependency**

Copy exactly these files, without conversion:

```bash
mkdir -p chatgpt_app_core/assets/icons/starcore
cp docs/design-assets/starcore-guide/assistant-creator.png chatgpt_app_core/assets/icons/starcore/
cp docs/design-assets/starcore-guide/assistant-explorer.png chatgpt_app_core/assets/icons/starcore/
cp docs/design-assets/starcore-guide/nav-chat-default.svg chatgpt_app_core/assets/icons/starcore/
cp docs/design-assets/starcore-guide/nav-chat-selected.svg chatgpt_app_core/assets/icons/starcore/
cp docs/design-assets/starcore-guide/nav-create-default.svg chatgpt_app_core/assets/icons/starcore/
cp docs/design-assets/starcore-guide/nav-create-selected.svg chatgpt_app_core/assets/icons/starcore/
cp docs/design-assets/starcore-guide/tool-knowledge-search.svg chatgpt_app_core/assets/icons/starcore/
cp docs/design-assets/starcore-guide/tool-web-search.svg chatgpt_app_core/assets/icons/starcore/
```

Add to `chatgpt_app_core/pubspec.yaml`:

```yaml
dependencies:
  flutter_svg: ^2.3.0

flutter:
  assets:
    - assets/icons/starcore/
```

Then resolve from the actual package:

```bash
cd chatgpt_app_core
fvm flutter pub get
```

Expected: `flutter_svg` changes from transitive to direct in `chatgpt_app_core/pubspec.lock`; no native plugin is added.

- [ ] **Step 4: Implement the immutable asset catalog**

Create `starcore_icon_assets.dart`:

```dart
abstract final class StarcoreIconAssets {
  static const packageName = 'chatgpt_app_core';
  static const assistantExplorerId = 'starcore_explorer';
  static const assistantCreatorId = 'starcore_creator';
  static const messageAssetPrefix = 'asset:';

  static const navChatDefault =
      'assets/icons/starcore/nav-chat-default.svg';
  static const navChatSelected =
      'assets/icons/starcore/nav-chat-selected.svg';
  static const navCreateDefault =
      'assets/icons/starcore/nav-create-default.svg';
  static const navCreateSelected =
      'assets/icons/starcore/nav-create-selected.svg';
  static const toolWebSearch =
      'assets/icons/starcore/tool-web-search.svg';
  static const toolKnowledgeSearch =
      'assets/icons/starcore/tool-knowledge-search.svg';
  static const assistantExplorer =
      'assets/icons/starcore/assistant-explorer.png';
  static const assistantCreator =
      'assets/icons/starcore/assistant-creator.png';

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
```

- [ ] **Step 5: Implement the package-qualified SVG renderer**

Create `starcore_svg_icon.dart`:

```dart
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class StarcoreSvgIcon extends StatelessWidget {
  final String assetName;
  final Widget fallback;
  final double size;
  final bool excludeFromSemantics;

  const StarcoreSvgIcon({
    super.key,
    required this.assetName,
    required this.fallback,
    this.size = 24,
    this.excludeFromSemantics = true,
  });

  String get assetKey =>
      'starcore-svg-${assetName.split('/').last.replaceFirst('.svg', '')}';

  @override
  Widget build(BuildContext context) => SizedBox.square(
        key: ValueKey(assetKey),
        dimension: size,
        child: SvgPicture.asset(
          assetName,
          package: StarcoreIconAssets.packageName,
          width: size,
          height: size,
          fit: BoxFit.contain,
          excludeFromSemantics: excludeFromSemantics,
          placeholderBuilder: (_) => Center(child: fallback),
          errorBuilder: (_, __, ___) => Center(child: fallback),
        ),
      );
}
```

- [ ] **Step 6: Verify byte identity and GREEN**

Run:

```bash
cmp docs/design-assets/starcore-guide/assistant-creator.png chatgpt_app_core/assets/icons/starcore/assistant-creator.png
cmp docs/design-assets/starcore-guide/assistant-explorer.png chatgpt_app_core/assets/icons/starcore/assistant-explorer.png
for f in nav-chat-default.svg nav-chat-selected.svg nav-create-default.svg nav-create-selected.svg tool-knowledge-search.svg tool-web-search.svg; do cmp "docs/design-assets/starcore-guide/$f" "chatgpt_app_core/assets/icons/starcore/$f"; done
cd chatgpt_app_core
fvm flutter test --no-pub test/starcore_runtime_icons_test.dart
```

Expected: all `cmp` commands exit 0 and all three Flutter tests pass.

- [ ] **Step 7: Commit the asset foundation**

```bash
git add chatgpt_app_core/assets/icons/starcore chatgpt_app_core/lib/theme/starcore_icon_assets.dart chatgpt_app_core/lib/widget/starcore_svg_icon.dart chatgpt_app_core/test/starcore_runtime_icons_test.dart chatgpt_app_core/pubspec.yaml chatgpt_app_core/pubspec.lock
git commit -m "feat(ui): package Starcore runtime icon assets"
```

---

### Task 2: Replace anime Chat/Create navigation glyphs

**Files:**
- Modify: `chatgpt_app_core/lib/pages/bottom_navigator.dart:146-218`
- Modify: `chatgpt_app_core/test/app_bottom_navigation_bar_test.dart`

**Interfaces:**
- Consumes: `StarcoreIconAssets` and `StarcoreSvgIcon` from Task 1.
- Produces: anime `NavigationDestination` properties with approved default/selected glyphs; the classic `BottomNavigationBar` interface is unchanged.

- [ ] **Step 1: Add failing navigation-property assertions**

After switching the existing test to anime, inspect the destination properties:

```dart
final destinations = tester.widgetList<NavigationDestination>(
  find.byType(NavigationDestination),
).toList();
expect(destinations, hasLength(4));
expect(
  (destinations[0].icon as StarcoreSvgIcon).assetName,
  StarcoreIconAssets.navChatDefault,
);
expect(
  (destinations[0].selectedIcon! as StarcoreSvgIcon).assetName,
  StarcoreIconAssets.navChatSelected,
);
expect(destinations[1].icon, isA<Icon>());
expect(
  (destinations[2].icon as StarcoreSvgIcon).assetName,
  StarcoreIconAssets.navCreateDefault,
);
expect(
  (destinations[2].selectedIcon! as StarcoreSvgIcon).assetName,
  StarcoreIconAssets.navCreateSelected,
);
expect(destinations[3].icon, isA<Icon>());
```

Also assert the classic branch contains no `StarcoreSvgIcon` after switching back to `AppVisualStyle.classic`.

Use `tester.ensureSemantics()` and assert each of `聊天`, `精彩`, `创作`, and `我的` appears once; no SVG filename may appear as a semantics label.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/app_bottom_navigation_bar_test.dart
```

Expected: casts fail because all four anime destinations still contain Material `Icon` widgets.

- [ ] **Step 3: Replace only the approved anime destinations**

Import the Task 1 types and change the anime destinations from a const list to this state-independent list:

```dart
destinations: [
  const NavigationDestination(
    icon: StarcoreSvgIcon(
      assetName: StarcoreIconAssets.navChatDefault,
      fallback: Icon(Icons.chat_bubble_outline_rounded),
    ),
    selectedIcon: StarcoreSvgIcon(
      assetName: StarcoreIconAssets.navChatSelected,
      fallback: Icon(Icons.chat_bubble_rounded),
    ),
    label: '聊天',
  ),
  const NavigationDestination(
    icon: Icon(Icons.local_fire_department_outlined),
    selectedIcon: Icon(Icons.local_fire_department_rounded),
    label: '精彩',
  ),
  const NavigationDestination(
    icon: StarcoreSvgIcon(
      assetName: StarcoreIconAssets.navCreateDefault,
      fallback: Icon(Icons.theater_comedy_outlined),
    ),
    selectedIcon: StarcoreSvgIcon(
      assetName: StarcoreIconAssets.navCreateSelected,
      fallback: Icon(Icons.theater_comedy_rounded),
    ),
    label: '创作',
  ),
  const NavigationDestination(
    icon: Icon(Icons.account_circle_outlined),
    selectedIcon: Icon(Icons.account_circle_rounded),
    label: '我的',
  ),
],
```

Do not modify `_classicItem`, labels, page order, callbacks, or navigation keys.

- [ ] **Step 4: Run navigation and asset tests**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/app_bottom_navigation_bar_test.dart test/starcore_runtime_icons_test.dart
```

Expected: all tests pass; tapping “我的”/“创作” still yields indices 3/2.

- [ ] **Step 5: Commit the navigation slice**

```bash
git add chatgpt_app_core/lib/pages/bottom_navigator.dart chatgpt_app_core/test/app_bottom_navigation_bar_test.dart
git commit -m "feat(ui): use Starcore anime navigation icons"
```

---

### Task 3: Add a generic message-avatar builder to `chat_message`

**Files:**
- Create: `chat_message/lib/widget/message_avatar_builder.dart`
- Create: `chat_message/test/message_avatar_builder_test.dart`
- Modify: `chat_message/lib/widget/default_message_widget.dart:8-143`
- Modify: `chat_message/lib/widget/chat_list.dart:8-93`

**Interfaces:**
- Consumes: `MessageModel` and existing URL/File/emoji/initials avatar behavior.
- Produces: `MessageAvatarBuilder` plus optional `avatarBuilder` constructor arguments on `DefaultMessageWidget` and `ChatList`; null preserves all existing behavior.

- [ ] **Step 1: Write failing override, forwarding, and fallback tests**

Create `message_avatar_builder_test.dart`:

```dart
import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final message = MessageModel(
    ownerType: OwnerType.receiver,
    ownerName: '艾琳',
    avatar: 'asset:starcore_explorer',
    content: '你好',
    createdAt: 1000,
  );

  test('asset avatar protocol survives MessageModel JSON round-trip', () {
    final restored = MessageModel.fromJson(message.toJson());
    expect(restored.avatar, 'asset:starcore_explorer');
  });

  testWidgets('DefaultMessageWidget uses a non-null avatar override',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DefaultMessageWidget(
        key: GlobalKey(),
        message: message,
        avatarBuilder: (_, __, size) => SizedBox.square(
          key: const ValueKey('custom-message-avatar'),
          dimension: size,
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('custom-message-avatar')), findsOneWidget);
    expect(find.text('艾'), findsNothing);
  });

  testWidgets('null override preserves the existing emoji protocol',
      (tester) async {
    final emojiMessage = MessageModel(
      ownerType: OwnerType.receiver,
      ownerName: '艾琳',
      avatar: 'emoji:${Uri.encodeComponent('🎭')}',
      content: '你好',
      createdAt: 1001,
    );
    await tester.pumpWidget(MaterialApp(
      home: DefaultMessageWidget(
        key: GlobalKey(),
        message: emojiMessage,
        avatarBuilder: (_, __, ___) => null,
      ),
    ));
    expect(find.text('🎭'), findsOneWidget);
  });

  testWidgets('ChatList forwards avatarBuilder', (tester) async {
    final controller = ChatController(
      initialMessageList: [message],
      itemScrollController: ItemScrollController(),
      itemPositionsListener: ItemPositionsListener.create(),
      timePellet: 60,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatList(
          chatController: controller,
          avatarBuilder: (_, __, size) => SizedBox.square(
            key: const ValueKey('forwarded-message-avatar'),
            dimension: size,
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('forwarded-message-avatar')), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
cd chat_message
fvm spawn 3.35.7 test --no-pub test/message_avatar_builder_test.dart
```

Expected: compilation fails because neither widget accepts `avatarBuilder`.

- [ ] **Step 3: Define the package-neutral callback**

Create `message_avatar_builder.dart`:

```dart
import 'package:chat_message/models/message_model.dart';
import 'package:flutter/widgets.dart';

typedef MessageAvatarBuilder = Widget? Function(
  BuildContext context,
  MessageModel message,
  double avatarSize,
);
```

- [ ] **Step 4: Thread the callback through the two widgets**

Add `final MessageAvatarBuilder? avatarBuilder;` and optional constructor arguments to both widgets. In `DefaultMessageWidget`, change the avatar getter into a context-aware method:

```dart
Widget _buildCircleAvatar(BuildContext context) {
  final override = avatarBuilder?.call(context, message, avatarSize);
  if (override != null) return override;
  final avatar = message.avatar?.trim() ?? '';
  // Keep the existing empty, emoji, local-file, and network branches verbatim.
}
```

Call `_buildCircleAvatar(context)` from `_buildReceiver` and `_buildSender`. In `ChatList`, pass `avatarBuilder: widget.avatarBuilder` to every `DefaultMessageWidget`.

- [ ] **Step 5: Run the new and existing package regressions**

Run:

```bash
cd chat_message
fvm spawn 3.35.7 test --no-pub test/message_avatar_builder_test.dart test/chat_message_test.dart test/chat_list_test.dart
```

Expected: all tests pass, including missing-file and emoji fallbacks.

- [ ] **Step 6: Commit the generic hook**

```bash
git add chat_message/lib/widget/message_avatar_builder.dart chat_message/lib/widget/default_message_widget.dart chat_message/lib/widget/chat_list.dart chat_message/test/message_avatar_builder_test.dart
git commit -m "feat(chat-message): add message avatar builder hook"
```

---

### Task 4: Add assistant asset rendering and explicit presets

**Files:**
- Create: `chatgpt_app_core/lib/widget/assistant_avatar_preset_picker.dart`
- Create: `chatgpt_app_core/test/assistant_edit_avatar_preset_test.dart`
- Create: `chatgpt_app_core/test/assistant_avatar_preset_test.dart`
- Modify: `chatgpt_app_core/lib/util/avatar_asset_service.dart:7-12`
- Modify: `chatgpt_app_core/lib/widget/assistant_avatar.dart`
- Modify: `chatgpt_app_core/lib/pages/assistant_edit_page.dart:535-610,1007-1080`
- Modify: `chatgpt_app_core/test/assistant_avatar_performance_test.dart`
- Verify: `chatgpt_app_core/test/assistant_market_page_test.dart`
- Verify: `chatgpt_app_core/test/assistant_anime_coverage_test.dart`

**Interfaces:**
- Consumes: `StarcoreIconAssets`, `AvatarAssetService.imageType`, and existing assistant form fields.
- Produces: `AvatarAssetService.assetType`, anime asset rendering, and `AssistantAvatarPresetPicker(selectedAssetId, onSelected)` where null means Emoji.

- [ ] **Step 1: Write failing asset-render and preset-selection tests**

Extend `assistant_avatar_performance_test.dart`:

```dart
testWidgets('asset preset renders only in anime and keeps an emoji fallback',
    (tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppThemeFactory.anime(),
    home: const Scaffold(
      body: AssistantAvatar.raw(
        emoji: '🤖',
        avatarType: AvatarAssetService.assetType,
        avatarValue: StarcoreIconAssets.assistantExplorerId,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  final image = tester.widget<Image>(find.byType(Image));
  final provider = image.image as ResizeImage;
  final asset = provider.image as AssetImage;
  expect(asset.assetName, StarcoreIconAssets.assistantExplorer);
  expect(asset.package, StarcoreIconAssets.packageName);

  await tester.pumpWidget(MaterialApp(
    theme: AppThemeFactory.classic(Colors.blue),
    home: const Scaffold(
      body: AssistantAvatar.raw(
        emoji: '🤖',
        avatarType: AvatarAssetService.assetType,
        avatarValue: StarcoreIconAssets.assistantExplorerId,
      ),
    ),
  ));
  expect(find.byType(Image), findsNothing);
  expect(find.text('🤖'), findsOneWidget);
});
```

Create `assistant_avatar_preset_test.dart` and assert tapping keys `assistant-avatar-preset-explorer`, `assistant-avatar-preset-creator`, and `assistant-avatar-preset-emoji` reports the two stable ids and null respectively.

Add a second avatar case with `avatarValue: 'unknown'`; in anime it must render the supplied emoji and no `Image`, proving unknown ids never become arbitrary asset paths.

Using the existing `Image.errorBuilder!` pattern in `assistant_avatar_performance_test.dart`, invoke the packaged-avatar error builder and assert it renders the supplied emoji; with an empty emoji it must render the existing `smart_toy` fallback. This covers decode failure without corrupting a checked-in PNG.

Create `assistant_edit_avatar_preset_test.dart` with an `AISettingsProvider` host and an injected `AssistantEditSaver`. Cover two page-level paths:

```dart
testWidgets('assistant editor saves a Starcore preset without opening a picker',
    (tester) async {
  final settings = AISettingsProvider();
  AssistantModel? saved;
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: AppThemeFactory.anime(),
        home: AssistantEditPage(
          assistant: AssistantModel(id: 7, name: '向导', emoji: '🤖'),
          saveAssistant: (assistant) async {
            saved = assistant;
          },
        ),
      ),
    ),
  );
  await tester.tap(
    find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
  );
  await tester.tap(find.text('保存修改'));
  await tester.pump();
  expect(saved?.avatarType, AvatarAssetService.assetType);
  expect(saved?.avatarValue, StarcoreIconAssets.assistantExplorerId);
});
```

In a second anime pump, select `starcore_creator`, enter `🛰️` into the keyed Emoji field, save, and assert `avatarType/avatarValue` are both null while `emoji == '🛰️'`. The test must never tap either image-upload control; the preset path is independent of gallery support, including HarmonyOS. Add a classic-theme pump with an existing asset id: the preset picker is absent, saving preserves that id, and no package `Image` is built.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/assistant_avatar_performance_test.dart test/assistant_avatar_preset_test.dart test/assistant_edit_avatar_preset_test.dart
```

Expected: compilation fails because `assetType` and `AssistantAvatarPresetPicker` do not exist.

- [ ] **Step 3: Add the stable avatar type and picker**

Add to `AvatarAssetService`:

```dart
static const imageType = 'image';
static const assetType = 'asset';
```

Implement the picker as a `Wrap` of three `ChoiceChip`s:

```dart
class AssistantAvatarPresetPicker extends StatelessWidget {
  final String? selectedAssetId;
  final ValueChanged<String?> onSelected;

  const AssistantAvatarPresetPicker({
    super.key,
    required this.selectedAssetId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            key: const ValueKey('assistant-avatar-preset-emoji'),
            label: const Text('Emoji'),
            selected: selectedAssetId == null,
            onSelected: (_) => onSelected(null),
          ),
          ChoiceChip(
            key: const ValueKey('assistant-avatar-preset-explorer'),
            label: const Text('探索向导'),
            selected: selectedAssetId == StarcoreIconAssets.assistantExplorerId,
            onSelected: (_) =>
                onSelected(StarcoreIconAssets.assistantExplorerId),
          ),
          ChoiceChip(
            key: const ValueKey('assistant-avatar-preset-creator'),
            label: const Text('创作搭档'),
            selected: selectedAssetId == StarcoreIconAssets.assistantCreatorId,
            onSelected: (_) =>
                onSelected(StarcoreIconAssets.assistantCreatorId),
          ),
        ],
      );
}
```

- [ ] **Step 4: Render valid asset ids in `AssistantAvatar`**

Before the emoji branch, resolve an asset only in anime mode:

```dart
final visual = AppVisualTheme.of(context);
if (visual.isAnime && type == AvatarAssetService.assetType) {
  final asset = StarcoreIconAssets.assistantAssetFor(value);
  if (asset != null) return _assetAvatar(context, asset);
}
```

Implement `_assetAvatar` with `Image.asset`, the same DPR-derived `cacheWidth/cacheHeight`, `package: StarcoreIconAssets.packageName`, and circular clipping. Its error builder uses the assistant/raw emoji when non-empty, otherwise a `CircleAvatar` with the existing `smart_toy` Material icon. Keep this fallback separate from asset resolution so a decode error cannot recurse into the same asset.

- [ ] **Step 5: Wire the picker into the assistant editor**

Under the avatar preview, derive `selectedAssetId` only when `_avatarType == AvatarAssetService.assetType`, and build `AssistantAvatarPresetPicker` only when `AppVisualTheme.of(context).isAnime`. The classic branch must not add choice-chip UI and must not clear a stored asset id. On selection:

Add `import 'dart:async';` beside the existing `dart:io` import, then use:

```dart
void _selectAvatarPreset(String? assetId) {
  final oldPath = _avatarType == AvatarAssetService.imageType
      ? _avatarValue
      : null;
  setState(() {
    _avatarType = assetId == null ? null : AvatarAssetService.assetType;
    _avatarValue = assetId;
  });
  if (oldPath != null) {
    unawaited(AvatarAssetService.deleteAssistantAvatar(oldPath));
  }
}
```

Pass this method to `AssistantAvatarPresetPicker` and key the Emoji field as `assistant-avatar-emoji-field`. Its `onChanged` must call `_selectAvatarPreset(null)` when the current type is `asset`, otherwise retain the existing `setState(() {})` preview refresh; do not delete a local image merely because text changed while image mode is selected. Update the caption to `图片头像`, `探索向导`, `创作搭档`, or `Emoji 头像` from the current type/id.

Also harden `_pickAvatarImage`: capture `oldPath` only when the current type is `AvatarAssetService.imageType`. Uploading a local image while an asset preset is selected must never pass `starcore_explorer` or `starcore_creator` to `deleteAssistantAvatar`.

Add a narrow save seam to the page without changing the production default:

```dart
typedef AssistantEditSaver = Future<void> Function(AssistantModel assistant);

final AssistantEditSaver? saveAssistant;

const AssistantEditPage({
  super.key,
  this.assistant,
  this.saveAssistant,
});
```

In `_save`, call `widget.saveAssistant` when supplied; otherwise execute the current `HiDBManager`/`AssistantDao.saveAssistant` path verbatim. Both paths still await completion and then `Navigator.pop(context, true)`.

- [ ] **Step 6: Run focused tests and editor analysis**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/assistant_avatar_performance_test.dart test/assistant_avatar_preset_test.dart test/assistant_edit_avatar_preset_test.dart
fvm flutter test --no-pub test/assistant_market_page_test.dart test/assistant_anime_coverage_test.dart
fvm flutter analyze lib/widget/assistant_avatar.dart lib/widget/assistant_avatar_preset_picker.dart lib/pages/assistant_edit_page.dart
```

Expected: tests and focused analysis pass; no file deletion receives a Starcore id.

- [ ] **Step 7: Commit assistant presets**

```bash
git add chatgpt_app_core/lib/util/avatar_asset_service.dart chatgpt_app_core/lib/widget/assistant_avatar.dart chatgpt_app_core/lib/widget/assistant_avatar_preset_picker.dart chatgpt_app_core/lib/pages/assistant_edit_page.dart chatgpt_app_core/test/assistant_avatar_performance_test.dart chatgpt_app_core/test/assistant_avatar_preset_test.dart chatgpt_app_core/test/assistant_edit_avatar_preset_test.dart
git commit -m "feat(ui): add Starcore assistant avatar presets"
```

---

### Task 5: Propagate Starcore avatars through normal conversations and exports

**Files:**
- Create: `chatgpt_app_core/lib/util/assistant_avatar_bytes.dart`
- Create: `chatgpt_app_core/lib/widget/starcore_message_avatar.dart`
- Create: `chatgpt_app_core/test/assistant_avatar_bytes_test.dart`
- Create: `chatgpt_app_core/test/starcore_message_avatar_test.dart`
- Modify: `chatgpt_app_core/lib/chat/application/assistant_conversation_factory.dart:61-80`
- Modify: `chatgpt_app_core/lib/pages/conversation_page.dart:315-342,2438-2452,2558-2572`
- Modify: `chatgpt_app_core/lib/widget/conversation_widget.dart:89-137`
- Modify: `chatgpt_app_core/lib/pages/assistant_list_page.dart:1765-1776`
- Modify: `chatgpt_app_core/test/assistant_test.dart:371-430`
- Modify: `chatgpt_app_core/test/assistant_tools_test.dart`
- Modify: `chatgpt_app_core/test/conversation_widget_theme_test.dart`
- Modify: `chatgpt_app_core/test/project_dao_test.dart`

**Interfaces:**
- Consumes: `MessageAvatarBuilder` from Task 3, `assetType` and Starcore ids from Tasks 1/4.
- Produces: `buildStarcoreMessageAvatar(BuildContext, MessageModel, double)`, `AssistantAvatarBytes.read`, asset propagation in `ConversationModel`, and packaged avatar bytes for character-card export.

- [ ] **Step 1: Write failing factory, conversation-card, and message-builder tests**

Add to `assistant_test.dart`:

```dart
test('Starcore asset avatar is copied into a new conversation', () {
  final assistant = AssistantModel(
    id: 45,
    name: '向导',
    emoji: '🤖',
    avatarType: AvatarAssetService.assetType,
    avatarValue: StarcoreIconAssets.assistantExplorerId,
  );
  final conversation = AssistantConversationFactory.create(
    cid: 125,
    icon: '',
    assistant: assistant,
  );
  expect(conversation.avatarType, AvatarAssetService.assetType);
  expect(
    conversation.avatarValue,
    StarcoreIconAssets.assistantExplorerId,
  );
});
```

Extend `conversation_widget_theme_test.dart` with an anime model using `avatarType='asset'` and assert an `Image` backed by `assistantExplorer`; repump the same model in classic and assert no package `Image` is built. Add a no-avatar/no-icon anime model and assert `_animeFallback` uses the explorer package asset, while classic keeps its current fallback.

Create `starcore_message_avatar_test.dart` with receiver messages for empty avatar, `asset:starcore_creator`, emoji, and sender. Assert anime returns explorer/creator only for the first two, while classic and sender return null.

Create `assistant_avatar_bytes_test.dart` with a `TestAssetBundle` that returns known bytes for `packages/chatgpt_app_core/assets/icons/starcore/assistant-explorer.png`. Assert `AssistantAvatarBytes.read` returns those bytes for an asset assistant, reads a temporary file for image type, and returns null for an unknown asset id. Add stable-id DAO round-trips to `assistant_tools_test.dart` and `project_dao_test.dart` so neither assistant nor conversation storage tries to relocate `starcore_explorer` as a file.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/assistant_test.dart --plain-name "Starcore asset avatar is copied into a new conversation"
fvm flutter test --no-pub test/conversation_widget_theme_test.dart test/starcore_message_avatar_test.dart test/assistant_avatar_bytes_test.dart test/assistant_tools_test.dart test/project_dao_test.dart
```

Expected: factory falls back to emoji, conversation card has no asset renderer, and the message builder file is missing.

- [ ] **Step 3: Propagate `asset` through assistant-to-conversation mapping**

Update `_avatarTypeOf` and `_avatarValueOf`:

```dart
if (assistant.avatarType == AvatarAssetService.assetType &&
    StarcoreIconAssets.assistantAssetFor(assistant.avatarValue) != null) {
  return AvatarAssetService.assetType;
}
```

Return `assistant.avatarValue!.trim()` for both valid image and asset types. Mirror the same valid-asset branch in `ConversationPage._conversationAvatarForAssistant`.

- [ ] **Step 4: Implement the anime-aware message callback**

Create `starcore_message_avatar.dart`:

```dart
Widget? buildStarcoreMessageAvatar(
  BuildContext context,
  MessageModel message,
  double avatarSize,
) {
  if (!AppVisualTheme.of(context).isAnime ||
      message.ownerType != OwnerType.receiver) {
    return null;
  }
  final raw = message.avatar?.trim() ?? '';
  final id = raw.isEmpty
      ? StarcoreIconAssets.assistantExplorerId
      : StarcoreIconAssets.parseMessageAvatar(raw);
  final asset = StarcoreIconAssets.assistantAssetFor(id);
  if (asset == null) return null;
  return ClipOval(
    key: ValueKey('starcore-message-avatar-$id'),
    child: Image.asset(
      asset,
      package: StarcoreIconAssets.packageName,
      width: avatarSize,
      height: avatarSize,
      cacheWidth: (avatarSize * MediaQuery.devicePixelRatioOf(context)).round(),
      cacheHeight: (avatarSize * MediaQuery.devicePixelRatioOf(context)).round(),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => CircleAvatar(
        radius: avatarSize / 2,
        child: const Icon(Icons.smart_toy_rounded),
      ),
    ),
  );
}
```

Pass `avatarBuilder: buildStarcoreMessageAvatar` to `ChatList` in `ConversationPage._chatList`. In `_assistantAvatarForMessage`, return `StarcoreIconAssets.messageAvatarFor(value)` for a valid asset before the image/emoji branches.

- [ ] **Step 5: Render asset ids in anime conversation cards**

In `ConversationWidget._animeIcon`, insert an asset branch before `_hasValidIcon`:

```dart
if (avatarType == AvatarAssetService.assetType) {
  final asset = StarcoreIconAssets.assistantAssetFor(avatarValue);
  if (asset != null) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.asset(
        asset,
        package: StarcoreIconAssets.packageName,
        height: 50,
        width: 50,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _animeFallback(context),
      ),
    );
  }
}
```

Replace `_animeFallback`'s direct `smart_toy` child with the explorer asset and retain `smart_toy` in its `errorBuilder`. Do not add an asset branch to the classic `_icon` getter.

- [ ] **Step 6: Include packaged presets in assistant-card export**

Create `assistant_avatar_bytes.dart` so the bundle boundary is directly testable:

```dart
import 'dart:io';

import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter/services.dart';

abstract final class AssistantAvatarBytes {
  static Future<List<int>?> read(
    AssistantModel assistant, {
    AssetBundle? bundle,
  }) async {
    final type = assistant.avatarType;
    final value = assistant.avatarValue?.trim() ?? '';
    if (type == AvatarAssetService.assetType) {
      final asset = StarcoreIconAssets.assistantAssetFor(value);
      if (asset == null) return null;
      final data = await (bundle ?? rootBundle).load(
        'packages/${StarcoreIconAssets.packageName}/$asset',
      );
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    if (type != AvatarAssetService.imageType || value.isEmpty) return null;
    final file = File(value);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }
}
```

Replace the private body of `_readAssistantAvatarBytes` with `return AssistantAvatarBytes.read(assistant);`. This keeps PNG/CHARX export behavior in one unit-tested helper.

- [ ] **Step 7: Run normal-conversation and export regressions**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/assistant_test.dart test/assistant_tools_test.dart test/project_dao_test.dart test/conversation_widget_theme_test.dart test/starcore_message_avatar_test.dart test/assistant_avatar_bytes_test.dart test/assistant_role_card_service_test.dart
cd ../chat_message
fvm spawn 3.35.7 test --no-pub test/message_avatar_builder_test.dart test/chat_message_test.dart test/chat_list_test.dart
```

Expected: all tests pass; Story room tests are unchanged because this slice does not alter its persona model.

- [ ] **Step 8: Commit conversation propagation**

```bash
git add chatgpt_app_core/lib/chat/application/assistant_conversation_factory.dart chatgpt_app_core/lib/pages/conversation_page.dart chatgpt_app_core/lib/widget/conversation_widget.dart chatgpt_app_core/lib/pages/assistant_list_page.dart chatgpt_app_core/lib/widget/starcore_message_avatar.dart chatgpt_app_core/lib/util/assistant_avatar_bytes.dart chatgpt_app_core/test/assistant_test.dart chatgpt_app_core/test/assistant_tools_test.dart chatgpt_app_core/test/project_dao_test.dart chatgpt_app_core/test/conversation_widget_theme_test.dart chatgpt_app_core/test/starcore_message_avatar_test.dart chatgpt_app_core/test/assistant_avatar_bytes_test.dart
git commit -m "feat(ui): propagate Starcore conversation avatars"
```

---

### Task 6: Add anime-only web and knowledge tool glyphs

**Files:**
- Create: `chatgpt_app_core/lib/widget/starcore_tool_icon.dart`
- Create: `chatgpt_app_core/test/starcore_tool_icon_test.dart`
- Modify: `chatgpt_app_core/lib/pages/assistant_edit_page.dart:893-918`
- Modify: `chatgpt_app_core/lib/chat/ui/block_message_content.dart:884-971`
- Modify: `chatgpt_app_core/test/block_message_content_test.dart:120-160`

**Interfaces:**
- Consumes: `ToolRegistry.webSearchId`, `ToolRegistry.knowledgeSearchId`, `StarcoreSvgIcon`, and `AppVisualTheme`.
- Produces: `StarcoreToolIcon(toolName, fallback, size)`; selection rows pass descriptor id, message cards pass `block.toolName`.

- [ ] **Step 1: Write failing mapping and ToolBlock-state tests**

Create `starcore_tool_icon_test.dart` and pump anime/classic widgets for `web_search`, `knowledge_search`, and `calculator`. Assert anime approved ids build the correct stable SVG keys while classic/unknown build only the supplied Material fallback. In the assistant tool-row test, assert `CheckboxListTile.controlAffinity` remains `leading`, `secondary` remains null, and the mapped SVG precedes the text inside the title row.

Add ToolBlock cases to `block_message_content_test.dart`:

```dart
ToolBlock(
  id: 'b_tool_web',
  messageId: messageKey,
  createdAt: 1,
  status: MessageBlockStatus.success,
  toolId: 'call_1',
  toolName: ToolRegistry.webSearchId,
  arguments: const {'query': '测试'},
)
```

Assert `starcore-svg-tool-web-search` appears for success, `CircularProgressIndicator` appears for processing, and `Icons.build_outlined` appears for error and unknown `toolName`. Keep the existing 44dp semantics assertion.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/starcore_tool_icon_test.dart test/block_message_content_test.dart
```

Expected: the new widget is missing and ToolBlock still always shows `Icons.build_outlined`.

- [ ] **Step 3: Implement the UI-layer tool mapper**

Create `starcore_tool_icon.dart`:

```dart
class StarcoreToolIcon extends StatelessWidget {
  final String toolName;
  final Widget fallback;
  final double size;

  const StarcoreToolIcon({
    super.key,
    required this.toolName,
    required this.fallback,
    this.size = 18,
  });

  String? get _asset => switch (toolName) {
        ToolRegistry.webSearchId => StarcoreIconAssets.toolWebSearch,
        ToolRegistry.knowledgeSearchId =>
          StarcoreIconAssets.toolKnowledgeSearch,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final asset = _asset;
    if (!AppVisualTheme.of(context).isAnime || asset == null) return fallback;
    return StarcoreSvgIcon(
      assetName: asset,
      fallback: fallback,
      size: size,
    );
  }
}
```

- [ ] **Step 4: Wire selection rows and successful ToolBlocks**

In `_buildToolTile`, keep `controlAffinity: ListTileControlAffinity.leading` so the checkbox remains the interaction control. For anime and the two approved ids only, place `StarcoreToolIcon(toolName: d.id, ...)` at the start of the existing `title: Row`, followed by an 8px gap and a `Flexible` label; the side-effect warning remains after the label. Do not use `secondary`, move the checkbox, or add empty spacing in classic/unknown rows.

In `_ToolState`, preserve the spinner branch. When not running, use `StarcoreToolIcon(toolName: block.toolName ?? '', ...)` only for `MessageBlockStatus.success`; use the existing `Icon(Icons.build_outlined, ...)` directly for error, paused, pending, and unknown names. Do not use `block.toolId` for mapping.

- [ ] **Step 5: Run focused tests and semantics regression**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/starcore_tool_icon_test.dart test/block_message_content_test.dart
```

Expected: all tests pass and the existing tool row remains at least 44dp high with one semantics label.

- [ ] **Step 6: Commit tool glyphs**

```bash
git add chatgpt_app_core/lib/widget/starcore_tool_icon.dart chatgpt_app_core/lib/pages/assistant_edit_page.dart chatgpt_app_core/lib/chat/ui/block_message_content.dart chatgpt_app_core/test/starcore_tool_icon_test.dart chatgpt_app_core/test/block_message_content_test.dart
git commit -m "feat(ui): add Starcore anime tool icons"
```

---

### Task 7: Run shared-core integration verification

**Files:**
- Verify: every Dart, asset, pubspec, lock, and test file changed in Tasks 1-6; this task introduces no new production behavior
- Do not modify: `login_sdk/test/support/`

**Interfaces:**
- Consumes: every runtime UI deliverable from Tasks 1-6.
- Produces: verified package locks, formatted Dart, passing focused/full suites, and a handoff that separates runtime UI completion from the launcher plan.

- [ ] **Step 1: Format only touched Dart files**

Run `dart format` with the exact files from Tasks 1-6; do not format unrelated packages or the whole repository.

- [ ] **Step 2: Run the existing Starcore master validator**

Run:

```bash
python3 docs/design-assets/starcore-guide/test_validate_assets.py
python3 docs/design-assets/starcore-guide/validate_assets.py
for f in chatgpt_app_core/assets/icons/starcore/*.svg; do xmllint --noout "$f"; done
```

Expected: 12 validator tests pass, the asset contract reports `starcore assets: OK`, and all six runtime SVGs are valid XML.

- [ ] **Step 3: Run focused runtime suites**

Run:

```bash
cd chat_message
fvm spawn 3.35.7 test --no-pub test/message_avatar_builder_test.dart test/chat_message_test.dart test/chat_list_test.dart
fvm spawn 3.35.7 analyze
cd ../chatgpt_app_core
fvm flutter test --no-pub test/starcore_runtime_icons_test.dart test/app_bottom_navigation_bar_test.dart test/assistant_avatar_performance_test.dart test/assistant_avatar_preset_test.dart test/assistant_edit_avatar_preset_test.dart test/assistant_market_page_test.dart test/assistant_anime_coverage_test.dart test/assistant_test.dart test/assistant_tools_test.dart test/project_dao_test.dart test/conversation_widget_theme_test.dart test/starcore_message_avatar_test.dart test/assistant_avatar_bytes_test.dart test/starcore_tool_icon_test.dart test/block_message_content_test.dart
```

Expected: all tests pass.

- [ ] **Step 4: Run full shared-package validation**

Run:

```bash
cd chatgpt_app_core
fvm flutter analyze
fvm flutter test --no-pub
```

Expected: analyzer exits 0 and the full core suite passes. If an unrelated pre-existing failure appears, record its exact test and error without weakening any Starcore assertion.

- [ ] **Step 5: Verify path-package bundling in the primary shell**

Run:

```bash
cd chatgpt_flutter
fvm flutter pub get
fvm flutter build apk --debug
unzip -Z1 build/app/outputs/flutter-apk/app-debug.apk | rg '^assets/flutter_assets/packages/chatgpt_app_core/assets/icons/starcore/'
```

Expected: the debug APK builds and the archive listing reports all eight `assets/flutter_assets/packages/chatgpt_app_core/assets/icons/starcore/` entries. Do not claim HarmonyOS launcher verification here; that belongs to the separate platform plan.

- [ ] **Step 6: Inspect the final runtime diff**

Run:

```bash
git diff --check
git status --short
git log --oneline -7
```

Expected: only planned runtime files plus the user's pre-existing `?? login_sdk/test/support/` appear; Tasks 1-6 each have a narrow commit.

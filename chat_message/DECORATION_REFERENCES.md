# 聊天装扮参考与实现记录

2026-10-21 查阅以下开源项目的公开 README、许可证与气泡绘制实现。新增样式在本仓库使用 Flutter `ShapeBorder` / `CustomPainter` 重新绘制，保留原有消息内容组件、选择复制、流式更新和操作入口。

| 参考项目 | 查阅版本 | 许可证 | 采用的视觉特征与本地样式 |
| --- | --- | --- | --- |
| [prahack/chat_bubbles](https://github.com/prahack/chat_bubbles/tree/790e5ebca1b6463b554d0ad875a299787ac124b3) | `790e5ebca1b6463b554d0ad875a299787ac124b3` | [MIT](https://github.com/prahack/chat_bubbles/blob/790e5ebca1b6463b554d0ad875a299787ac124b3/LICENSE), Prabhanu Gunaweera | `BubbleSpecialThree` 的圆润弧尾和 `BubbleSpecialOne` 的轻巧尖尾，分别对应“弧尾”“轻聊” |
| [apgapg/avatar_glow](https://github.com/apgapg/avatar_glow/tree/1f9f4bcf17fcb68ce237aa6d10c6c75e90d94a85) | `1f9f4bcf17fcb68ce237aa6d10c6c75e90d94a85` | [MIT](https://github.com/apgapg/avatar_glow/blob/1f9f4bcf17fcb68ce237aa6d10c6c75e90d94a85/LICENSE), Ayush P Gupta | 头像外侧的柔和环形光晕，对应“晨光” |
| [ajilo297/Flutter-Dotted-Border](https://github.com/ajilo297/Flutter-Dotted-Border/tree/8446e07daa732143fdfcfdb07cb460ed7782f842) | `8446e07daa732143fdfcfdb07cb460ed7782f842` | [MIT](https://github.com/ajilo297/Flutter-Dotted-Border/blob/8446e07daa732143fdfcfdb07cb460ed7782f842/LICENSE), Ajil Oommen；上游同时保留 path_drawing 的 MIT 声明 | 圆形轮廓与虚实相间的描边，对应“星点”，加入本地渐变配色 |

这里只复刻上述视觉特征，路径坐标、配色和布局按艾普的正文与头像尺寸重新设计；没有复制上游源文件、图片、图标或示例业务逻辑，也没有新增包依赖。晨光使用静态光晕，不包含上游的循环扩散动画，避免每条历史消息长期运行动画。许可证与来源保留在本记录，方便后续追溯。

## 使用与兼容

- 入口：我的 → 外观与主题 → 聊天装扮。
- 当前共 12 款气泡、12 种头像框（包含经典气泡和原生头像）。我的消息与 AI 回复可分别选择，自动保存在当前设备。
- 自定义气泡颜色优先，预设同时支持明暗主题。新款式追加稳定的配置名字，旧用户保持原选择，未知名字回退经典 / 原生。
- 尾角在气泡内部预留空间，隐藏头像时一并隐藏尾角；长回复、图片、代码块和消息按钮继续由原组件负责。
- 头像框在原头像尺寸内绘制，不扩大消息行；晨光的模糊绘制限制在框内，星点不需要计时器。

## 验证

定向检查包括尾角边界与镜像、消息流式更新及操作、所有款式的长文本布局与颜色对比度、配置保存与恢复、设置入口和小屏 / 横屏 / 大文字 / 明暗模式。构建与设备验收分开记录：本地构建通过不代表已经安装到真机。

2026-10-21 开源参考批次的本地验收结果（当时 8 + 8 款，Flutter 3.35.7）：

- `chat_message`：`flutter test --no-pub`，28 项通过。
- `chatgpt_app_core`：`chat_decoration_test`、`chat_appearance_test`、`theme_provider_test`、`appearance_settings_page_test`、`starcore_message_avatar_test`，25 项通过。
- 6 个变更源码 / 测试文件定向静态分析：无诊断；尾角实现与全部 8 款气泡、8 种头像框均参与验证。
- Android debug APK 与 Web release 构建通过；Web 构建仍有原有的 CupertinoIcons 字体提示。
- 真实 Flutter 组件已导出浅色、深色和宽屏预览检查；没有用预览截图代替真机验收，本轮未安装真机。


## QQ 装扮方向的原创套装

2026-10-21 参考[腾讯 ISUX 介绍 QQ 个性装扮的公开文章](https://cloud.tencent.com/developer/article/1838237)及其中的商城效果图，提取“成套主题、装饰外圈、边缘角标、宝石与花簇”的视觉形式。QQ 的图片仅供观察，新增套装的几何、配色和装饰均在 `chat_ornaments.dart` 中独立绘制。

- **星河**：星月角标与星座连线气泡，配流翼、星星、宝石头像框。
- **樱花**：粉色渐层与花瓣边角气泡，配花簇、叶片环绕的花冠头像框。
- **甜心**：奶油色气泡与蝴蝶结、爱心、丝带，配心形宝石头像框。
- **机甲**：深色棱角气泡与青色能量线，配六角徽章和侧翼头像框。

新款优先展示，原有款式与配置继续保留。气泡装饰只使用顶部 26、底部 22 像素的预留区域，头像装饰限制在原布局尺寸内；全部使用静态矢量绘制，适合长聊天列表和减弱动画模式。

QQ 装扮方向批次验收（2026-10-21，当前 12 + 12 款）：消息组件 29 项、核心外观与设置 25 项测试通过；新增逐像素检查，确认装饰不进入气泡正文且头像框不越界。6 个源码 / 测试文件定向静态分析无诊断；Android debug APK 与 Web release 构建通过，浅色、深色主题和正式设置页均以真实 Flutter 组件导出预览。Web 构建仍有原有的 CupertinoIcons 字体提示，本轮未进行真机安装验收。

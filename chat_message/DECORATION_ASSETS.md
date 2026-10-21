# 插画装扮素材

2026-10-21 按用户确认的六组原创概念图，通过 imagegen 分别生成透明头像框和透明气泡边框。素材不含用户头像或消息文字，不包含 QQ 的商标、角色或原图。

生成 PNG 以 `cwebp -lossless -z 6` 转为 WebP，保留像素和 alpha。十二张素材共 11,773,008 字节，随 `chat_message` Flutter 包离线分发；不依赖网络下载或新的第三方组件。

头像框为 1254×1254；使用时按实际尺寸和设备像素比解码，最高 512×512。气泡为 1774×887，按 64 逻辑像素的设计高度加载，通过九宫格固定角部并伸缩连续边缘；不会拉伸整张图片或将正文画进素材。

气泡的九宫格源矩形为 `(444,426)-(1330,461)` 像素。Flutter 的 `centerSlice` 使用除以图片 `scale` 后的逻辑坐标；`scale=887/64`。气泡底色独立响应明暗主题和自定义颜色。

头像原图位于透明框后。2026-10-22 根据真机反馈，消息头像保持原有大小，布局为外框预留额外空间；装扮样卡仍按固定外框大小显示。气泡正文预留左/右 28、上/下 34 逻辑像素，并裁掉素材进入正文的零星像素。图片加载失败时保留头像或正文，并回退到静态矢量装饰。

新增十套动态头像框及配套气泡见 [ANIMATED_DECORATION.md](ANIMATED_DECORATION.md)。

| 套装 | 文件 | 字节 | SHA-256 |
| --- | --- | ---: | --- |
| 像素冒险 | `adventure_bubble.webp` | 535818 | `93267e7419dae8d82e61552d5b2a8a233c91ae79afc317ad150f89c56ae36a32` |
| 像素冒险 | `adventure_frame.webp` | 1040816 | `f0674253e2a2f24217e4aa67c597b716b9e46f6dfb3654dceed2e3051c9d72f4` |
| 黄铜航行 | `brass_bubble.webp` | 759302 | `a1b91aa725e9247d45a07e955fc9995870b79056d09d67541496abeeac5ca8b3` |
| 黄铜航行 | `brass_frame.webp` | 1336864 | `0e07db7f1276ce5ecb64da3bcc6736a7f3b4d557d4253bc94ce7ab74941a404d` |
| 海盐水晶 | `crystal_bubble.webp` | 779732 | `3f906d9fc9c8dee960005dc174019d4f087c700de6f17e4872e4f3ad720e80f1` |
| 海盐水晶 | `crystal_frame.webp` | 1324068 | `b70c880bb9356f2f1d3607744e80eb9022b897aca3c45a684ff0469a2b782749` |
| 墨染山河 | `ink_bubble.webp` | 677978 | `d27fb66f019754111f6dc37a7b8c48c07dbe1b0af6f4c7abebd35d09e2b70d21` |
| 墨染山河 | `ink_frame.webp` | 1208106 | `f53d4413b0bdab7c438a7fe4a3facd5ae54c259628dee8f71805c198040a7caf` |
| 霓虹信号 | `neon_bubble.webp` | 502506 | `95a4a88a2f0b2a5fd2ae493e212a8a50e5d5d6ba8aa1ca2a651f39d15d7d8748` |
| 霓虹信号 | `neon_frame.webp` | 1340942 | `273369899b99d34ceed2f7abeea243193fb1215e4d728b859fa0df8cfb2ed4aa` |
| 绒绒伙伴 | `plush_bubble.webp` | 913172 | `070ae312b8757deabfcf88d1ca13fec4bdfb09ab103cbba18611b891c770a0f4` |
| 绒绒伙伴 | `plush_frame.webp` | 1353704 | `a9779f279e4744a00cb6b9af88d61232cc3c15d147793e10f86ddccff104f0ca` |

# login_sdk_example

`login_sdk` 的可独立运行 demo。提供：

- **launcher 页**：背景下拉（20 个 `LoginBgVariant`）+ 6 个入口（Login / Register / Forgot × tabs / bg）
- **进程内 mock backend**（监听 `127.0.0.1:3000`）：所有 POST 都返回 `{code:0, data, extra}` 让登录流程能跑完。

无须启动 `chatgpt_backend`、Postgres，或部署任何东西。

## 运行

```bash
cd login_sdk/example
flutter pub get
flutter run
```

默认会启动桌面 / 模拟器；指定设备：`flutter run -d <device_id>`。

`flutter devices` 看可用设备。

## 文件

```
example/
├── lib/
│   ├── main.dart          # 启动 mock backend、注入 BackendConfig.host、跑 ExampleApp
│   ├── launcher_page.dart # bg picker + 6 入口
│   └── mock_backend.dart  # HttpServer 实现的 canned-response mock
└── pubspec.yaml           # 依赖 login_sdk via `path: ../`
```

## 用法

1. 启动后进入 launcher
2. 顶部下拉切换背景（仅 `bg` 样式生效；`tabs` 样式是白底，与背景无关）
3. 点 6 个 tile 之一进入对应页面
4. 在登录 / 注册 / 忘记密码页随便填，提交 — mock backend 永远返回成功，看到的就是真实跳转 / 状态切换
5. 返回 launcher 继续切其他组合

## 怎么改成对接非 imooc 后端

把 `main.dart` 里的初始化换成显式 `LoginSdkConfig.install(...)`，参见 `../REFACTOR_GENERIC_SDK.md`。

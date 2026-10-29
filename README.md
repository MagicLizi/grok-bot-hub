# Grok Bot Hub

一个 macOS 管家应用：在一台 Mac 上同时运行多个 [Grok Bot](https://x.ai/bot) 桌面实例，每个实例登录不同的账号；由管家负责新建、登录和保活。

## 功能

- **多开**：每个 Bot 是一个独立的 Grok Bot 进程，有自己的数据目录。账号、缓存、单实例锁互不干扰。
- **新建 + 登录**：点「新建 Bot」后，管家会启动实例、替你点「登录」、取到登录链接，按设置里的「登录方式」打开：
  - **全新会话**（默认）：系统安全登录窗口（`ASWebAuthenticationSession`，与 Safari 同内核，Google 官方认可），不带任何已有 cookie，适合给每个 Bot 登不同的个人账号。打不开时自动改用内置浏览器窗口。
  - **默认浏览器**：和 Grok Bot 自带的登录完全一样，沿用浏览器里已有的登录状态。**公司单点登录账号**（如 `@example.com` 的 Google Workspace 账号）在全新会话里可能被公司策略拒绝（Google 报 `403 app_not_enabled_for_user`），用这个方式。给不同 Bot 登不同账号时，需要先在网页上切换账号。

  登录提示窗口里可以一键切换两种方式，切换后会记住。主窗口被关掉的实例会先自动重新打开窗口再登录。直接在 Grok Bot 里完成的登录，管家几秒内也会显示出来。
- **保活**
  - **一键暂停 / 开启全部保活**：主窗口工具栏和菜单栏都有「暂停保活」。暂停时 Bot 继续运行，取消正在执行和排队的自动恢复、前台轮换，暂停健康与登录巡检、自动拉起和卡死重启，并释放本机防休眠；手动显示窗口、登录、启动、重启和唤醒仍可使用。各 Bot 原来的保活开关及设置会保留，点「开启保活」后恢复，原本关闭保活的 Bot 保持关闭。暂停状态在重开管家后仍然保留。
  - 进程退出或崩溃：当场发现，按 2s → 5s → 10s → 30s → 1min → 2min → 5min 的间隔退避重启；稳定运行 10 分钟后退避计数清零。
  - 卡死：每 30 秒做一次健康检查，连续 4 次无响应（约 2 分钟）就强制结束并重新拉起。
  - 掉线：已登录的 Bot 每 3 分钟确认一次登录状态（未登录时每 15 秒、登录中每 3 秒），账号被退出时发系统通知，在管家里点「登录」即可重新登录。
  - 有 Bot 运行时默认保持显示器常亮：macOS 的锁屏由显示器关闭或屏保触发，显示器不因闲置关闭，Mac 就不会自动锁屏，点「唤醒」时不会被锁屏挡住。可在设置里改成只阻止系统休眠（显示器照常关闭，之后可能锁屏）。可选阻止 Grok Bot 进入 App Nap。
  - 管家重启后会自动接管仍在运行的实例；可设置登录 macOS 时自动打开管家。
  - **电脑自动检查与恢复**（默认开启）：已登录、开启保活的 Bot 每 30 秒检查电脑状态；休眠时唤醒，连接失败时重试，屏幕暂停时重新激活窗口。新加入并登录的 Bot 自动纳入。停止、删除、重启、退出登录或关闭保活时，会取消该 Bot 的旧操作；关闭设置里的「自动保持所有 Bot 的电脑运行」会立即取消所有自动操作。
    - 每台云端电脑每 3 分钟轮换前台一次，打开「电脑」页并确认窗口在前台停留 3 秒后，切回原来的程序；期间用户主动切换程序时保留用户选择，未成功到达前台会重试。前台操作串行，电脑检查和恢复并行，一台启动缓慢不会拖住其他 Bot。运行在此设备上的电脑无需轮换。
    - 优先通过对应实例自己的窗口接口显示和恢复窗口，已有电脑画面时直接聚焦；需要导航时，直接点击这个实例里的「电脑」页签。窗口重开和前台切回按进程 PID 发送系统事件，不再启动临时 Bot。连续停留 3 秒才算轮换完成。窗口已显示但前台被切走时，提示「轮换被打断」并在 30 秒后重试，不计为恢复失败；若最近检查仍确认电脑可用，保留实际运行状态。
    - 恢复失败按 30 秒 → 1 分钟 → 2 分钟 → 5 分钟退避，期间仍每 30 秒检查状态。详情页显示最近检查、最近前台轮换、失败原因、下次重试和自动恢复次数。只有 90 秒内确认可用且没有待处理问题的电脑才显示「电脑运行中」和计入已确认数量。
    - Mac 锁屏时等待解锁，账号退出时提示重新登录，服务端重建或暂停时继续检查并等待恢复。网络和服务端可能造成中断；自动检查与恢复不能保证云端电脑从不休眠。
- **手动唤醒电脑**：每个 Bot 的详情页和菜单栏里有「唤醒电脑」，工具栏和菜单栏有「全部唤醒」。与自动恢复共用同一流程：
  - 把这个 Bot 的 Grok Bot 窗口带到前台，在对应实例里打开「电脑」页。「全部唤醒」并行准备各 Bot，依次激活窗口，各 Bot 独立恢复。
  - 然后最多 120 秒内按电脑当前的样子做你会做的那一步，每种操作最多两次：电脑正在休眠 → 点「唤醒电脑」；无法连接屏幕 → 点「重试」；「你离开期间屏幕已暂停」→ 再把窗口带到前台；认不出的全屏画面 → 点「退出全屏」回到电脑页。正在唤醒 / 设置 / 启动桌面 / 切换屏幕时等着；电脑正在重建或已暂时暂停时只能等 Grok Bot 自己恢复，直接提示。
  - 小预览卡片和全屏画面都认，文案按 Grok Bot 0.75 的简体、繁体、英文界面识别。Mac 锁屏时 Grok Bot 认为没人在电脑前、不会唤醒，管家会直接提示先解锁。
- **菜单栏**：显示运行数量，可以快速显示、重启、启停、唤醒各个 Bot。关掉主窗口后管家仍在菜单栏里继续保活。
- 每个 Grok Bot 窗口的标题会加上 Bot 名字（如「Grok Bot — 工作号」），方便在调度中心里区分。

## 构建与安装

要求：macOS 14 及以上，Swift 6 工具链（只装 Command Line Tools 也可以），本机已安装 Grok Bot。

```bash
scripts/build.sh              # 生成 build/Grok Bot Hub.app（release，ad-hoc 签名）
scripts/build.sh --install    # 同时复制到 /Applications
swift test                    # 运行单元测试
swift scripts/test-computer-state.swift  # 检查电脑界面识别和操作范围
```

应用只做了 ad-hoc 签名，换一台 Mac 使用时，第一次需要右键 →「打开」。

## 使用

1. 打开 Grok Bot Hub，点工具栏的 **＋ 新建 Bot**，起个名字，保持勾选「创建后立即登录」。
2. 弹出「为 XX 登录 Grok Bot 账号」提示窗口后：
   - 全新会话：在安全登录窗口里点「使用 Google 登录」，登录这个 Bot 要用的账号并确认（每次都要重新输入账号，可用钥匙串自动填充）。系统浏览器也会弹出同一个页面，直接关掉即可。
   - 默认浏览器：在浏览器里打开的登录页上完成登录并确认。

   两种方式下提示窗口都要保持打开，关掉它等于取消这次登录。
3. 登录成功后，管家会把这个 Bot 的 Grok Bot 窗口带到前台，剩下的初始设置在 Grok Bot 里完成。
4. 重复以上步骤添加更多 Bot。右侧详情页的「保活」开关默认开启。

「停止」会同时关闭保活，「启动」会重新开启保活。删除 Bot 时会先退出它的账号、结束进程，再把它的数据目录移到废纸篓；云端的 Bot 和任务不受影响。

需要操作 Bot、不希望被自动切换窗口时，点工具栏的「暂停保活」；完成后点「开启保活」。这与「全部停止」不同，暂停不会关闭正在运行的 Bot。

## 工作原理

| 环节 | 做法 |
| --- | --- |
| 隔离 | 启动实例时传入 `SAND_USER_DATA_DIR=<目录>` 和 `SAND_DATA_ROOT=<目录>/sand-data`，分别隔离 Electron 会话与账号业务数据；保留 `--user-data-dir=<目录>` 参数用于旧版兼容和进程识别。Grok Bot 0.78.1 会覆盖 Chromium 的目录参数，仅传参数已无法隔离 |
| 启动方式 | 通过 LaunchServices（`NSWorkspace`）新开实例，而不是直接起子进程，这样麦克风、录屏、辅助功能等权限仍然记在 Grok Bot 名下 |
| 接管 | 同时传 `--remote-debugging-port=0`，Chromium 会随机选一个只监听 127.0.0.1 的端口，写进 `<目录>/DevToolsActivePort`。管家连接前先用 `SystemInfo.getProcessInfo` 核对端口背后的进程 PID |
| 登录 | 调用 Grok Bot 界面自己用的 `window.desktop.main.loginCursor()` / `copyCursorLoginLink()`，拿到 `cursor.com/loginDeepControl` 链接后，在临时会话的 `ASWebAuthenticationSession` 里打开（备用：每个 Bot 一个 `WKWebsiteDataStore` 的内置浏览器）。token 由 Grok Bot 用自己私有的 verifier 轮询 `api2.cursor.sh/auth/poll` 领取，不依赖 `grokbot://` 回调，因此多开时不会串号；登录页跳转的 `grokbot://` 回调会被截下丢弃 |
| 识别进程 | 每 2 秒扫描 bundle id 为 `com.anysphere.sand` 的进程，用 `sysctl(KERN_PROCARGS2)` 读启动参数，按 `--user-data-dir` 对应到 Bot |

## 数据位置

- Bot 列表：`~/Library/Application Support/GrokBotHub/profiles.json`
- 每个 Bot 的 Grok Bot 数据：`~/Library/Application Support/GrokBotHub/Profiles/<id>/`
- 日志：`~/Library/Logs/GrokBotHub/hub.log`

账号、Cookie 和登录状态保存在上述本机数据目录，不随源代码分发。`.gitignore` 排除了 Bot 数据、凭证、日志、截图目录和构建产物。分享问题时，请先检查日志和截图中的邮箱、登录链接、聊天内容及个人路径，并遮盖这些信息。

## 已知限制

- **调试端口**：只监听 127.0.0.1，但本机上以你的账号运行的其他程序理论上也能连接并操控 Bot。这是选择全自动登录和状态检测的代价。
- **依赖 Grok Bot 内部接口**：登录自动化和登录状态检测用的是 Grok Bot 0.75.8 渲染进程里的 `window.desktop.main.*`。如果 Grok Bot 改版后这些接口变了，这两项会失效，多开和进程保活不受影响。
- **0.78.1 目录兼容**：已适配新版的隔离环境变量。安装修复版后需重启管家管理的旧实例，才能使用正确的独立目录；不自动复制默认目录的登录数据，避免把同一账号复制给多个 Bot。
- **自动更新**：某个实例安装更新并重启时，Grok Bot 的更新器可能额外拉起一个不带参数的默认实例。管家会照常把自己管理的实例拉起；默认实例会在侧栏底部显示为「非管家实例」，可以手动关掉。
- **退出管家后保活暂停**：Bot 会继续运行，但不再被自动拉起，下次打开管家时会重新接管。

## 开发

```
Sources/HubCore/      纯逻辑（参数解析、退避策略、登录状态与链接校验），有单元测试
Sources/GrokBotHub/
  Runtime/            进程扫描与启动、CDP 客户端、Grok Bot 桥接、每个 Bot 的状态机、总调度
  Login/              隔离登录窗口（WKWebView）
  UI/                 SwiftUI 界面、菜单栏、设置
scripts/              打包脚本与图标生成
```

macOS 27 SDK 里 `@State` 改成了宏，它的实现只随完整 Xcode 提供。为了只装 Command Line Tools 也能编译，界面里统一使用等价的 `@ViewState`（见 `UI/ViewState.swift`）。

仅安装 Command Line Tools 时，若 `swift test` 提示找不到 `TestingMacros`，可显式加载随工具链附带的测试宏：

```bash
swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Debug 构建提供两个自测入口（release 构建中不存在）：

```bash
scripts/build.sh debug
open --env GROKBOTHUB_SELFTEST_NEW_BOT=测试 "build/Grok Bot Hub.app"        # 启动后直接新建（或对同名 Bot 重新）登录
open --env GROKBOTHUB_SELFTEST_SNAPSHOT=20 "build/Grok Bot Hub.app"         # 20 秒后把窗口内容存到日志目录
```

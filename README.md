# 诡秘神谕移动展示终端 · LokiMetrisDisplay

**数据采集端：[LokiMetris · 诡秘神谕](https://github.com/ManonLoki/LokiMetis)** —— 电脑负责采集用量与活动，移动端负责展示。

在 Android、iPhone、iPad、Apple Watch 和小组件上，查看电脑上的 AI 编程工具用量、账户额度与运行状态。两端通过局域网连接，首次使用四位码配对，之后自动重连。

中文系统里的应用名为“诡秘神谕”，其他语言显示为“LokiMetris”。

[下载 Android APK](https://github.com/ManonLoki/LokiMetisMobileDisplay/releases/latest) · [主要界面](#主要-ui-展示) · [使用说明](#详细使用说明) · [版本更新](https://github.com/ManonLoki/LokiMetisMobileDisplay/releases) · [从源码运行](#从源码运行)

> **Desktop 实验展示终端**：`codex/desktop-experimental` 分支新增 `desktopApp`，在电脑窗口中使用与 Android 平板共用的展示台和设置。它从 LokiMetris 采集端接收数据，本身不采集本机 AI 用量。该分支与 `main` 独立开发、禁止互相合并；当前发布仍为 **v1.0.7**，本次没有发布新版本。运行与验证范围见 [Desktop 实验说明](docs/11-Desktop实验展示终端.md)。

## 主要 UI 展示

以下界面使用隔离演示数据，Token、账户额度、状态正文与图片均用于展示效果。实际内容以电脑同步为准。

### 手机展示台与图文详情

| Android：详细用量与四张 Hooks | iPhone：用量、额度与活动 | iPhone：正文与图片详情 |
| --- | --- | --- |
| <img src="docs/images/v1.0.6/android-panel.png" width="260" alt="Android 展示台：演示用量、四种状态与 PNG/GIF 图片"> | <img src="docs/images/v1.0.6/iphone-panel.png" width="260" alt="iPhone 展示台与 Mock 图片"> | <img src="docs/images/v1.0.6/iphone-hook-detail.png" width="260" alt="iPhone Hooks 详情中的演示正文与 GIF"> |

卡片可同时显示用量、账户周期和 Agent 活动；点击手机或平板上的 Hooks 卡片查看图文详情。示例含静态 PNG 与动画 GIF，截图只记录其中一帧。另见 [大字精简模式](docs/images/v1.0.6/android-panel-compact.png) 与 [Android 图文详情](docs/images/v1.0.6/android-hook-detail.png)。

### 面板设置

| Android：直接调整面板 | iPhone：自定义面板 |
| --- | --- |
| <img src="docs/images/v1.0.6/android-settings.png" width="260" alt="Android 面板设置"> | <img src="docs/images/v1.0.6/iphone-customize.png" width="260" alt="iPhone 的 Token 详略与 Hooks 布局设置"> |

Token 精简／详细、Hooks 1×1／2×2 均可独立选择并自动保存，适合随手查看或长时间放在支架上展示。

### 平板与横屏

<img src="docs/images/v1.0.6/ipad-landscape.png" width="1000" alt="iPad 横屏：侧栏导航，用量与四张 Hooks 图片卡并列">

iPad 横屏将用量与 Hooks 并列，宽窗口使用侧栏导航；手机横屏也采用左右分区。另见 [Android 横屏](docs/images/v1.0.6/android-landscape.png) 与 [Android 大字号](docs/images/v1.0.6/android-large-text.png)。

### Desktop 实验展示台

<img src="docs/images/desktop-experimental/desktop-tablet-panel.png" width="1000" alt="Desktop 实验展示台：侧栏导航、用量与四张 Hooks 并列，使用测试专用演示数据">

宽窗口参照 Android 平板左右分区，缩窄后改为上下分区和底部导航；支持鼠标翻页、图文详情及本机面板设置。另见 [设置](docs/images/desktop-experimental/desktop-settings.png) 与 [窄窗口](docs/images/desktop-experimental/desktop-narrow-panel.png)。图片由隔离的桌面 UI 自动化测试生成；真实采集端配对与实际运行结果另记录在 [实验说明](docs/11-Desktop实验展示终端.md)。

### Android 悬浮窗与小组件

| 悬浮窗：Token 与额度 | 悬浮窗：Hooks 摘要 | 系统桌面小组件 |
| --- | --- | --- |
| <img src="docs/images/v1.0.6/android-overlay-token.png" width="260" alt="Android 桌面上方的 Token 悬浮窗"> | <img src="docs/images/v1.0.6/android-overlay-hooks.png" width="260" alt="Android 悬浮窗的 Hooks 状态摘要"> | <img src="docs/images/v1.0.6/android-widget.png" width="260" alt="添加到 Pixel Launcher 的真实小组件"> |

悬浮窗可拖动、切换两页；小组件保留最近摘要及同步时间。两者都使用精简内容，不显示 Hooks 图片。

### Apple 小组件内容预览

| 小号 | 中号 |
| --- | --- |
| <img src="docs/images/v1.0.6/apple-widget-small.png" width="200" alt="iOS 小号组件的演示内容预览"> | <img src="docs/images/v1.0.6/apple-widget-medium.png" width="420" alt="iOS 中号组件的演示内容预览"> |

小组件视图使用同一份演示摘要单独渲染，供查看内容布局；添加到系统桌面或锁屏的操作见下方说明。[锁屏摘要内容预览](docs/images/v1.0.6/apple-widget-lockscreen.png) 展示了矩形、圆形和单行三种形式。

### Apple Watch

| Hooks 图片与状态 | Token 总量 | 账户额度 |
| --- | --- | --- |
| <img src="docs/images/v1.0.6/watch-hooks.png" width="200" alt="Apple Watch Hooks 图片页"> | <img src="docs/images/v1.0.6/watch-token.png" width="200" alt="Apple Watch 当日 Token 页"> | <img src="docs/images/v1.0.6/watch-quota.png" width="200" alt="Apple Watch 账户额度页"> |

左右切换三个页面，在 Hooks 页上下查看活动；另见 [Watch 动图卡片截图](docs/images/v1.0.6/watch-hooks-gif.png)。更多界面、演示数据来源及实际验证范围见 [v1.0.6 UI 与发布记录](docs/09-v1.0.6发布与UI验证.md)。

## 详细使用说明

### 能看到什么


- **当日 Token 用量**：Token 是模型处理内容的计量单位。显示桌面统计日期对应的总量与各工具明细，支持大字精简模式与分项详细模式，保留完整整数。
- **账户额度**：展示桌面提供的 Codex、Claude Code、Cursor、Grok 额度，包括来源实际提供的五小时、周或账单月周期，以及剩余比例与套餐标签。
- **Agent 活动**：通过 Hooks（工具发送的活动事件）查看空闲、运行、等待确认、出错四种状态。手机和平板支持正文、图片与动图，每页一张或四张卡片，点击可看详情；Watch 展示图片与状态。
- **自定义展示台**：用量和 Hooks 可独立开关，适配手机、平板、横竖屏与大字号，保存本机布局偏好。
- **自动发现与重连**：前台寻找局域网内的电脑，首次由用户选择并配对；之后自动连接已保存的电脑。设置中可修改设备名称、重试连接或忘记配对。
- **跟随桌面 Agent 开关**：用量明细和额度只展示桌面已开启的 Agent，总量保留桌面提供的原值。

移动端展示电脑提供的当日快照，不独立采集 AI 会话、不重新计算总量，也没有历史日期查询。额度由桌面读取，移动端不需要保存各 AI 工具的登录凭据；Cursor 额度卡片也不代表已取得其完整账户 Token 明细。

### 支持的设备


| 设备 | 最低系统 | 说明 |
| --- | --- | --- |
| Android 手机、平板 | Android 12（API 31） | 原生库支持 `arm64-v8a`、`x86_64`，适用于相应真机与模拟器 |
| iPhone | iOS 18.2 | 原生 SwiftUI 应用 |
| iPad | iPadOS 18.2 | 平板布局与多窗口 |
| Apple Watch | watchOS 11.0 | 首次配置需要已配对的 iPhone；Always On 取决于表款及系统设置 |
| Desktop 实验展示终端 | 本次验证 macOS Apple Silicon | 配置了 macOS、Windows、Linux 宿主构建；后两者尚未构建或运行验证，未声明统一最低系统版本 |

### 各端入口


| 入口 | 功能 |
| --- | --- |
| Android App | 手机、平板完整展示台；可手动开启后台实时同步 |
| Desktop 实验 App | 电脑窗口中的完整展示台；与 Android 平板共用界面，窗口存续期间维持连接，没有 Android 系统悬浮窗或小组件 |
| Android 桌面小组件 | 可调整尺寸，查看最近同步的用量、额度、活动摘要与同步时间，支持手动刷新 |
| Android 悬浮窗 | 在其他应用上方查看紧凑卡片；Token 页显示总量与最多四个额度账户，Hooks 页显示最多四条状态与正文首行，不显示图片 |
| iPhone / iPad App | 原生 SwiftUI 展示台，保留最近缓存；iPad 支持多窗口共用连接 |
| iOS 小组件 | 桌面小号、中号，以及锁屏单行、圆形、矩形摘要 |
| Apple Watch | 左右切换 Hooks、Token、额度，支持动图、离线缓存与常亮显示（Always On） |

Android 悬浮窗需开启系统的“显示在其他应用上层”权限。拖动标题可移动，点击或左右滑动可换页；锁屏隐藏、解锁恢复，关闭悬浮窗后后台同步继续运行。

### 安装应用


**Android**：从 [GitHub Releases](https://github.com/ManonLoki/LokiMetisMobileDisplay/releases/latest) 下载 APK 安装，附件中的 `SHA256SUMS` 可用于校验。

**Desktop 实验 App**：当前从实验分支构建运行，见下方 [Desktop 源码运行](#desktop-实验展示终端)。macOS 可生成携带运行时的 `.app`；本次未向正式 Releases 发布桌面安装包。

**iPhone / iPad / Apple Watch**：当前通过 Xcode 开发签名安装，见下方[源码运行说明](#iphone--ipad)。iPhone 宿主同时包含 Widget 和 Watch 应用；Watch 需要与 iPhone 配对。

使用同签名安装包覆盖升级，可保留本机数据。Android 卸载会删除本机配对材料，重新安装后需要再次配对；签名说明见 [signing/README.md](signing/README.md)。

### 第一次连接电脑

1. 在电脑上启动 [LokiMetris 桌面端](https://github.com/ManonLoki/LokiMetis)，让电脑和移动设备处于同一局域网。
2. 打开移动 App，进入“设置”，选择发现的电脑；允许系统提示的本地网络访问。
3. 移动端显示四位码后，保持 App 在前台，在电脑自动弹出的配对窗口中输入该码。四位码有效期为 60 秒，过期后重新发起即可。
4. 显示“已连接”后，回到“展示台”查看数据。以后打开 App 会自动连接保存的配对。

在展示终端忘记配对只移除本机凭据；电脑上的旧设备记录需在采集端单独移除。Desktop 采用相同的四位码流程，为兼容现有采集端按 Android 平板身份连接，采集端设备列表会将它识别为 Android 平板。

### 自定义展示台

1. 打开“设置”。Android 直接在“面板显示”调整；iPhone / iPad 点击“自定义面板”。
2. 分别开启或关闭“Token 用量”和“Hooks”。关闭的内容不占展示区域，两项都关闭时会提示先选择内容。
3. Token 选择“精简”突出总量，选择“详细”查看各 Agent 明细与完整数值。
4. Hooks 选择“1×1”每页一张，或“2×2”每页四张；在展示台左右滑动查看更多卡片。
5. 返回“展示台”查看结果。更改自动保存，只影响这台设备；两块都开启时竖屏上下、横屏左右排列，只开启一块时铺满展示区域。用量明细较多时，可在用量卡片内上下滚动。

Desktop 与移动端的窄窗口通过底部导航切换展示台与设置，宽窗口使用侧栏；iPad 分屏时也会随窗口宽度调整。iPad 多窗口共用桌面连接，不需要每个窗口重新配对。

### 查看 Hooks 图文与状态

Hooks 是编程工具发送的活动事件，卡片可显示空闲、运行、等待确认（界面显示“询问”）、出错四种状态。在手机或平板上点击卡片可查看正文和图片详情，查看结束后关闭详情返回展示台；卡片中的图片和动图由桌面提供，移动端下载并缓存。想专注看一张图时使用 1×1，想同时看多个工具时使用 2×2。

正文、图片与 Agent 开关在桌面端配置。移动端暂不提供修改这些内容的入口；没有图片时卡片仍显示标题与状态，正文可在详情中查看。小组件只显示活动状态汇总；Android 悬浮窗显示当前连接的状态与正文首个非空行，两者均不展示 Hooks 图片。

### Android 后台实时同步与悬浮窗

1. 完成配对后，在设置中点击“开启后台实时同步”，让应用在后台维持连接；按系统提示允许通知，便于在持续通知中查看状态和停止同步。
2. 需要悬浮窗时，点击“授权悬浮窗”，在系统页面允许“显示在其他应用上层”，返回应用后会自动显示窗口；已授权时直接点击“显示悬浮窗”。显示窗口时也会开启后台实时同步。
3. 拖动窗口标题移动位置；点击标题或内容，或在内容区左右滑动，在 Token 与 Hooks 两页间切换。Token 页最多显示四个额度账户，Hooks 页最多显示四条状态及正文首行。
4. 点击窗口关闭按钮或设置中的“隐藏悬浮窗”只隐藏窗口。要结束后台连接，点击“停止后台实时同步”或通知里的“停止同步”。

锁屏时悬浮窗隐藏，解锁后恢复。系统结束进程或设备重启后，需重新手动开启后台实时同步；具体后台限制取决于设备系统。

### 添加桌面与锁屏小组件

**Android**：在应用设置中点击“添加小组件”，按系统提示确认；也可长按系统桌面，从“诡秘神谕／LokiMetris”列表添加。长按组件后拖动边框调整尺寸，使用刷新入口更新摘要，点击主体可回到 App。较大尺寸可显示更多额度账户，最窄的精简尺寸不显示额度；活动摘要按四种状态汇总数量。

**iPhone / iPad**：先在 App 完成配对和一次同步，再长按主屏幕添加“诡秘神谕／LokiMetris”小组件，选择小号或中号。iPhone 锁屏可添加单行、圆形或矩形摘要。

小组件显示最近摘要和原同步时间。刷新失败时保留旧结果；如一直为空，回到 App 检查配对与连接，重新同步一次。

### 使用 Apple Watch

1. 使用系统已配对的 iPhone / Watch 组合，在 iPhone 安装并打开 App，完成电脑配对与一次同步。
2. 在手表打开“诡秘神谕／LokiMetris”，自动读取手机同步的内容，无需在手表输入配对码。
3. 左右滑动切换 Hooks、Token、额度页；在 Hooks 页上下滑动逐条查看活动图片与状态，正文在手机或平板查看。Token 页查看当日用量，额度页查看桌面提供的账户周期。
4. 如迟迟没有新数据，先确认 iPhone 已连接电脑，再在本应用的“设置 → 扩展”中展开“Apple Watch”，点击“重试手表同步”；保持手机、手表和电脑可通信。

Watch 的新图片经 iPhone 同步。手机不可达时，已获配置的 Watch 可向电脑读取只读摘要。如需延长抬腕后的停留时间，可在手表“设置 → 通用 → 返回表盘”中调整本应用的返回时间。常亮显示遵守表款、省电和减少动态效果等系统设置。

### 后台更新与离线


| 入口 | 断线或进入后台后的行为 |
| --- | --- |
| Android 主展示台 | 只显示当前连接数据；断线后清空，重启不恢复旧面板。未开启实时同步时，进入后台会关闭连接 |
| Desktop 实验展示台 | 断线清空完整面板；失焦与最小化保持连接，最小化暂停动效，关闭窗口退出。已校验图片可以保留，必须被新认证快照引用后才重新显示 |
| Android 后台实时同步 | 用户手动开启后，通过前台服务维持连接并显示持续通知；系统结束进程或设备重启后需重新开启 |
| Android 小组件 | 独立保留最近一次摘要和原同步时间，刷新失败时继续显示旧结果 |
| iPhone / iPad | 保留最近数据与同步时间；进入后台关闭持续连接，系统后台任务可短暂连接电脑更新摘要 |
| iOS 小组件 | 可独立向已配对电脑读取只读摘要，失败时保留缓存 |
| Apple Watch | 优先从 iPhone 同步；手机不可达时可向电脑读取摘要，新图片仍需通过手机获取 |

Apple App、小组件与 Watch 的后台刷新申请间隔约为 **5 分钟**，Android 普通后台任务的申请间隔为 **15 分钟**。实际执行时间由系统调度与省电策略决定，不保证准时更新或持续实时连接。

小组件的独立摘要包含用量、额度与活动状态，不包含 Hooks 正文和图片。Android 为组件单独保存摘要与只读刷新目标，主展示台不会用这份摘要恢复旧面板；Apple 主 App 的完整缓存还可保留正文和图片引用。离线缓存以原同步时间标识；电脑需要在线且局域网可达，才能取得新数据。

## 从源码运行

以下命令以 macOS 为例。iPhone / iPad 当前只配置 ARM64 真机与模拟器目标，同时开发 Android 和 Apple 端可使用 **Apple Silicon Mac**。

### 工具与源码

| 工具 | 用途 |
| --- | --- |
| JDK 21 | Gradle 构建，仓库配置使用 Azul 21 |
| Android Studio、SDK、NDK | Android 开发；需要 SDK Platform 37、Platform Tools，以及包含 API 31 Clang 的 NDK |
| Xcode | iPhone、iPad、Watch 与 Widget 开发，需要对应系统的 SDK 和模拟器运行时 |
| Rust / Cargo / rustup | 编译主通道配对与加密核心，版本要求见所选桌面仓库的 `Cargo.toml` |
| Python 3 | 运行仓库自带的构建、签名及 Apple 测试脚本，无第三方 Python 依赖 |
| 宿主 C 编译工具 | Desktop JNI 构建；macOS 使用 Xcode Command Line Tools，Linux 使用 C 编译器与 libc 开发文件，Windows 使用匹配 Rust 的 MSVC 或 MinGW 工具链 |

Gradle 使用项目的 `./gradlew`。完整 Android／iPhone App 与 Desktop 展示终端还依赖采集端仓库中的 Rust 源码，需同时准备两个仓库，并选择与移动版本兼容的桌面提交：

```sh
git clone https://github.com/ManonLoki/LokiMetisMobileDisplay.git
git clone https://github.com/ManonLoki/LokiMetis.git
cd LokiMetisMobileDisplay
```

下面的 `/absolute/path/to/LokiMetis` 请替换为桌面仓库的绝对路径。新环境应显式指定路径，不依赖脚本中的原开发环境默认值。构建脚本不安装开发工具；Gradle 与 Cargo 首次构建仍可能下载清单和锁文件声明的依赖。

### Android

在 Android Studio 中打开本仓库。通过 SDK Manager 准备 SDK 与 NDK，在本机 `local.properties` 中设置 `sdk.dir`；也可使用 `ANDROID_HOME`，需要指定 NDK 时设置 `ANDROID_NDK_HOME`。

添加 Rust 编译目标：

```sh
rustup target add aarch64-linux-android x86_64-linux-android
```

Debug 与 Release 都使用项目固定签名。需要覆盖已有安装时，迁移原有 `signing/lokimetris.keystore` 和 `signing/signing.properties`；本机已有原开发证书时可运行 `python3 scripts/prepare_android_signing.py`。首次独立安装、无需兼容旧签名时初始化新签名：

```sh
python3 scripts/prepare_android_signing.py --new-key
```

将 SDK 的 `platform-tools` 加入 `PATH`。真机开启 USB 调试并允许电脑连接，或在 Android Studio 启动模拟器，然后构建安装：

```sh
./gradlew :androidApp:assembleDebug \
  -PlokiDesktopRoot=/absolute/path/to/LokiMetis

adb install -r androidApp/build/outputs/apk/debug/androidApp-debug.apk
adb shell am start -n com.manonloki.lokimetrisdisplay/.MainActivity
```

使用 IDE 调试时选择 `androidApp` 运行配置、目标设备并点击 **Debug**。桌面源码路径可写入本机 `~/.gradle/gradle.properties`：

```properties
lokiDesktopRoot=/absolute/path/to/LokiMetis
```

构建 Release APK 时，将任务换为 `:androidApp:assembleRelease`，保留路径参数；输出为 `androidApp/build/outputs/apk/release/androidApp-release.apk`。

当前 Android 的 Debug／Release 共用原生库生成任务，Rust 桥均使用脚本默认的 Cargo Debug 配置；APK 的 Release 名称不代表桥已采用 Cargo Release 优化。

### Desktop 实验展示终端

先切换到实验分支；桌面开发与验证统一使用此分支，不合入 `main`：

```sh
git switch codex/desktop-experimental
./gradlew :desktopApp:run \
  -PlokiDesktopRoot=/absolute/path/to/LokiMetis
```

首次打开后进入“设置”选择采集端，在采集端输入本窗口显示的四位码。展示终端可与采集端运行在同一台或另一台电脑上，发现仍依赖局域网多播和系统防火墙规则。窗口失焦或最小化不会断开连接；关闭窗口结束进程。

生成当前系统、当前架构的应用目录或安装包：

```sh
./gradlew :desktopApp:createDistributable \
  -PlokiDesktopRoot=/absolute/path/to/LokiMetis
./gradlew :desktopApp:packageDistributionForCurrentOS \
  -PlokiDesktopRoot=/absolute/path/to/LokiMetis
```

macOS 应用目录为 `desktopApp/build/compose/binaries/main/app/LokiMetrisDisplay.app`，携带运行时和本机 Rust／JNI 库。构建配置提供 macOS DMG、Windows MSI、Linux DEB，需在对应系统构建；本次已验证 macOS arm64 应用目录，Windows／Linux 与各系统安装包尚未验证。Windows 使用 `gradlew.bat`，MSVC 构建需从 Visual Studio Native Tools 环境运行。详细依赖、私有数据位置与测试记录见 [Desktop 实验说明](docs/11-Desktop实验展示终端.md)。

### iPhone / iPad

添加 Rust 编译目标并打开 Xcode 工程：

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
open iosApp/iosApp.xcodeproj
```

1. 选择 **iosApp** scheme，以及 iPhone 或 iPad 模拟器。
2. 在项目 Build Settings 添加 `LOKI_DESKTOP_ROOT`，值为桌面仓库的绝对路径。
3. 点击 **Run** 或 **Debug**，Xcode 会编译 Kotlin framework 与 Rust 桥；构建进程需能找到 JDK、`python3` 和 `cargo`。
4. 使用真机时，在 `iosApp/Configuration/Config.xcconfig` 中填写自己的 `TEAM_ID`，并准备对应签名与设备描述文件；在设备上开启开发者模式，在 Xcode 中完成设备连接。

`TEAM_ID` 参与生成 Bundle ID（应用标识）与 App Group（App 和小组件共用的存储容器）。主 App、Widget 和 Watch 的签名及配套标识需匹配；覆盖已有安装时沿用原团队与应用标识。

也可从命令行构建 iOS 模拟器应用：

```sh
xcodebuild -project iosApp/iosApp.xcodeproj \
  -scheme iosApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  LOKI_DESKTOP_ROOT=/absolute/path/to/LokiMetis \
  CODE_SIGNING_ALLOWED=NO build
```

这条命令禁用签名，用于验证构建。连接调试还需要可用的 Keychain（系统安全存储）及正确的 App / Widget 共享容器权限。v1.0.6 的未签名模拟器验证遇到设备身份保存失败，未完成真实配对验收，具体环境与范围见 [UI 验证记录](docs/09-v1.0.6发布与UI验证.md)。

### Apple Watch

在 Xcode 选择 **LokiMetrisWatch** scheme 和目标手表，点击 **Run** 或 **Debug**。同步需要已配对的 iPhone / Watch 组合，并先在 iPhone 完成电脑配对；实体 Watch 同样需开启开发者模式并连接 Xcode。

Watch 界面使用 SwiftUI，并链接 SharedLogic 共享规则，可单独构建模拟器目标：

```sh
xcodebuild -project iosApp/iosApp.xcodeproj \
  -scheme LokiMetrisWatch -configuration Debug \
  -sdk watchsimulator \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

### 共享逻辑与 Apple 测试

SharedLogic 同时编译到 Android、Desktop JVM、iOS 和 watchOS。Watch 真机保留 `arm64` 与 `arm64_32`，Apple 模拟器使用 Apple Silicon 的 `arm64`。Xcode 的 App、Watch、Widget 各自生成并链接所需框架；构建脚本会串行更新共用产物。

在 Apple Silicon Mac 上运行：

```sh
./gradlew :sharedLogic:testAndroidHostTest :sharedLogic:desktopTest :sharedLogic:iosSimulatorArm64Test
python3 scripts/test_apple_shared.py
```

第二条命令先生成 macOS SharedLogic 框架，再让 Swift 测试真实调用共享业务规则。测试覆盖 Swift 数据编解码、文件事务和系统适配边界，在 macOS 宿主运行，不代替 iOS／watchOS 模拟器或真机互通验证；可在脚本后追加 SwiftPM 参数，例如 `--filter WidgetSnapshotTests`。

## 技术与目录

Android 与 Desktop 使用 Kotlin + Compose，共用 `sharedUI` 的展示台、设置、用量卡片、Hooks 图文详情与动效；Apple 各端使用原生 SwiftUI；主局域网通道的配对与加密核心由桌面仓库的 Rust 模块提供，只读 HTTP 使用独立密钥并由各平台密码 API 执行。Android、Desktop、iOS、Watch 和 Widget 通过 SharedLogic 复用展示模型校验、Agent 筛选与排序、用量和额度规则、连接时限与帧容量、Watch 传输与配置、图片调度与缓存淘汰、解码预算，以及只读 HTTP 协议与局域网地址边界。系统网络、文件与图片解码仍由平台执行；Swift 保留原有数据编码格式与界面适配。

```text
.
├── androidApp/       Android 入口、平台界面、小组件、后台同步、悬浮窗与本地桥构建
├── desktopApp/       实验桌面窗口、发现／连接、私有存储、图片与宿主原生库构建
├── sharedUI/         Android／Desktop 共用 Compose 页面与动效
├── sharedLogic/      各端共享业务规则；androidMain 内为 Android 网络与存储适配
├── iosApp/
│   ├── iosApp/                iPhone / iPad 应用
│   ├── LokiMetrisWatch/       Apple Watch 应用
│   ├── LokiMetrisWidgets/     iOS 桌面与锁屏小组件
│   ├── WidgetShared/          App 与小组件共享容器
│   ├── Configuration/         Apple 版本与应用标识配置
│   └── iosApp.xcodeproj/      Xcode 工程
├── appleDisplay/     Apple 共用的 Swift 展示、缓存与传输逻辑
├── scripts/          移动／桌面 Rust 桥、Apple 共享框架与测试、Android 签名及图标脚本
├── signing/          Android 签名说明
├── branding/         应用图标资源
├── docs/             功能与技术文档
└── gradle/           Wrapper、JDK 与依赖配置
```

```mermaid
flowchart TD
    desktop["电脑 LokiMetris：用量、额度、Hooks"] -->|局域网加密连接| android["Android App"]
    desktop -->|局域网加密连接| ios["iPhone / iPad App"]
    desktop -->|局域网加密连接| display["Desktop 实验展示终端"]
    android --> androidWidget["Android 桌面小组件"]
    android --> floating["Android 悬浮窗"]
    ios -->|共享缓存| widget["iOS 小组件"]
    ios -->|手机同步| watch["Apple Watch"]
    desktop -->|只读加密摘要| androidWidget
    desktop -->|只读加密摘要| widget
    desktop -->|只读加密摘要| watch
```

版本名和构建号见 [Android 配置](androidApp/build.gradle.kts) 与 [Apple 配置](iosApp/Configuration/Config.xcconfig)；Desktop 实验包的配置见 [desktopApp](desktopApp/build.gradle.kts)。

当前发布为 **v1.0.7**：Android 构建号 **9**，Apple 构建号 **15**；变化与实际验证范围见 [发布记录](docs/10-v1.0.7发布与设备安装.md)。移动端 UI 图片保留 v1.0.6 的演示来源说明；Desktop 图片与验证属于实验分支，不构成新版本发布。

| 要修改的内容 | 先看哪里 |
| --- | --- |
| 展示规则、额度、排序、缓存与传输策略 | `sharedLogic/src/commonMain/` |
| Android／Desktop 共用展示台、设置、卡片与动效 | `sharedUI/src/commonMain/` |
| Android 平台界面、组件、悬浮窗与后台服务 | `androidApp/src/main/` |
| Desktop 窗口、连接、存储与图片 | `desktopApp/src/desktopMain/` |
| Android 连接、配对、图片缓存与独立摘要 | `sharedLogic/src/androidMain/` |
| Apple 网络、系统生命周期与各端界面 | `iosApp/` |
| Apple 编解码、缓存、传输适配与跨语言测试 | `appleDisplay/` |

完整文件职责、并发队列和存储边界见 [文档索引](docs/README.md) 与 [当前架构](docs/07-当前架构.md)。历史发布验证按版本保留，不能作为后续改动已验收的依据。

## 常见问题

| 遇到的情况 | 检查方式 |
| --- | --- |
| 找不到电脑 | 确认桌面应用运行、处于同一局域网并允许本地网络访问；访客 Wi-Fi 隔离、VPN 和防火墙可能影响发现 |
| Android 切到后台后展示台没数据 | 未开启实时同步时，后台会关闭连接；返回前台等待重连，或在设置中手动开启后台实时同步 |
| 悬浮窗无法显示 | 检查“显示在其他应用上层”权限，锁屏时窗口会隐藏 |
| App 有数据，小组件为空 | 先完成一次前台配对同步；Apple 端检查 App Group 与签名，桌面端需支持只读摘要 |
| 小组件或 Watch 更新较慢 | 查看原同步时间；后台刷新受系统调度影响，Watch 的新图片需由手机补齐 |
| 构建提示缺少 Rust bridge | 检查桌面源码是否完整，`lokiDesktopRoot` 或 `LOKI_DESKTOP_ROOT` 是否指向正确目录 |
| Android 无法覆盖安装 | 确认沿用原签名；迁移方式见[签名说明](signing/README.md) |

进一步阅读：[Desktop 实验展示终端](docs/11-Desktop实验展示终端.md)、[KMP 分层优化与后续路线](docs/08-KMP分层与优化路线.md)、[当前架构与源码导航](docs/07-当前架构.md)、[文件结构详解](docs/01-文件结构.md)、[技术架构](docs/02-技术架构.md)、[功能与交互](docs/03-业务需求整理.md)、[Android 签名](signing/README.md)。

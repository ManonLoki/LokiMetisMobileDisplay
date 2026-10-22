# 11 Desktop 实验展示终端

核对日期：2026-10-22。本文对应 `codex/desktop-experimental` 工作树，记录 DesktopApp 的使用、构建、兼容与验证范围。正式发布仍为 **v1.0.7**；本次没有创建发布标签或向正式 Releases 发布桌面安装包。

## 用途与界面

`desktopApp` 是运行在电脑窗口中的**展示终端**。数据仍由 [LokiMetris 采集端](https://github.com/ManonLoki/LokiMetis) 统计并通过局域网发送；DesktopApp 不扫描本机 AI 会话，不读取各工具登录凭据，也不重新计算 Token 总量。

它与 Android 平板共用 `sharedUI`：

- 宽窗口使用侧栏导航，用量与 Hooks 左右分区；缩窄后使用底部导航和上下分区。
- Token 支持精简与详细，保留完整整数、账户套餐和实际额度周期；Agent 筛选与排序调用 `sharedLogic`。
- Hooks 支持 1×1／2×2，鼠标可点“上一页／下一页”；点击卡片查看正文和大图。
- 图片支持 BMP、PNG、JPEG、WebP 与 GIF；动画遵循图片帧时长和循环数，在最小化或不可见时停止界面计时。
- 设备名称、面板开关和布局保存在本机。没有 Android 系统悬浮窗、小组件、后台服务设置或 Apple Watch 通道。

![Desktop 平板布局示例](images/desktop-experimental/desktop-tablet-panel.png)

[设置示例](images/desktop-experimental/desktop-settings.png) · [窄窗口示例](images/desktop-experimental/desktop-narrow-panel.png)

上述 PNG 来自 Desktop Compose 自动化测试。数字、账户、正文和图片均为测试专用样例，使用隔离临时目录，不写入用户正式数据。静态截图只证明相应布局，不作为真实局域网配对或动画播放的证据。

## 连接与日常使用

1. 启动 LokiMetris 采集端，让两台电脑处于可通信的同一局域网；也可以在同一台电脑同时运行采集端和展示端。
2. 启动 DesktopApp，进入“设置”，从自动发现列表选择采集端。
3. 在采集端配对窗口中输入展示端显示的四位码；配对窗口有效期为 60 秒。
4. 认证后收到第一份合法完整快照才显示“已连接”。之后启动会自动重连已保存且本轮发现的采集端。

窗口失焦和最小化不会关闭网络连接；最小化暂停动效，关闭窗口退出应用并释放连接。完整展示快照只在内存，断线后撤下用量、额度、Hooks 及对应图片投影，重启不显示旧面板。已校验图片可以留在磁盘，只有新认证快照再次引用后才恢复显示。

### Android 平板兼容身份

当前采集端协议只接受 `android`／`ios` 平台，设备形态只接受 `phone`／`tablet`。按用户指定的兼容方式，DesktopApp：

- 在加密设备信息中发送 `platform: "android"`、`appVersion: "1.0.7-desktop-experimental"`，本机持久 UUID 和名称仍按实际配置发送。
- 仅在当前认证快照广告 `deviceFormFactorV1` 能力后，上报一次 `formFactor: "tablet"`；重连后重新协商。
- 不修改外部采集端源码、不扩展其平台枚举。因此采集端会将此终端识别为 Android 平板。

这只影响对端协议中的设备类别，DesktopApp 实际仍是运行在 JVM（Java 虚拟机）上的桌面应用。发现目前通过 IPv4 多播发送 mDNS 查询，可解析收到的 AAAA（IPv6 地址）记录；尚未建立 IPv6 多播发现通道，不能视为已支持 IPv6-only 局域网。

## 从源码运行与打包

桌面功能开发、修复和集成验证统一使用 `codex/desktop-experimental`，跟踪 `origin/codex/desktop-experimental`。沿用当前仓库和 `origin`，不创建 fork；此分支与 `main` 禁止互相 merge、squash、rebase 或 cherry-pick，也不创建以 `main` 为目标的桌面实验合并请求。仓库协作规则见 [AGENTS.md](../AGENTS.md)。

需要完整 JDK 21、Rust/Cargo、Python 3 和当前系统的 C 编译工具；本次构建辅助脚本已在 Python 3.9 下验证，不要求额外安装第三方模块。Gradle 使用仓库 wrapper，Python 脚本只使用标准库，不安装开发工具。额外需要采集端仓库的 `loki_metris_pairing`、`loki_metris_mobile_bridge` 和其 `Cargo.lock`：

```sh
git switch codex/desktop-experimental
./gradlew :desktopApp:run \
  -PlokiDesktopRoot=/absolute/path/to/LokiMetis
```

| 系统 | 原生构建工具 | 当前范围 |
| --- | --- | --- |
| macOS | Xcode Command Line Tools，含 Clang、macOS SDK、`install_name_tool` 和 `codesign` | 本次已验证 Apple Silicon arm64 |
| Linux | C 编译器与 libc 开发文件 | 已配置构建路径，尚未构建或运行验证 |
| Windows | 与 Rust 宿主相符的 Visual Studio MSVC Native Tools，或 MinGW GCC | 已配置构建路径，尚未构建或运行验证；使用 `gradlew.bat` |

构建只生成当前系统、当前架构的原生库，没有在 macOS 上交叉生成 Windows／Linux 产物。未据此声明统一最低系统版本。

### 原生库构建

`desktopApp:buildDesktopNative` 调用 [build_desktop_native.py](../scripts/build_desktop_native.py)，以 `cargo build --locked --lib --target <宿主>` 编译外部 Rust 桥，再用本仓库已有的 [JNI C 包装](../androidApp/src/main/c/loki_metris_jni.c) 生成宿主 JNI 库。JNI 是 JVM 调用本机原生代码的接口。脚本显式传入当前宿主架构，产物隔离在本项目的 `build/`，不修改外部源码或锁文件。

也可单独调用脚本：

```sh
python3 scripts/build_desktop_native.py \
  --desktop-root /absolute/path/to/LokiMetis \
  --java-home /absolute/path/to/jdk-21 \
  --out desktopApp/build/generated/desktopNative
```

当前 Gradle 任务沿用脚本默认的 Cargo Debug 配置；桌面安装包的名称不代表其中 Rust 桥已经采用 Release 优化。独立脚本可显式传 `--configuration release`，其输出需与对应构建任务安排一致。

两个原生库随当前架构 JAR 一起分发，启动时提取到本用户私有临时目录并按绝对路径加载，安装后的应用不依赖开发机上的源码目录。

### 应用目录与安装包

```sh
./gradlew :desktopApp:createDistributable \
  -PlokiDesktopRoot=/absolute/path/to/LokiMetis
./gradlew :desktopApp:packageDistributionForCurrentOS \
  -PlokiDesktopRoot=/absolute/path/to/LokiMetis
```

`createDistributable` 生成携带运行时的当前系统应用目录；macOS 路径为 `desktopApp/build/compose/binaries/main/app/LokiMetrisDisplay.app`。`packageDistributionForCurrentOS` 使用当前系统的分发格式，配置为 macOS DMG、Windows MSI、Linux DEB。生成应用目录、生成安装包、开发者签名／公证、对外发布是不同步骤，执行结果分别记录在下方。

Desktop 打包配置暂沿用包版本 `1.0.7`，没有独立桌面构建号；Android 仍为 `1.0.7 (9)`，Apple 为 `1.0.7 (15)`。这些配置值不表示已发布新的桌面版本。

## 本机数据与源码入口

| 系统 | 默认数据目录 |
| --- | --- |
| macOS | `~/Library/Application Support/LokiMetrisDisplay/` |
| Windows | `%LOCALAPPDATA%\LokiMetrisDisplay\`，缺省回退到用户的 `AppData\Local` |
| Linux | `$XDG_DATA_HOME/LokiMetrisDisplay/`，缺省为 `~/.local/share/LokiMetrisDisplay/` |

| 文件 | 内容与寿命 |
| --- | --- |
| `settings.properties` | 本机 UUID、名称和面板偏好；完整原子提交。坏名称或布局回退默认，已有损坏 UUID 显式失败，不偷偷更换配对身份 |
| `pairings-v1.json` | 以采集端 UUID 索引的配对材料；提交成功后 Rust 才生成 ACK，忘记操作只删除精确记录 |
| `lan-assets-v1/` | 以 SHA-256 摘要寻址的已校验图片，当前认证快照引用优先保留；淘汰目标为 512 MiB／512 文件，不是强制硬上限 |

配对材料当前保存在本用户私有 JSON 文件，未接入系统钥匙串或平台密钥库。POSIX 系统限制目录为 0700、文件为 0600；Windows 配对与资源存储通过 ACL（访问控制列表）限制用户访问。主面板完整快照没有持久恢复文件，也没有小组件只读 HTTP 目标。

| 要修改的内容 | 入口 |
| --- | --- |
| 共用界面 | `sharedUI/src/commonMain/kotlin/com/manonloki/lokimetrisdisplay/` |
| 窗口、设置、图片、时间 | `desktopApp/src/desktopMain/kotlin/com/manonloki/lokimetrisdisplay/Desktop*.kt` |
| 发现、DNS 缓存、TCP 与连接状态 | 同目录 `connection/` |
| 严格 JSON 与平板兼容身份 | 同目录 `protocol/` |
| 配对、原子文件与图片缓存 | 同目录 `storage/` |
| Rust JNI 与资源库加载 | 同目录 `nativebridge/` |
| 公共业务及 JVM Unicode 比较键 | `sharedLogic/src/commonMain/`、`sharedLogic/src/desktopMain/` |

## 本次验证记录

本次外部 Rust 依据为提交 **`0e326ceb745d7fa50119d61ab5a2ee59d868c9f6`**。外部仓库位于其 `main`，核对时工作区干净，未为 Desktop 修改外部协议或源码。本仓库的 JNI C 源仍沿用 Android 的现有实现。

已确认的验证：

| 检查 | 已确认结果 |
| --- | --- |
| Desktop 宿主编译与本机原生库构建 | macOS arm64 通过 |
| Desktop 全量测试 | `:desktopApp:desktopTest` 共 26 项通过，0 失败；包括 DNS／TCP／协议／存储、设置重启与失败保护、PNG／JPEG／BMP／WebP／GIF、GIF 像素／70 与 130 ms 时长／有限循环、513 帧拒绝、宽窄布局、鼠标分页和详情 |
| mDNS 缓存一致性 | 分包多地址保留、cache-flush 的一秒宽限、goodbye 延迟失效与重新广播恢复均通过；实现依据 [RFC 6762 第 10 节](https://www.rfc-editor.org/rfc/rfc6762#section-10) |
| Rust JNI 与 TCP 全链路 | `DesktopConnectionIntegrationTest` 使用隔离 Rust 测试端，验证首次配对、存储后 ACK、新 TCP 恢复、Android 平板协商每连接仅一次、中文与 emoji 完整快照、PNG 校验下载、ping／pong、断线清空及关闭释放 |
| 原生构建 Python 辅助脚本 | 6 项通过，使用标准库；Python 3.9 可运行 |
| Android 回归与公共 JVM 规则 | `:androidApp:assembleDebug` 通过；`:sharedLogic:testAndroidHostTest` 149 项、`:sharedLogic:desktopTest` 133 项通过；不代表 Android 真机安装或配对验收 |
| macOS 应用目录与实际启动 | `:desktopApp:createDistributable` 成功；实际启动携带运行时的 `.app`，mDNS 发现成功 |
| 真实采集端配对与展示 | 用户在 Desktop 窗口手动完成配对，已看到实际 Token、额度与 Hooks 图片；真实内容截图不纳入文档 |
| UI 图片 | Desktop UI 测试生成五张 PNG，本文选用其中三张演示布局 |

自动化集成使用隔离测试端，与用户手动完成的真实采集端配对分别验证；测试数据没有进入正式采集端。macOS DMG、Windows／Linux 构建与运行、跨电脑真实局域网配对、IPv6-only 网络、Apple 构建／真机回归、开发者签名与公证均未验证；没有执行正式发布。

常用回归入口：

```sh
./gradlew :desktopApp:desktopTest :sharedLogic:desktopTest \
  -PlokiDesktopRoot=/absolute/path/to/LokiMetis
```

UI 测试截图生成在 `desktopApp/build/screenshots/`，文档使用最终测试输出的三张样例 PNG。186 个本地文档目标路径与 `git diff --check` 已通过核对。文档核对已覆盖 README 的使用与启动、能力、设备／平台范围、目录、架构、版本与外部源码依赖；已有发布记录保持原范围，本次实验记录不替代未来正式发布时的 [发布检查清单](06-发布检查清单.md)。

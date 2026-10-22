# 08 KMP 分层与优化路线

核对日期：2026-10-22；当前源码基线为 `v1.0.7`。前半篇说明现有分层与待评估边界，后半篇保留发布前五轮共享层整理的历史记录。那些记录中的版本 `1.0.5`、测试数量和本机构建日志仍属于当时产物；本次文档核对未重新执行这些构建。模拟器 UI 历史证据见 [09](09-v1.0.6发布与UI验证.md)，本次发布验证见 [10](10-v1.0.7发布与设备安装.md)，当前架构图与源码索引见 [07](07-当前架构.md)。

## 官方依据与当前结构

以 [Kotlin 官方推荐项目结构](https://kotlinlang.org/docs/multiplatform/multiplatform-project-recommended-structure.html) 为主线：应用入口独立，平台和界面无关的业务规则放共享模块；只有需要共享 Compose 界面的平台才使用额外的 `sharedUI`。结合 [Android 官方模块化指南](https://developer.android.com/topic/modularization)，按实际消费者和编译隔离收益决定粒度，不额外增加一组小型 `core/domain/data/feature` 构建模块。

当前采用 **SharedLogic 业务决策 + 平台接口与原生界面**：

- Android、iOS 主 App、iOS Widget、Watch 均实际使用 SharedLogic。
- Android 的 Compose 界面归 `androidApp`，仅支持 Android 的原 `sharedUI` 已合并。
- Apple 保留 Swift Codable 数据外壳（用于既有 JSON 编解码）和 SwiftUI 界面；领域验证、展示与缓存决策调用 Kotlin，删除重复算法。
- macOS 目标供 Swift 测试真实链接共享框架，不新增 macOS 产品。
- Rust 仍提供主通道配对、认证和加解密；Watch 与 Widget 不链接 Rust、不持有主配对秘密。

## 模块和编译目标

| 部分 | 当前处理 | 原因 |
| --- | --- | --- |
| `sharedUI` → `androidApp` | 已合并，Gradle 从三个模块减为两个 | 只有 Android 目标；消除中间模块、单目标 `expect/actual` 和通过 UI 间接暴露核心的依赖 |
| `sharedLogic` | 保留，Android 显式依赖；Apple 各目标链接对应静态框架 | 公共 `commonMain` 不依赖 Compose 或系统视图；`androidMain` 仍包含系统网络、存储及 `Drawable` 图片投影 |
| iOS App、Watch App、Widget Extension | 保留三个 Xcode target | 权限、系统入口、生命周期和安装产物独立 |
| `appleDisplay` | 仍为共享 Swift 源码与 SwiftPM 测试入口 | Xcode 按需编译源文件，SwiftPM 测试同时链接 macOS SharedLogic；未改成 Xcode package product 依赖 |
| `WidgetShared` | 保留为文件目录 | 仅为 App Group 容器适配，没有需要合并的独立构建模块 |
| 桌面 Rust | 保持外部源码依赖 | 同一协议实现同时服务桌面和移动端 |

SharedLogic 的 Apple 目标：

| 用途 | Kotlin 目标 | 架构 |
| --- | --- | --- |
| iPhone / iPad 真机 | `iosArm64` | arm64 |
| iOS / Widget 模拟器 | `iosSimulatorArm64` | arm64 |
| Watch 真机 | `watchosArm64`、`watchosDeviceArm64` | arm64_32、arm64 |
| Watch 模拟器 | `watchosSimulatorArm64` | arm64 |
| Swift 测试 | `macosArm64` | Apple Silicon macOS |

本项目实际目标以 [sharedLogic/build.gradle.kts](../sharedLogic/build.gradle.kts) 与 [Xcode 工程](../iosApp/iosApp.xcodeproj/project.pbxproj) 为准：保留 Watch 真机双架构，Apple 模拟器与 macOS 测试仅声明 arm64，没有配置 Intel 模拟器目标。平台支持级别会随工具链变化，查阅 [Kotlin/Native 官方支持表](https://kotlinlang.org/docs/native-target-support.html) 时应匹配项目的 Kotlin 版本，不能仅凭上游支持表推定本仓库已验证。

## 哪些业务已经只维护一份

| 业务 | SharedLogic 中的实现 | 平台适配保留什么 |
| --- | --- | --- |
| 名称、UUID、内容摘要格式 | `MdnsProtocol`、`TerminalValueRules` | 系统设备信息、密码哈希计算 |
| 连接选择与重试预算 | `TerminalConnectionPolicy` | Bonjour/NSD、Socket、线程/队列、计时器执行 |
| 连接阶段、预算、超时优先级 | `TerminalSessionPhase`、`TerminalSessionTimingPolicy` | 平台时钟精确到期比较、失败清理、首次快照起算事件与调度 |
| 帧容量、阶段长度、写队列与写超时 | `TerminalFramePolicy`、`TerminalWritePolicy` | 原生 Data / ByteArray 缓冲、网络字节序和真实收发 |
| 认证能力表 | `TerminalCapabilities` | JSON 字段映射；坏表不授予扩展或只读 HTTP 权限 |
| 面板默认值、恢复、枚举键、列数与分页位置 | `PanelConfiguration`、`HookLayout` | SwiftUI / Compose 控件、标题、UserDefaults / SharedPreferences |
| 每连接一次的设备形态报告 | `TerminalDeviceTypeReport` | UIKit / Android 系统类别观测、JSON 外壳 |
| Agent 别名、启用过滤、排序、Token 与额度合并、Cursor 默认零行 | `UsageDisplayPolicy` | Swift 根据共享索引映射回原始 Codable 对象 |
| 数字精度、进位、质量文字、Hook 状态文字 | `TokenFormatting`、`UsageDisplayPolicy` | 原生字体、颜色、读屏及日期格式 |
| 完整/摘要快照、Token、额度、图片描述的领域校验 | `TerminalSnapshot`、`TerminalTokens`、`TerminalAmount`、`ProviderQuota*`、`TerminalAsset` | 数据解码、Apple 图片历史时间外壳与主机/文件系统校验 |
| 套餐标签、窗口顺序、剩余比例、百分比及语义档位 | `ProviderQuota*` | 具体颜色、布局与 Date 转换 |
| 无正文/图片摘要裁剪 | `TerminalWidgetSnapshot` | Android 现有二进制存储；Apple 仍使用既有 Swift 编码外壳 |
| 来源与时间接纳、旧 HTTP 回复拒绝、完整度优先 | `SnapshotAcceptancePolicy` | 在原有锁中读取、完整 target 比较及原子提交 |
| 同一读取配置保留代次 | `RefreshConnection` | 平台生成 UUID、主机解析和凭据存储 |
| 45 秒摘要租约、缓存资格、刷新到期 | `SnapshotFreshnessPolicy` | Android 15 分钟、Apple 5 分钟的系统调度约束仍由各端提供 |
| 从唯一配对索引恢复身份 | `DeviceIdentityRules` | Keychain 读取/错误传播、UUID 生成、提交成功门禁 |
| 图文完整度、历史图片复用、清图墓碑及迟到缓存接纳 | `HookImageCachePolicy` | Swift 映射 Hook、组装资源描述、执行 WatchConnectivity 与文件操作 |
| Watch 前台代次、可达租约、ACK 与独立同步事实 | `WatchCommunicationPolicy` | 无符号纳秒位映射、系统通信与报告字典编码 |
| 主 LAN 图片候选、完整描述与引用资格 | `AssetTransferRules` | 原始对象按共享索引映射、缓存命中、同步／异步解码、实际请求与取消 |
| Watch 图片优先、精确分块、RPC 语义 | `WatchTransferRules`、`WatchProtocolRules` | Data / SHA-256 / Codable、真实 WCSession 调用与完成回调 |
| Watch 配置修订、撤销、去重、重签及缓存保留 | `WatchConfigurationPolicy` | UInt64 十进制映射、Keychain 事务、配置哈希及系统发布 |
| 图片磁盘淘汰、引用保护与预算更新 | `ImageCachePolicy` | 原生目录枚举、文件类型检查、删除和失败重试 |
| 图片像素、目标尺寸与动画解码预算 | `ImageDecodePolicy` | ImageIO / ImageDecoder、真实行字节、动画时序与播放 |
| Widget HTTP 期限、容量、端点、认证域与二进制字段边界 | `WidgetHttpPolicy` | 原生 HTTP、取消、JSON、Base64 与系统密码 API |
| 局域网地址文本、IPv4、scope 与已解析地址分类 | `WidgetEndpointRules` | 系统 IPv6 解析、Apple `.local` 及构造时小写化、Android 数值对端 |

`UsageDisplayPolicy` 返回原始数组的 Token / 额度索引，两个平台使用同一算法；不改写原始总量、统计质量、日期或缓存顺序。Cursor 默认零只属于展示投影。

名称只对比较键做 Unicode NFC 规范化（将规范等价编码转换为同一形式），Android 使用系统 Normalizer，Apple 使用 Foundation；`Café` 与分解形式能匹配，原始显示与编码字段保持原样。规范等价的重复名单/Token 名称会被拒绝，历史图也不会被误判成换 Agent。

Swift 的 `TokenNumber`、有实际消费的名称与额度属性保留为薄调用入口，内部已委托 Kotlin；只被测试使用的 `AgentDisplayPolicy`、`providerQuotaKey`、`WidgetTokens.displayRows` 等旧包装已删除，测试改为覆盖共享规则与生产投影。领域验证通过 `isValid()` 或结果对象进入 Swift，损坏输入不会以未声明 Kotlin 异常跨越语言边界。Swift `Int` 转 Kotlin `Int` 也处理超界，不能把超大版本号、槽位或比例转换成合法值。

身份恢复继续分阶段执行：已有稳定身份时不读配对索引；系统读取失败向上传递；明确缺失后才恢复或生成；写入成功后才返回有效身份。

HTTP 接纳仍比较包括代次在内的完整目标，并保护请求期间到达的新摘要。Android 的目标与摘要在同一个原子提交的二进制文件中，目标单独加密，缺少原记录不能接收；Apple 有独立目标文件，允许凭据存在且摘要缺失的合法恢复。

连接超时共同优先级为：配对窗口 → 阶段期限 → 实时入站静默 → 图片响应。60 秒配对、15 秒握手、3 秒收尾、45 秒入站租约、10 秒图片等待由公共层提供；平台仅执行选定动作。保留已有差异：Android 在认证确认写完后重新开始 15 秒首快照预算，iOS 继续沿用连接起点；iOS 图片超时还要求存在在途资源。共享预算不表示这些平台时机已经统一。

Watch 纳秒单调时间用高、低 32 位传递，Kotlin 内部保持 ULong；配置修订号用规范 u64 十进制传递，两者均不经 Double 或有符号 Long 截断。租约与事实状态不可变，Swift struct 副本继续持有原状态，后续 ACK 不会回改已捕获的事实。

能力表共用有界、UTF-8 字节和规范等价去重校验；共享规则不拥有已存 HTTP 授权。Android 生产入口先严格校验，坏表导致整份快照被拒绝，旧 Widget 目标不因此清除。Apple 前台先发起 Watch HTTP 撤销，再因坏表拒绝快照，App Group 旧目标保留；Apple 后台可接纳本身合法的快照，并以空目标进入提交、移除 App Group 旧目标。具体执行顺序见 [02 连接状态机](02-技术架构.md#连接状态机)。

## 文件分层

省略相同的 `kotlin/com/manonloki/lokimetrisdisplay/` 前缀：

```text
sharedLogic/src/
  commonMain/.../
    domain/          快照、Token、额度、面板配置及语义校验
    protocol/        发现、能力、阶段/超时、帧/写容量、Watch通信、Widget HTTP、JSON边界
    presentation/    Agent/用量行投影、数字格式、摘要裁剪、图片解码预算
    storage/         提交、身份恢复、租约、缓存接纳、图文历史、磁盘淘汰、Watch配置修订
  androidMain/.../
    connection/      NSD、Socket、唯一网络引擎
    storage/         系统偏好、Keystore、缓存、Android JSON 适配
    widget/          只读 HTTP、平台密码 API、文件编解码与提交
    nativebridge/    Rust JNI 包装
    protocol/        Android 系统 Unicode NFC 规范化适配
  appleMain/.../protocol/ Apple 系统 Unicode NFC 规范化适配
  commonTest/.../     同一业务用例在 JVM / iOS / watchOS 上验证
  androidHostTest/.../ Android/JVM 文件、HTTP、密码向量与存储验证

androidApp/src/main/.../
  MainActivity.kt     Android 入口
  application/       应用级引擎及投影订阅
  ui/                Compose 页面、用量、设置、动效
    platform/        图片、日期及系统设置适配
  service/           前台服务和通知
  overlay/           悬浮窗、拖动、切页
  widget/            系统小组件与后台调度

iosApp/              Apple 原生入口、界面和系统适配
appleDisplay/        Codable / Date / 图片 / 文件 / 传输等 Swift 适配及真实共享测试
scripts/
  build_apple_shared.py  Xcode 各目标按 SDK/架构生成框架，共用构建锁
  test_apple_shared.py   构建 macOS 框架后运行 Swift 测试
```

最初的物理目录调整保留 Kotlin 原包名、JNI 符号、Manifest 组件名、领域模型和本机持久化键。内部资源传输描述在最终筛查时统一为通用类型，两端调用同步更新，线格式与缓存字段不变。目录定位职责，尚不等于编译器强制的包级依赖隔离；以后若调整包 API，应单独验证这些对外接口。

## 构建与测试入口

Xcode 沿用 [Kotlin 官方 direct integration](https://kotlinlang.org/docs/multiplatform/multiplatform-direct-integration.html) 的 `embedAndSignAppleFrameworkForXcode`。三个目标通过标准库 Python 包装串行调用，避免同时更新相同框架目录；各目标保留独立 SDK、架构及配置。Watch 真机产物按当前架构组合为 fat framework（包含两种机器码的框架）。

```sh
./gradlew :sharedLogic:testAndroidHostTest :sharedLogic:iosSimulatorArm64Test :androidApp:assembleDebug
python3 scripts/test_apple_shared.py
```

Watch 公共测试使用 `./gradlew :sharedLogic:watchosSimulatorArm64Test --device <Watch模拟器UUID>`；需要本机已有可用 Watch 模拟器设备，只有 SDK/runtime 而没有设备时，Kotlin 插件可能报出误导的 SDK 错误。

第二条命令先生成 macOS SharedLogic，再将框架搜索及链接路径提供给 SwiftPM。它是本仓库的测试包装；直接运行 `swift test --package-path appleDisplay` 缺少这些框架构建与链接参数时不能替代该入口。Xcode 产品仍按需编译 Swift 源文件，未改为 package product 依赖。Android 打包另需项目固定签名与桌面 Rust 源码，详见 [README](../README.md#从源码运行)。

## 仍应留在平台或继续评估的部分

- Bonjour/NSD、Socket、HTTP 取消和系统任务负责实际执行；共享层输出决策，不接管已有单 owner 的线程状态。
- Keychain/Keystore、App Group 跨进程锁、文件保护、原子事务、ImageIO/ImageDecoder 和动图播放继续使用系统实现。
- Rust 密码协议、C/JNI 入口和平台 CryptoKit/JCA 适配继续保留。
- Swift Codable 外壳继续兼容既有 JSON 与缓存格式。统一序列化引擎应作为另一个变更单独验证，不能顺带改存量文件。
- WatchConnectivity 的分块、ACK 事实和前台租约规则已共享；真实 sendMessage、系统取消及后台完成回调仍在 Apple 适配层。
- TCP 分帧的长度、读块、累计容量、写队列上限和写超时规则已共享；原生字节累积与切片继续留平台，避免为了共用存储缓冲而复制整个网络载荷。
- 数字展示的单位策略由共享格式器显式区分：主面板与 Apple 小组件 K/M/B，Android 小组件 K/M/B/T/P/E；原 Android BigInteger 副本已删除，u64 最大值与 E 级舍入不使用浮点或可能溢出的余数乘法。
- Android `Drawable` 仍位于平台缓存和投影中；后续可将展示实例下移应用，数据层只返回已验证资源引用。

Android 只读目标要求认证 TCP 的数值 IP，Apple 目标还支持 `.local`。共同的数值地址与字节分类通过 `WidgetEndpointRules` 验证，系统解析和域名差异继续由平台处理。

独立 HTTP 目标会将认证连接得到的地址、端口和只读密钥持久化，不能把“配对记录不保存 IP”理解为全项目不保存地址。Apple 的 45 秒摘要租约用于抑制重复 HTTP：认证快照和 HTTP 新摘要均创建初始租约，主 App 心跳可续租；读取缓存不续租，组件也不据此证明实时在线。Watch 的前台与系统后台刷新窗口都可接受即时分块，后台执行资格仍由系统决定。

当前图片与 HTTP 的共用范围如下：

| 公共策略 | 实际消费者与规则 | 保留的既有差异 |
| --- | --- | --- |
| `ImageCachePolicy` | Android、iPhone、Watch：当前引用优先、最近复用排序、预算判断；删除成功后提交新的占用状态 | 三端以 512 MiB 为淘汰目标，Android/Watch 另以 512 文件为目标；当前引用全部保留，故可超过目标。删除失败不扣预算，下轮继续扫描 |
| `ImageDecodePolicy` | Android 目标尺寸、Apple 分帧预算与实测行字节缩边、共同 16,777,216 源像素限制 | Android/iPhone 目标边长 512、Watch 256；Apple 最多 512 帧及 iPhone 8 MiB/Watch 2 MiB 总解码预算；Android 沿用系统动画解码，不增加 Apple 帧预算 |
| `WidgetHttpPolicy` | Android Widget、iOS Widget、Watch：6 秒总期限、96 KiB 响应、固定端点与认证域、200/JSON/原 URL、增量容量、nonce/tag/密文边界及请求绑定 | 封闭的 Android/Apple 配置保留 Android 1024 字节请求与规范 Base64 限制；Apple 响应沿用 Foundation 可解码语义，密钥两端均要求规范编码 |

解码前只共享尺寸和容量事实，不搬运图片；HTTP 认证只桥接 12 字节 nonce 和固定小型附加认证数据，不跨语言复制整个响应。原生网络取消、重定向处理、流式回调及文件锁继续由原 owner 执行。发布节流、投影的线程投递和异常分类也保留在平台边界。

## 发布前共享层整理记录（2026-10-22，v1.0.5 基线）

以下五轮过程与验证结果保留为历史，不作为 `v1.0.6` 发布后本次核对的执行结果。仍适用的当前规则已列在上文；本机构建日志路径只是原始取证位置，未随文档一起提交，其他机器可能不存在。

### 第四轮旧实现与残留清理

- 删除已被公共规则取代的三端图片淘汰／解码计算，以及 HTTP 客户端和密码适配中的固定协议副本。
- 删除无生产消费者的 Kotlin `agentDisplayName`、`providerQuotaKey`、`canonicalAgentKey` 顶层转发、`TerminalTokens.displayAgents`、`TerminalUsageRow.isZeroDefaultProvider`；实际调用直接使用 `UsageDisplayPolicy` 与生产用量投影。
- 删除上述 Swift 测试专用包装；保留有真实生产调用、Codable 映射或系统执行职责的适配。
- 将只剩设备类别枚举的 `LanConnectionPolicy.swift` 更名为 `LanDeviceFormFactor.swift`，更新全部 Xcode 源文件引用。
- 删除本轮核实未使用的 6 个依赖别名、5 个版本声明及空 `commonMain.dependencies` 模板块；没有引入或升级依赖。
- 核实原 `sharedUI` 只剩 667 个生成文件后，移除 12,357,209 字节旧构建缓存与空目录。历史文档、Archify 图稿和本地验证记录保留。

新增代码先判断是否为“同一输入应得到相同业务结果”的规则；规则放 `commonMain`，系统调用和序列化适配留平台。没有实际消费者或构建隔离收益时，先用文件与目录组织，不新增构建模块。

### 第五轮最终筛查与收敛

本轮再次从 Android、iPhone／iPad、Watch、Widget 的生产调用、公共 API 引用及构建入口交叉筛查，完成最后几处收拢：

- `AssetTransferRules` 统一主 LAN 与 Watch 的完整图片描述／引用资格，以及主 LAN 待取资源索引。保持原清单顺序，Android 排除已解码／失败项，iOS 额外排除异步解码中的图片。缓存优先查找、Drawable 插槽实例、发送异常边界和下一块到达后再取消的时机保持原样。
- Watch 快照与图片复用同一有界精确块规则；快照仍限制 96 KiB，图片仍限制 32 MiB，超范围 UInt64 偏移在 Swift 转换时即被拒绝，不截断成合法偏移。
- `WidgetEndpointRules` 统一严格 IPv4、作用域标识和已解析地址字节分类，不另写 IPv6 解析器。保留 Apple `.local`／尾点与构造时小写化、Android 仅数值且已小写、两端系统解析器的已有语法差异。
- 删除 `WidgetSnapshotStore.saveRefreshTarget`、无条件 `save`、Android `clearListener` 和无消费的 Hook 校验便利入口。正常测试改走真实认证提交；专测两个原子文件间中断的盘面由测试夹具构造。
- Bonjour 域实际使用已有共享常量；删除全注释 ProGuard 模板及其构建引用，保持原有关闭代码压缩的配置。修正业务需求文档中的旧策略名。

继续保留的代码均有实际职责：原生 UI／布局／动画、系统网络／调度、密钥库、文件锁和事务、JSON／Swift Codable 映射、系统图片解码及 Rust 密码核心。Android 独有的最新意图槽处理有界命令队列，Swift 直接使用串行队列；两者调度语义不同，不能为了共用而替换。Android 旧快照迁移清理及现有缓存格式解码仍服务已安装版本，历史文件和升级兼容路径也不属于无用实现。

Android Drawable 从平台数据投影下移到应用是可选的分层调整；它没有剩余的跨平台业务算法，不作为本轮未完成提取。Swift 叶子校验中仍有测试使用的错误适配，不增加第二份算法，也不为移除这些入口而扩大模型重写。

**当时的收敛结论**：那轮审计在已检查的生产调用范围内未发现需继续上提的重复业务规则，已处理发现的无消费者入口。这是当次代码复核结论，不保证后续代码或所有执行路径不存在重复与缺陷；新增功能继续按实际复用需求决定公共边界。

| 最终检查 | 结果 |
| --- | --- |
| Android/JVM 公共规则与平台边界 | 149 项通过 |
| iOS ARM64 模拟器公共规则 | 133 项通过 |
| Watch ARM64 模拟器公共规则 | 同一组 133 项通过 |
| 真实 macOS SharedLogic 链接的 Swift 集成测试 | 167 项通过 |
| Android Debug 包 | 构建通过 |
| iOS 真机／模拟器、Watch 两种真机架构、macOS 共享框架 | 编译／链接通过 |
| Xcode 主 App、Widget、Watch 模拟器完整构建 | `BUILD SUCCEEDED` |
| 独立代码复核 | 图片顺序／引用／取消时机、分块偏移、地址接纳集合及平台字节映射均未发现可行动回归 |
| 文档链接、Python 语法、PBX 格式与 `git diff --check` | 通过，121 个本地文档链接有效 |

最终测试均 0 失败、0 跳过。Swift 首次测试发现两处测试迁移假设与既有行为不符：系统可以接纳某些带前导零的 mapped IPv6 文本，合法认证事务也可以安全移除目标符号链接并重建普通文件。已修正测试以验证系统解析边界，以及 HTTP 失败／认证修复／外部文件与摘要保护；生产接纳规则未因此修改，随后全量通过。

日志：`build/shared-final-audit-gradle.log`、`build/shared-final-audit-watch.log`、`build/shared-final-audit-swift.log`、`build/shared-final-audit-xcode.log`。测试临时 Watch 已关闭、删除并通过设备 JSON 核实不存在，回执为 `build/shared-final-audit-watch-cleanup.json`。

README 与 `01`、`02`、`03`、`07` 及本文已同步核对。Android 仍为 `1.0.5 (7)`、Apple 为 `1.0.5 (13)`；桌面 Rust 提交核实仍为 `94ed1b2f0624a66f3c1fffdd8a452fe515397c10`，复用现有本机 native 产物。未新增依赖、改变存储格式或发布版本。本轮未执行实体设备与真实局域网回归、模拟器 UI 冒烟、Release 签名归档，以及包体／内存／耗电测量；前轮证据保留原适用范围。

### 第四轮验证与限制（历史记录）

| 检查 | 结果 |
| --- | --- |
| Android/JVM 公共规则与平台边界 | 139 项通过 |
| iOS ARM64 模拟器公共规则 | 124 项通过 |
| Watch ARM64 模拟器公共规则 | 同一组 124 项通过 |
| 真实 macOS 框架链接的 Swift 集成测试 | 162 项通过，含真实文件删除失败后相同引用集重试 |
| Android Debug 包 | 构建通过 |
| iOS 真机／模拟器、Watch 两种真机架构、macOS 共享框架 | 编译／链接通过 |
| Xcode 主 App、Widget、Watch 模拟器完整构建 | `BUILD SUCCEEDED` |
| 独立代码复核 | 未发现可行动回归；核对引用保护、删除失败、整数边界、解码行字节、HTTP 取消与平台差异 |
| 文档链接、Python 语法、PBX 格式与 `git diff --check` | 通过 |

所有测试均 0 失败、0 跳过。Swift 测试首次遇到额度模型同名导入歧义，改为只导入所需共享策略后全量通过；生产 Apple 构建也已通过。最终日志在 `build/shared-cleanup-gradle.log`、`build/shared-cleanup-watch.log`、`build/shared-cleanup-swift.log`、`build/shared-cleanup-xcode.log`。测试用临时 Watch 已关闭、删除并核实不存在。

README 以及 `01`、`02`、`07`、本文已按实际消费者和删除项核对；历史记录保留。版本仍为 Android `1.0.5 (7)`、Apple `1.0.5 (13)`，没有新增依赖、修改存储格式或做发布。本轮未执行实体设备与真实局域网配对回归，也未重复模拟器 UI 冒烟、Release 体积、内存或耗电测量；前轮相应证据仍只适用于当时产物。

### 第三轮验证与限制（历史记录）

| 检查 | 结果 |
| --- | --- |
| Android/JVM 公共规则与平台边界 | 123 项通过 |
| iOS ARM64 模拟器公共规则 | 109 项通过 |
| Watch ARM64 模拟器公共规则 | 同一组 109 项通过 |
| 真实 macOS 框架链接的 Swift 集成测试 | 158 项通过 |
| Android Debug 包、iOS 真机/模拟器与 Watch 双真机架构框架 | 编译/链接通过 |
| Xcode 主 App、Widget、Watch 模拟器完整构建 | `BUILD SUCCEEDED` |
| 独立代码复核 | 未发现本轮可行动回归；核对全 u64 范围、Swift 值复制、撤销与迟到响应、末块和失败清理 |

所有测试均 0 失败、0 跳过。日志在 `build/public-policy-gradle.log`、`build/public-policy-watch.log`、`build/public-policy-swift.log`、`build/public-policy-xcode.log`。测试用临时 Watch 已关闭、删除并确认不存在。本轮没有重复真机或模拟器 UI 冒烟；第二轮的冷启动证据仍属于当时产物。

版本保持 Android `1.0.5 (7)`、Apple `1.0.5 (13)`；未新增依赖、改密码协议、做发布或实体设备回归。此前 Debug 动态库体积记录见下一节，只对应第二轮产物，本轮未重新测量 Release 体积、内存或耗电。README 和架构文档已同步新增共享范围。

### 第二轮验证与限制（历史记录）

第二轮最终源码验证：

| 检查 | 结果 |
| --- | --- |
| Android/JVM 共同规则与平台边界 | 97 项通过，0 失败／跳过 |
| iOS ARM64 模拟器公共规则 | 83 项通过，含 Unicode NFC 与完整 u64 边界 |
| watchOS ARM64 模拟器公共规则 | 同一组 83 项通过，临时 Watch 设备显式选择运行 |
| `python3 scripts/test_apple_shared.py` | 154 项 Swift 测试通过，真实链接最终 macOS SharedLogic |
| Android Debug 完整包 | 构建通过 |
| iOS 真机及模拟器、Watch 两种真机架构、macOS 共享框架 | 最终源码编译／链接通过 |
| Xcode iOS + Widget + Watch 模拟器完整构建 | `BUILD SUCCEEDED`，核实各 target 的实际框架链接 |
| 独立代码复核 | 发现并修复 Unicode 规范等价回归；数字单位迁移另对照 100,418 个有效 u64 输入，结果一致 |
| Watch 最终 App 冷启动 | 版本 `1.0.5 (13)` 启动并持续存活，显示等待 iPhone 同步；未发现 Kotlin / uncaught / fatal 异常 |
| 文档链接、Python 语法、PBX 格式与 `git diff --check` | 通过 |

最终日志：`build/shared-business-final-gradle.log`、`build/shared-business-final-swift.log`、`build/shared-business-final-xcode.log`。Watch 测试首次因只有 SDK/runtime 而无设备失败，创建临时设备后成功；未下载或升级 SDK。最终 App 冒烟证据位于 `build/watch-shared-smoke/`，临时 Watch 已关闭、删除并核实不存在。

第二轮仍为结构优化，版本保持 Android `1.0.5 (7)`、Apple `1.0.5 (13)`。桌面 Rust 基线仍为 `94ed1b2f0624a66f3c1fffdd8a452fe515397c10`，构建复用本机 Rust 产物；未更改密码协议或做发布。

新增 Kotlin 运行时有实际二进制成本。相对第一轮，模拟器 Debug 动态库的 arm64 切片大小变化如下（只比较动态库机器码切片，不代表最终安装包、Release 大小或运行内存）：

| 目标 | 第一轮字节 | 第二轮字节 | 增量 |
| --- | ---: | ---: | ---: |
| iOS主App | 15,693,968 | 15,881,728 | +0.18 MiB |
| Widget | 2,347,104 | 5,382,032 | +2.89 MiB |
| Watch | 3,138,856 | 6,199,256 | +2.92 MiB |

原始记录在 `build/shared-business-baseline.json` 和 `build/shared-business-binary-sizes.json`。Release 体积、峰值内存、耗电和真机后台预算尚未测量；此轮不宣称性能收益。

尚未执行实体 Android / iPhone / Watch 安装与真实局域网配对回归。README 与 `01`、`02`、`07` 已按最终共享范围和测试入口同步；`04` 与下方第一轮记录作为历史保留。Archify 图稿未重新生成，文字已说明其旧依赖基线。


### 第一轮验证（历史记录）

此项为代码结构优化，未变更版本、创建发布标签或发布安装包。Android 配置仍为 `1.0.5 (7)`，Apple 配置仍为 `1.0.5 (13)`；它们的构建号独立。

已执行：

| 检查 | 结果 |
| --- | --- |
| `:sharedLogic:testAndroidHostTest` | 69 项通过（含公共规则和 Android/JVM 边界） |
| `:sharedLogic:iosSimulatorArm64Test` | 55 项公共规则测试通过 |
| `:sharedLogic:linkDebugFrameworkIosSimulatorArm64` | 框架生成通过，已检查 Swift 导出签名 |
| `:androidApp:compileDebugKotlin`、`:androidApp:assembleDebug` | 完整 Android Debug 构建通过 |
| `swift test --package-path appleDisplay` | 153 项通过；原 Swift 连接策略测试已由公共 Kotlin 测试替代 |
| `xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` | 主 App、嵌入 Watch 和 Widget 三个目标均通过 |
| 独立代码复核、`git diff --check` | 未发现可行动回归；格式检查通过 |

本轮 Android 构建使用默认桌面源码路径，Rust 工作区提交为 `94ed1b2f0624a66f3c1fffdd8a452fe515397c10`；Android native 构建任务复用现有产物，未强制清理重编 Rust。Gradle 完整包及 Native 测试日志在 `build/kmp-refactor-gradle.log`，Xcode 日志在 `build/kmp-refactor-xcode.log`（均为本地构建记录）。

尚未执行实体 Android / iPhone / Watch 安装、真实局域网配对回归或 Release 签名归档；本轮不声称获得包体、内存、耗电或启动时间改善。

README 已核对安装与启动命令、现有能力、设备最低系统、文件结构和源码依赖，结构说明已更新，运行命令与支持范围保持原配置；`01`、`02`、`07` 同步当前边界，`04` 保留历史观察并注明变化。既有 Archify HTML 是重构前生成的图稿，本轮只修正文档入口与源码链接，未重新生成图稿。

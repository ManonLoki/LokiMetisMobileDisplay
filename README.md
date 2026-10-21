# LokiMetrisDisplay

This is a Kotlin Multiplatform project targeting Android, iOS.

* [/iosApp](./iosApp/iosApp) contains an iOS application. Even if you’re sharing your UI with Compose Multiplatform,
  you need this entry point for your iOS app. This is also where you should add SwiftUI code for your project.

* [/sharedLogic](./sharedLogic/src) is for the code that will be shared between app targets in the project.
  The most important subfolder is [commonMain](./sharedLogic/src/commonMain/kotlin). If preferred, you
  can add code to the platform-specific folders here too.

* [/sharedUI](./sharedUI/src) is for code that will be shared across your Compose Multiplatform applications.
  It contains several subfolders:
  - [commonMain](./sharedUI/src/commonMain/kotlin) is for code that’s common for all targets.
  - Other folders are for Kotlin code that will be compiled for only the platform indicated in the folder name.
    For example, if you want to use Apple’s CoreCrypto for the iOS part of your Kotlin app,
    the [iosMain](./sharedUI/src/iosMain/kotlin) folder would be the right place for such calls.
    Similarly, if you want to edit the Desktop (JVM) specific part, the [jvmMain](./sharedUI/src/jvmMain/kotlin)
    folder is the appropriate location.

### 菜单与面板

- **展示台**：导航入口统一命名为“展示台”，内容区不显示页面标题、连接／缓存状态栏或自定义按钮；面板配置统一从设置进入。用量与 Hooks 图文平分可用内容区，竖屏上下各半、横屏左右各半，不再显示槽位统计摘要或外层 Hooks 标题；断开、进入后台、切换桌面或重启后清空Token与Hooks，等待当前连接的新快照。连接与配对入口保留在设置中。
- **设置**：使用低对比石墨分组、青色选中态和统一图标；Token 与 Hooks 的开关和显示选项各自归组，精简／详细和 1×1／2×2 带布局示意并即时保存。桌面连接集中展示发现、配对与连接状态，本机名称独立编辑、修改后显示保存按钮，设备信息折叠收纳。iOS 的 Watch 与小组件说明也收在此处，iOS 在无障碍字号下将选择项纵向排列。
- 用量支持**精简**与**详细**。Token 与 Hooks 各占一半可用内容区，不再选择 1×1／2×2 卡片尺寸；只开启一个模块时占满内容区。两块内容独立滚动。Hooks 可独立选择 **1×1／2×2**：1×1 每页一张，图片使用标题和状态下方全部剩余空间；2×2 将 Hooks 区域等分成四张卡片，不足四张保留空位，超过四张按每页四张左右分页。卡片仅显示标题、状态与图片，点击可查看完整正文和图片；图片按比例完整显示。Token 主数字使用 K／M／B 近似值（最多两位小数），下方小字保留完整整数并紧邻统计质量；精简款根据卡片可用宽高放大总量并居中展示，详细款自适应总量、间距与 Agent 明细排版，窄卡片或大字体下明细自动换行，内容较多仍可滚动。日期收在卡头，时区位于详细模式明细区首行；Agent 类型名称加粗放大，完整数字与统计质量在对应简化数字下方右对齐。显示配置保存在本机，卡片可全部关闭。
- 手机使用底部导航；Android 宽屏使用侧栏和双栏设置，iPad 使用侧栏与多列展示台。Hooks 图片随卡片剩余空间伸展，点击可查看详情。Watch 采用独立速览与设置页，小组件按系统尺寸组织最近一次同步的摘要与时间。采用深色赛博主题：冷青与紫色光边、细网格、局部扫光、分层入场和数值更新过渡。手机保留原生触控反馈，平板增加悬停反馈；Watch 仅使用短促入场与更新反馈，小组件保持静态光边。持续装饰动画受前台、页面及滚动可见性控制，响应系统减弱动态效果／禁用动画设置。
- 发现随前台生命周期自动运行，无开启/停止开关。首次配对仍需用户选择桌面；已保存的配对可自动认证重连。后台暂停，回到前台恢复，切换菜单不会重新配对。

### iOS 局域网接线

iPhone在前台自动浏览桌面`_loki-host._tcp.local.`服务，在手机设置中选择桌面。首次选择候选时手机显示四位码，桌面自动弹出配对窗口供用户输入。候选广告没有授信作用；共享Rust验证、真实Keychain保存和ACK完成后，手机另开TCP认证，收到首个真实snapshot才显示已连接。

`LanLinkEngine`串行拥有Network浏览/连接、一个共享密码桥、Keychain及图片接收。窗口内的socket重试不重开四位码或返还次数；密码窗口60秒/5次由共享Rust唯一控制。进入后台尽力发送pause后关闭，前台自动重新发现和认证，无需开启发现。网络重试最多8次，真正前台恢复/目标新广告可开启新一轮。切菜单与保存名称不启停网络。

App主线程只接收最新投影，写队列最多8帧；坏帧、认证失败或半写失败关闭socket，不跳过已经消耗的加密序号。Keychain失败不发送ACK；单边保存后仍支持“忘记”再重新配对。当前可见的名字来自发现广告，UUID/信任及在线结果以认证连接为准。

Token与Hooks只存在当前认证连接的内存中，不保存或恢复历史展示快照；升级时精确清理旧`DisplayCache/display-lan-v1.json`。图片只按内容哈希保存在私有`lan-assets-v1`，逐16KiB块由共享Rust验证，最后同步磁盘并重新核验，再原子提交；缓存命中不请求正文。只下载当前Hook实际引用的图片，保留当前引用并按复用时间收敛到512MiB，启动精确回收上次崩溃的部分文件。图片支持 BMP、PNG、JPEG、WebP、GIF。后台 ImageIO 解码保留 GIF、动态 PNG、动态 WebP 的帧时长与循环次数；展示边长最多512像素，原图最多16MP、动画最多512帧、每图已解码帧最多8MiB，超限明确提示。

本次 iOS 模拟器完整 App 构建通过，已检查面板配置和既有真实缓存的展示。Swift 测试覆盖自动发现、后台恢复、五格式解码、动画时长与资源边界；不把这些检查等同于新的桌面到手机配对互通验收。

### Android 局域网接线

`DisplayApplication`持有一个串行`AndroidLanEngine`，`MainActivity`只订阅投影和申请权限。旋转屏幕、菜单切换和保存名称不重开密码窗口；真实进入后台时尽力发送加密pause并关闭连接。首次进入前台自动发现，系统本地网络权限满足后继续浏览。设备ID和名称沿用原`mdns_identity`位置，损坏身份失败关闭。

手机主动浏览桌面`_loki-host._tcp.local.`；旧的只能接受后立即关闭的广播owner已移除。API34及以上持续订阅服务信息，旧版一次只做一个解析并定期刷新；只在前台发现期间持有旧系统需要的多播锁。临时地址来自实际SRV结果，不持久化IP；TXT不授信。局域网的访客隔离、VPN和系统权限可能影响发现。[NSD官方合同](https://developer.android.com/reference/android/net/nsd/NsdManager)（2026-10-21核对）。

显式选择才开启共享Rust配对窗口；Keystore加密的私有记录同步提交成功、且commit仍有效后才发送ACK。SharedPreferences提交失败也会更新其系统内存，因此应用只发布已成功提交的权威映射，下一次写入完整映射，防止失败保存/忘记改变信任。新TCP认证、裸DeviceInfo、加密心跳与完整快照沿用桌面协议。最多8次传输重试，不重置密码预算。

完整快照只保留在当前连接内存，断开/后台/换目标立即清空，启动精确清理旧`lan-display-v1.json`及其`.new/.bak`，配对凭据保留。图片按摘要保存在`lan-assets-v1`。每次复用和落盘完成均由Rust核验真实正文，AtomicFile静默提交失败也必须读回发现并清理部分文件。当前Hook引用优先保留，其余缓存收敛到512MiB/512文件。后台使用系统 ImageDecoder 解码最多512像素的图片，原图最多16MP；原生 Drawable 保留 GIF/WebP 动画，离开面板或进入后台停止播放。网络及缓存JSON进入系统解析器前检查严格语法与64层深度上限。

Android APK 构建与共享宿主测试通过。模拟器检查覆盖两菜单、显示偏好持久化、横竖屏等分、精简/详细、独立滚动与模块开关；这些属于本次 UI 回归，不替代真实桌面配对互通验收。

### 手机与平板类型上报

Android在应用级owner创建时读取系统最小宽度配置（≥600dp为平板尺寸类，未知配置不报告）；iOS在主线程从UIKit取得phone/pad类别。名称和页面宽度不参与类型选择。每条认证连接只有收到实时snapshot的`deviceFormFactorV1`能力后，才发一次`deviceFormFactor`报告；旧桌面无能力时不发，缓存不能启用能力，重新连接重新协商。桌面未取得报告时使用中性图标。Android尺寸类别不能保证所有折叠/桌面窗口模式的物理形态识别。

形态协商的Kotlin测试3项、Swift类型与既有Watch能力回归14项通过；未据此声明新包安装或平板真机互通通过。

### Apple Watch配套接线

同一Xcode工程包含现代单target `LokiMetrisWatch`，随iPhone宿主嵌入；Watch本身不链接Kotlin/Rust，也不创建独立LAN服务。应用提供面板和设置，配套同步入口整合在设置中，面板可分别开关用量与 Hooks，并选择精简或详细用量。稳定安装UUID与名称保存在Watch私有不备份目录。系统Watch配对与桌面四位码各自独立；Watch使用已经配对的iPhone中转。

`PhoneWatchBridge`只接收iPhone LAN owner已完整验证的快照和图片路径。两端保持前台时，`sendMessageData`按16KiB块逐块确认，单RPC最多32KiB；只有完整摘要与语义验证通过并接纳到当前前台内存后才确认同步，Token与Hooks不再落盘，启动精确清理旧`watch-display-v1.json`。相同图片摘要可直接复用，Watch缩略图限制256像素，当前显示静态图片。完整Token日期、数字/质量及Hooks图文只来自当前桌面连接。失去前台、RPC超时、配套不可达或手机LAN失效通知后清空旧投影，并撤销旧接收代次；图片文件继续按摘要复用。

Watch每次进入active产生独立前台UUID；inactive或后台立即撤销，旧请求不能恢复。iPhone的TCP/IP、WC激活、isReachable都不替代手表实际回复。大图的每个有效块回执续通信租约，只有完整快照确认才更新最近同步；缓存命中只表示核验。两端各只允许一个物理请求在途，超时等系统终态，不创建后台context/file传输队列。iPhone到Watch可能走系统蓝牙或Wi-Fi；不保证息屏更新，也不启用APNs。

当前已完成移动源码与桌面独立Watch状态投影接线；只有实时认证快照广告watchCompanionV1后，手机才上送无IP的Watch回执事实，并引用桌面心跳作保守时间锚。相同ACK序号不能续期，父连接撤销会立即撤销手表可达。两端完整图文互通仍待运行验证。运行Watch开发目标可使用Xcode同名scheme；独立构建命令为`xcodebuild -project iosApp/iosApp.xcodeproj -target LokiMetrisWatch -configuration Debug -sdk watchsimulator CODE_SIGNING_ALLOWED=NO build`。不要把独立Watch构建或空态交互当作桌面到手表的完整E2E通过。

### iOS 桌面与锁屏小组件

`iosApp`工程包含独立的`LokiMetrisWidgets`扩展，支持桌面小号/中号和锁屏单行/圆形/矩形。安装后先启动App，再在系统小组件列表添加“诡秘神谕”。常亮显示由设备和系统决定；组件优先读取最近一次合法本地摘要，系统唤醒Timeline时可独立通过HTTP向已配对桌面拉取；断连、后台和重新启动后保留，并标明“上次同步”与统计日期；切换桌面或忘记当前配对时清除。Timeline使用`.after`申请约5分钟后再次执行，前台同步与App后台认证短时拉取继续保留；实际执行可能明显晚于申请时间；电脑需在线且局域网可达，不保证息屏实时更新，也不启用云推送或组件长连接。[WidgetKit刷新规则](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)（2026-10-21核对）。

App与扩展的entitlements及Info.plist引用`Configuration/Config.xcconfig`中的同一`LOKI_WIDGET_APP_GROUP`。使用实际Apple开发团队签名时，需要该团队的App ID/扩展ID与App Group权限一致；当前没有代用户注册或修改开发者账号。共享容器不可用、首次尚未同步或文件损坏时，组件显示真实空态，不回退普通偏好存储。

共享快照只保存来源UUID、接收时间、Token日期/十进制数字/质量和Hooks四态摘要；另一个有界文件保存Widget专用只读密钥、当前服务地址及代次，不共享长期配对密钥、Hook正文/图片或宿主路径。共享格式schema 2保留45秒连接租约，认证心跳才续期；组件作为上次同步结果读取，租约过期不删除摘要，旧格式、损坏或未来时间均显示空态。Timeline不再预排45秒后的空条目。失效请求和待发布快照共用最新待办槽，明确清除意图不会被暂停请求覆盖，写入失败会披露。`LanLinkEngine`只把成功`open`且通过完整展示解析的snapshot交给单一后台组件发布器；中间消息与主线程投递都只保留最新一份。正文仅在当前会话内存，图片在App私有目录，App Group包含最近一次摘要与独立读取配置；主App不从共享文件恢复Token或状态。iOS网络owner已接入，完整模拟器 App 构建通过；没有将空态或测试夹具当作已连接。

后台刷新使用 `BGAppRefreshTask`，任务标识为 `com.manonloki.lokimetrisdisplay.widget-refresh`。App 启动即注册，进入后台或每次任务开始时申请下一次刷新；15 分钟仅为最早执行时间，实际唤醒可能明显更晚。系统禁用后台刷新时不强行运行。任务复用唯一 LAN owner，使用最近一次成功认证桌面的 Bonjour 服务名重新解析地址，读取已有配对并完成加密认证；仅接收一份快照、写入 App Group 并请求组件刷新后结束，不下载图片、不同步 Watch、不在后台开启配对或持续重试。25 秒本地超时和系统 expiration 都会撤销连接代次；前台接管优先。离线或失败保留上次摘要，任务完成成功必须等待共享文件实际提交，不能仅以接收消息宣告成功。[后台任务配置](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app)。

配对秘密仍仅在 App 私有、不同步的 Keychain 中；访问级别为 `AfterFirstUnlockThisDeviceOnly`，已有 `WhenUnlockedThisDeviceOnly` 记录在前台逐条验证双端身份后迁移，只修改访问属性，保留秘密原字节。设备重启后需先解锁一次才能锁屏认证。后台目标只保存来源 UUID 与 Bonjour 服务名/类型/本地域，不保存固定 IP、配对秘密或完整快照，按设备身份隔离、首次解锁后可读并排除备份；换桌面或忘记配对时撤销旧目标，损坏元数据可在显式选择时精确清理。组件不读取配对秘密。新版桌面在认证快照中提供`widgetHttpV1`及`widgetEndpoint {version,port,key}`，手机将系统实际连接的对端地址与该端口组合，每次认证同步后更新；旧桌面缺少能力时清除独立读取配置，保留App原有同步。Widget每次Timeline执行只发起一次固定路径`POST /api/widget/v1/snapshot`，6秒总超时、有界响应、拒绝重定向。使用独立派生32字节密钥及ChaCha20-Poly1305加密请求/响应，响应绑定本次随机nonce与来源UUID；桌面在当前账本验证权限后短暂唤醒统计发布器，响应不含Hook正文或图片。离线/超时/坏响应不改变上次同步时间。共享文件锁保证换桌面、忘记配对和服务地址换代之后，旧在途响应不能写回；较新App摘要也不能被旧HTTP请求或心跳覆盖。[Keychain 可访问性](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)。

`appleDisplay`使用SwiftPM运行共享投影/缓存的隔离单元测试，零第三方依赖。App与扩展直接编译该目录同一份Swift源码；扩展不链接Kotlin/Rust。开发测试：`swift test --package-path appleDisplay`。iPhone上的桌面组件与后台保留已实机验证；系统自然调度的后台唤醒间隔、锁屏遮蔽和实际常亮由系统与设备决定，不能从调试触发推断准点更新。

### Running the apps

Android、iOS 与 Apple Watch 统一使用桌面版的黑金眼睛图标。原始母版保存在 `branding/app-icon.png`；在 macOS 仓库根目录运行 `swift scripts/generate_app_icons.swift` 可重新生成各端资源，仅使用系统 SDK，不需要桌面仓库或第三方图像工具。Watch 使用独立的资源目录，并由同一 Xcode 工程编译图标。

Use the run configurations provided by the run widget in your IDE's toolbar. You can also use these commands and options:

- Android app: `./gradlew :androidApp:assembleDebug`
- iOS app: open the [/iosApp](./iosApp) directory in Xcode and run it from there.

### Running tests

Use the run button in your IDE's editor gutter, or run tests using Gradle tasks:

- Android tests: `./gradlew :sharedUI:testAndroidHostTest :sharedLogic:testAndroidHostTest`
- iOS tests: `./gradlew :sharedLogic:iosSimulatorArm64Test`

广播协议测试覆盖桌面端要求的服务类型、TXT 字段、UUID 格式，以及中文／emoji 名称的 UTF-8 长度和控制字符边界。

---

Learn more about [Kotlin Multiplatform](https://www.jetbrains.com/help/kotlin-multiplatform-dev/get-started.html)…

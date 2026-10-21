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
- 用量支持**精简**与**详细**。Token 与 Hooks 各占一半可用内容区，不再选择 1×1／2×2 卡片尺寸；只开启一个模块时占满内容区。两块内容独立滚动。Hooks 可独立选择 **1×1／2×2**：1×1 每页一张，图片使用标题和状态下方全部剩余空间；2×2 将 Hooks 区域等分成四张卡片，不足四张保留空位，超过四张按每页四张左右分页。卡片仅显示标题、状态与图片，点击可查看完整正文和图片；图片按比例完整显示。Token 主数字使用 K／M／B 近似值（最多两位小数），下方小字保留完整整数；精简款根据卡片可用宽高放大总量并居中展示，详细款自适应总量、间距与 Agent 明细排版，窄卡片或大字体下明细自动换行，内容较多仍可滚动。日期收在卡头，时区位于详细模式明细区首行；Agent 类型名称加粗放大，完整数字在对应简化数字下方右对齐。显示配置保存在本机，卡片可全部关闭。
- 手机使用底部导航；Android 宽屏使用侧栏和双栏设置，iPad 使用侧栏与多列展示台。Hooks 图片随卡片剩余空间伸展，点击可查看详情。Watch 采用独立速览与设置页，小组件按系统尺寸组织最近一次同步的摘要与时间。采用深色赛博主题：冷青与紫色光边、细网格、局部扫光、分层入场和数值更新过渡。手机保留原生触控反馈，平板增加悬停反馈；Watch 仅使用短促入场与更新反馈，小组件保持静态光边。持续装饰动画受前台、页面及滚动可见性控制，响应系统减弱动态效果／禁用动画设置。
- 发现随前台生命周期自动运行，无开启/停止开关。首次配对仍需用户选择桌面；已保存的配对可自动认证重连。后台暂停，回到前台恢复，切换菜单不会重新配对。

### 配对身份、备份与重装

iOS 将本机 UUID 与配对秘密分别保存在本机私有 Keychain，均不同步。已有 `Discovery/device-id` UUID 原值迁移；卸载后旧文件缺失时，只在旧配对记录归属于唯一合法本机身份时恢复，不按名称、IP 或时间猜测，也不改绑原密钥。多组身份、冲突、损坏或钥匙串不可访问时明确报错。Keychain 跨卸载保留是系统现有行为，不能代替备份，也不承诺抹机、换设备或签名访问组变化后仍可自动连接。

Android 与 iOS 的设置均提供“配对备份与恢复”。卸载前导出加密 JSON 文件，并单独保管随机 256 位恢复码；重装后选择文件、输入恢复码、核对设备 ID 和桌面配对数量，再确认恢复。包只含原 UUID 及成对配对材料，不含 Token、Hooks 正文、图片、网络地址、组件或手表只读配置。两移动平台使用同一带版本的 AES-256-GCM 格式、固定域 AAD，拒绝篡改、错误恢复码、重复身份和越界记录。文件与恢复码共同持有即可恢复授权，应分开妥善保管。

恢复仅允许没有不同配对的安装，不能静默覆盖现有信任。导入先停旧网络 owner，再提交持久化事务，成功后重新建立连接；Android 用新 Keystore 密钥重新加密，未完成事务在启动时先回放；iOS 只有完整材料读回验证后才提交身份，中断后可重新导入同一个包继续。恢复旧备份可能包含后来忘记的配对；对端已撤销的秘密仍不能通过认证。Android 系统备份不携带设备 UUID 或无法跨卸载解密的配对密文。

Android Debug 和 Release 均使用项目 `signing/` 中的固定签名；本机已将原开发证书保存到项目，保持现有签名兼容。私钥与随机密码文件被 Git 忽略，公开证书可以核对；换电脑需安全迁移原签名文件。首次配置及生成选项见 [签名说明](signing/README.md)。签名一致支持保留数据的覆盖安装；真正卸载后仍需要配对恢复文件，固定签名不能恢复已删除的 Keystore 密钥。

2026-10-21 验证：Android 54 项共享宿主测试（含7项恢复专项）、Apple 16项身份／恢复专项通过，Android Debug／Release 签名 APK 和 iOS／Watch 模拟器构建通过。两种 APK 的证书与原开发 APK 一致；跨移动端固定密码向量一致。中断回放使用临时目录与合成材料测试，未卸载真实设备应用、导入真实用户配对或宣称实机恢复验收通过。桌面正式／测试实例区分及其独立加密账本恢复已在桌面仓库实现，桌面恢复文件与移动端文件按角色区分。

### iOS 局域网接线

iPhone在前台自动浏览桌面`_loki-host._tcp.local.`服务，在手机设置中选择桌面。首次选择候选时手机显示四位码，桌面自动弹出配对窗口供用户输入。候选广告没有授信作用；共享Rust验证、真实Keychain保存和ACK完成后，手机另开TCP认证，收到首个真实snapshot才显示已连接。

`LanLinkEngine`串行拥有Network浏览/连接、一个共享密码桥、Keychain及图片接收。窗口内的socket重试不重开四位码或返还次数；密码窗口60秒/5次由共享Rust唯一控制。进入后台尽力发送pause后关闭，前台自动重新发现和认证，无需开启发现。网络重试最多8次，真正前台恢复/目标新广告可开启新一轮。切菜单与保存名称不启停网络。

App主线程只接收最新投影，写队列最多8帧；坏帧、认证失败或半写失败关闭socket，不跳过已经消耗的加密序号。Keychain失败不发送ACK；单边保存后仍支持“忘记”再重新配对。当前可见的名字来自发现广告，UUID/信任及在线结果以认证连接为准。

Token与Hooks只存在当前认证连接的内存中，不保存或恢复历史展示快照；升级时精确清理旧`DisplayCache/display-lan-v1.json`。图片只按内容哈希保存在私有`lan-assets-v1`，逐16KiB块由共享Rust验证，最后同步磁盘并重新核验，再原子提交；缓存命中不请求正文。只下载当前Hook实际引用的图片，保留当前引用并按复用时间收敛到512MiB，启动精确回收上次崩溃的部分文件。图片支持 BMP、PNG、JPEG、WebP、GIF。后台 ImageIO 解码保留 GIF、动态 PNG、动态 WebP 的帧时长与循环次数；展示边长最多512像素，原图最多16MP、动画最多512帧、每图已解码帧最多8MiB，超限明确提示。

本次 iOS 模拟器完整 App 构建通过，已检查面板配置和既有真实缓存的展示。Swift 测试覆盖自动发现、后台恢复、五格式解码、动画时长与资源边界；不把这些检查等同于新的桌面到手机配对互通验收。

### Android 局域网接线

`DisplayApplication`持有一个串行`AndroidLanEngine`，`MainActivity`只订阅投影和申请权限。旋转屏幕、菜单切换和保存名称不重开密码窗口；未开启后台实时同步时，真实进入后台尽力发送加密pause并关闭连接。首次进入前台自动发现，系统本地网络权限满足后继续浏览。设备ID和名称沿用原`mdns_identity`位置，损坏身份失败关闭。

手机主动浏览桌面`_loki-host._tcp.local.`；旧的只能接受后立即关闭的广播owner已移除。API34及以上持续订阅服务信息，旧版一次只做一个解析并定期刷新；只在前台发现期间持有旧系统需要的多播锁。临时地址来自实际SRV结果，不持久化IP；TXT不授信。局域网的访客隔离、VPN和系统权限可能影响发现。[NSD官方合同](https://developer.android.com/reference/android/net/nsd/NsdManager)（2026-10-21核对）。

显式选择才开启共享Rust配对窗口；Keystore加密的私有记录同步提交成功、且commit仍有效后才发送ACK。SharedPreferences提交失败也会更新其系统内存，因此应用只发布已成功提交的权威映射，下一次写入完整映射，防止失败保存/忘记改变信任。新TCP认证、裸DeviceInfo、加密心跳与完整快照沿用桌面协议。最多8次传输重试，不重置密码预算。

完整快照只保留在当前连接内存，断开/后台/换目标立即清空，启动精确清理旧`lan-display-v1.json`及其`.new/.bak`，配对凭据保留。图片按摘要保存在`lan-assets-v1`。每次复用和落盘完成均由Rust核验真实正文，AtomicFile静默提交失败也必须读回发现并清理部分文件。当前Hook引用优先保留，其余缓存收敛到512MiB/512文件。后台使用系统 ImageDecoder 解码最多512像素的图片，原图最多16MP；原生 Drawable 保留 GIF/WebP 动画，离开面板或进入后台停止播放。网络及缓存JSON进入系统解析器前检查严格语法与64层深度上限。

Android APK 构建与共享宿主测试通过。模拟器检查覆盖两菜单、显示偏好持久化、横竖屏等分、精简/详细、独立滚动与模块开关；这些属于本次 UI 回归，不替代真实桌面配对互通验收。

### Android 小组件、悬浮窗与后台同步

设置中的“小组件与后台”提供添加桌面小组件、立即同步、后台实时同步和悬浮窗入口。该分组位于面板显示、桌面连接和本机设置下方，占满内容区；三张功能卡片按实际宽度及字号排为一至三列，同行等高，窄屏按顺序纵向排列。小组件使用系统 `AppWidgetProvider` / `RemoteViews`，支持横竖尺寸调整，显示 Token 缩写及精确值、日期、Hooks 四态和上次同步时间；点击主体打开 App，刷新按钮提交一次后台任务。启动器不支持快捷添加时，可长按桌面，在“诡秘神谕”（非中文环境为 LokiMetris）的小组件列表添加。组件内容始终表示上次同步摘要，断线不会伪装成实时在线。

普通后台由系统 `JobScheduler` 持久化申请每 15 分钟执行一次加密 HTTP 读取，重启后仍由系统调度；立即同步使用独立的一次性任务。网络约束只要求 Wi-Fi 或以太网，不要求互联网验证；客户端根据实际目标的本地路由选择网络。桌面需支持 `widgetHttpV1` 并曾在前台完成认证同步，以授予组件专用只读配置。固定路径 `POST /api/widget/v1/snapshot` 使用独立32字节密钥及 ChaCha20-Poly1305；响应绑定本次请求 nonce 与桌面身份，拒绝代理、重定向和越界正文，总期限6秒。离线或失败保留上次摘要，不更新同步时间。系统省电、配额和厂商策略可能延后任务，不保证准点或息屏实时更新。[JobScheduler](https://developer.android.com/reference/android/app/job/JobScheduler)。

需要更及时的更新时，可显式开启“后台实时同步”。`connectedDevice` 前台服务显示持续通知，复用同一个 LAN owner 接收已配对桌面的认证快照推送；关闭服务后恢复普通后台模式。首次配对仍只能在 App 前台开启，离开前台会撤销尚未完成的配对窗口。服务不在开机或进程结束后自动启动；系统休眠仍可能暂停网络，不以常驻通知承诺不被回收，也不接入云推送。[前台服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types#connected-device)。

悬浮窗使用系统“显示在其他应用上层”授权，可拖动标题、折叠、关闭；关闭窗口后后台同步继续，停止后台同步则窗口和连接一并关闭。小窗按 Hooks、Token、额度分成三页，首次显示中间的 Token 页，左滑看额度、右滑看 Hooks，保存最后所在页；标题仍用于拖动，内容区纵向滚动。窗口显示当前认证连接的数值及同步时间，断线清空实时数值；锁屏或息屏时移除，解锁后按用户原意恢复，权限撤销时安全关闭窗口。窗口尺寸与位置限制在屏幕安全区域内。

普通 App 面板仍只接收当前连接的完整快照。小组件专用 `noBackupFilesDir/android-widget-v1/summary-v1.bin` 仅保存用量与 Hooks 四态，不保存正文和图片；读取配置由 Android Keystore 的 AES-GCM 密钥加密，不包含长期配对秘密。同进程多入口使用同一把锁原子提交，来源、端点或只读密钥变化会撤销旧代次；迟到 HTTP 不能覆盖较新推送、换桌面或忘记配对后的状态。损坏摘要可以由新合法快照重建，撤销组件缓存不依赖读取损坏内容。无额外第三方运行依赖。

2026-10-21 验证：Debug / Release APK 构建、Lint（零错误）和47项共享宿主测试通过；API31真实系统的9项HTTP/密码探针覆盖成功、篡改/错源、重定向、大小/深度、取消与总期限，包含阻塞disconnect时约6秒返回。API31联想平板收到真实桌面推送，悬浮窗拖动和息屏隐藏通过。API37模拟器完成真实桌面→App→小组件，以及通知权限、connectedDevice常驻服务启停；App退后台且无常驻服务时，强制触发周期任务和点击组件刷新按钮均独立拉取并推进摘要接收时间。强制触发不代表自然15分钟调度、Doze或厂商省电验收。联想启动器快捷添加的实时预览曾触发其自身ClassCastException，已改用静态空态预览；该机随后断开ADB，兼容修复尚待同机复测。

### 手机与平板类型上报

Android在应用级owner创建时读取系统最小宽度配置（≥600dp为平板尺寸类，未知配置不报告）；iOS在主线程从UIKit取得phone/pad类别。名称和页面宽度不参与类型选择。每条认证连接只有收到实时snapshot的`deviceFormFactorV1`能力后，才发一次`deviceFormFactor`报告；旧桌面无能力时不发，缓存不能启用能力，重新连接重新协商。桌面未取得报告时使用中性图标。Android尺寸类别不能保证所有折叠/桌面窗口模式的物理形态识别。

形态协商的Kotlin测试3项、Swift类型与既有Watch能力回归14项通过；未据此声明新包安装或平板真机互通通过。

### Apple Watch配套接线

同一Xcode工程包含现代单target `LokiMetrisWatch`，随iPhone宿主嵌入；Watch不链接Kotlin/Rust，也不创建独立TCP或Bonjour服务。Hooks、Token和额度使用原生水平分页，首次默认中间的Token总量页，向左滑看额度、向右滑看Hooks；保存最后所在页，重新打开时恢复。设置可选用量明细及Hooks **1×1／2×2（每屏四格）**，默认1×1，更多槽位沿竖向或表冠浏览。槽位卡片优先显示Agent与四态，点击进入正文／图片详情。稳定安装UUID与名称保存在Watch私有不备份目录，系统Watch配对与桌面四位码各自独立。

手机实时连接可用时，`PhoneWatchBridge`通过`sendMessageData`按16KiB块逐块确认，单RPC最多32KiB；Watch完整验证后接纳到当前前台内存，相同图片摘要可复用，缩略图限制256像素，当前显示静态图片。手机通道不可达、后台或请求超时后，Watch自动用`URLSession`直接调用电脑已有的`POST /api/widget/v1/snapshot`；无需手机App保持前台，也不启动手机后台长连接。首次仍需在iPhone连接支持`widgetHttpV1`的桌面，由认证快照授予独立只读配置。手机通过最新`applicationContext`及请求回执下发配置，Watch将其保存在本机Keychain，不传主连接配对秘密；修订号防旧消息复活被撤销的目标，换桌面／忘记配对明确撤销旧配置。电脑地址变化后需由手机同步新配置。

HTTP复用现有ChaCha20-Poly1305、来源与请求nonce绑定、有界正文、拒绝代理／重定向及6秒总期限，只提供Token精确值／统计质量、日期和Hooks插槽四态，不包含正文或图片；手机恢复完整同步时替换摘要。Watch活跃期间使用原15秒心跳尝试刷新，每次只有一个HTTP请求，持续有效的手机分块优先于HTTP后备。手机暂停或刷新失败保留本次前台内存中的最近成功结果与原接收时间，设置披露连接方式及上次同步；退出Watch前台、换来源或撤销配置清空，Token与Hooks不落盘。请求捕获前台代次、配置与手机同步版本，退出、换目标或新手机数据到达后迟到HTTP结果不能覆盖。系统可能通过手机网络代理或手表Wi-Fi承载HTTP；需要电脑在线且局域网可达，不保证息屏更新，不启用APNs。

当前已完成移动源码与桌面独立Watch状态投影接线；只有实时认证快照广告watchCompanionV1后，手机才上送无IP的Watch回执事实，并引用桌面心跳作保守时间锚。相同ACK序号不能续期，父连接撤销会立即撤销手表可达。两端完整图文互通仍待运行验证。运行Watch开发目标可使用Xcode同名scheme；独立构建命令为`xcodebuild -project iosApp/iosApp.xcodeproj -target LokiMetrisWatch -configuration Debug -sdk watchsimulator CODE_SIGNING_ALLOWED=NO build`。不要把独立Watch构建或空态交互当作桌面到手表的完整E2E通过。

2026-10-21 本轮验证：92 项 Swift 测试通过，iPhone／Watch 模拟器构建通过；42mm 模拟器的 Token、Hooks 1×1 与 2×2 布局截图均无裁切。隔离副本在无 iPhone 时，使用真实 Watch owner 与加密 HTTP 客户端成功取测试服务摘要并显示；仅在测试副本绕过未签名模拟器不可用的 Keychain 加载，正式源码无测试配置。Keychain 持久化与真实手机／手表之间的配置下发、通道切换仍待实机验收。

### iOS 桌面与锁屏小组件

`iosApp`工程包含独立的`LokiMetrisWidgets`扩展，支持桌面小号/中号和锁屏单行/圆形/矩形。安装后先启动App，再在系统小组件列表添加“诡秘神谕”。常亮显示由设备和系统决定；组件优先读取最近一次合法本地摘要，系统唤醒Timeline时可独立通过HTTP向已配对桌面拉取；断连、后台和重新启动后保留，并标明“上次同步”与统计日期；切换桌面或忘记当前配对时清除。Timeline使用`.after`统一申请 15 分钟后再次执行，Debug 与 Release 相同；前台同步与App后台认证短时拉取继续保留；实际执行可能明显晚于申请时间；电脑需在线且局域网可达，不保证息屏实时更新，也不启用云推送或组件长连接。[WidgetKit刷新规则](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)（2026-10-21核对）。

App与扩展的entitlements及Info.plist引用`Configuration/Config.xcconfig`中的同一`LOKI_WIDGET_APP_GROUP`。使用实际Apple开发团队签名时，需要该团队的App ID/扩展ID与App Group权限一致；当前没有代用户注册或修改开发者账号。共享容器不可用、首次尚未同步或文件损坏时，组件显示真实空态，不回退普通偏好存储。

共享快照只保存来源UUID、接收时间、Token日期/十进制数字/质量和Hooks四态摘要；另一个有界文件保存Widget专用只读密钥、当前服务地址及代次，不共享长期配对密钥、Hook正文/图片或宿主路径。共享格式schema 2保留45秒连接租约，认证心跳才续期；组件作为上次同步结果读取，租约过期不删除摘要，旧格式、损坏或未来时间均显示空态。Timeline不再预排45秒后的空条目。失效请求和待发布快照共用最新待办槽，明确清除意图不会被暂停请求覆盖，写入失败会披露。`LanLinkEngine`只把成功`open`且通过完整展示解析的snapshot交给单一后台组件发布器；中间消息与主线程投递都只保留最新一份。正文仅在当前会话内存，图片在App私有目录，App Group包含最近一次摘要与独立读取配置；主App不从共享文件恢复Token或状态。iOS网络owner已接入，完整模拟器 App 构建通过；没有将空态或测试夹具当作已连接。

后台刷新使用 `BGAppRefreshTask`，任务标识为 `com.manonloki.lokimetrisdisplay.widget-refresh`。App 启动即注册，进入后台或每次任务开始时申请下一次刷新；与小组件 Timeline 共用 `WidgetSnapshot.refreshInterval`，Debug 与 Release 均申请 15 分钟间隔，这仅为最早执行时间，实际唤醒可能明显更晚。系统禁用后台刷新时不强行运行。任务复用唯一 LAN owner，使用最近一次成功认证桌面的 Bonjour 服务名重新解析地址，读取已有配对并完成加密认证；仅接收一份快照、写入 App Group 并请求组件刷新后结束，不下载图片、不同步 Watch、不在后台开启配对或持续重试。25 秒本地超时和系统 expiration 都会撤销连接代次；前台接管优先。离线或失败保留上次摘要，任务完成成功必须等待共享文件实际提交，不能仅以接收消息宣告成功。[后台任务配置](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app)。

配对秘密仍仅在 App 私有、不同步的 Keychain 中；访问级别为 `AfterFirstUnlockThisDeviceOnly`，已有 `WhenUnlockedThisDeviceOnly` 记录在前台逐条验证双端身份后迁移，只修改访问属性，保留秘密原字节。设备重启后需先解锁一次才能锁屏认证。后台目标只保存来源 UUID 与 Bonjour 服务名/类型/本地域，不保存固定 IP、配对秘密或完整快照，按设备身份隔离、首次解锁后可读并排除备份；换桌面或忘记配对时撤销旧目标，损坏元数据可在显式选择时精确清理。组件不读取配对秘密。新版桌面在认证快照中提供`widgetHttpV1`及`widgetEndpoint {version,port,key}`，手机将系统实际连接的对端地址与该端口组合，每次认证同步后更新；旧桌面缺少能力时清除独立读取配置，保留App原有同步。Widget每次Timeline执行只发起一次固定路径`POST /api/widget/v1/snapshot`，6秒总超时、有界响应、拒绝重定向。使用独立派生32字节密钥及ChaCha20-Poly1305加密请求/响应，响应绑定本次随机nonce与来源UUID；桌面在当前账本验证权限后短暂唤醒统计发布器，响应不含Hook正文或图片。离线/超时/坏响应不改变上次同步时间。共享文件锁保证换桌面、忘记配对和服务地址换代之后，旧在途响应不能写回；较新App摘要也不能被旧HTTP请求或心跳覆盖。[Keychain 可访问性](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)。

`appleDisplay`使用SwiftPM运行共享投影/缓存的隔离单元测试，零第三方依赖。App与扩展直接编译该目录同一份Swift源码；扩展不链接Kotlin/Rust。开发测试：`swift test --package-path appleDisplay`。iPhone 前台同步与退到后台后的缓存保留已实机验证；独立自然后台刷新尚未完成排除主 App 唤醒影响的验收。15 分钟是统一的刷新申请间隔，系统自然调度的后台唤醒间隔、锁屏遮蔽和实际常亮由系统与设备决定，不能从调试触发或前台同步推断准点更新。

Bonjour 返回的 IPv4 对端可能包含 `%en0` 等接口后缀。保存组件刷新目标时，IPv4 从原始四字节生成规范地址；IPv6 保留路由所需的接口作用域，避免已连接但 HTTP 目标校验失败。组件每次真实 Timeline 执行会在 App Group 的 `Library/Caches/WidgetRefresh/timeline.json` 记录开始时间、完成时间、结果及错误域/码，不记录地址、身份或密钥；没有目标会标记 `missingTarget`，网络失败保留旧摘要。Debug 构建使用启动参数 `--widget-http-probe` 可在不启动前台 LAN 连接的情况下运行同一 HTTP 路径，结果写入该目录的 `appProbe.json`；此探针不代表系统已自然调度组件。

### Running the apps

Android、iOS、Apple Watch 及小组件的显示名称随系统语言选择：中文（含简体与繁体地区）为“诡秘神谕”，其他语言默认“LokiMetris”；项目名、应用标识与配对身份不参与名称本地化。Android、iOS 与 Apple Watch 统一使用桌面版的黑金眼睛图标。原始母版保存在 `branding/app-icon.png`；在 macOS 仓库根目录运行 `swift scripts/generate_app_icons.swift` 可重新生成各端资源，仅使用系统 SDK，不需要桌面仓库或第三方图像工具。Watch 使用独立的资源目录，并由同一 Xcode 工程编译图标。

Use the run configurations provided by the run widget in your IDE's toolbar. You can also use these commands and options:

- Android app: `./gradlew :androidApp:assembleDebug`
- iOS app: open the [/iosApp](./iosApp) directory in Xcode and run it from there.

### Running tests

Use the run button in your IDE's editor gutter, or run tests using Gradle tasks:

- Android tests: `./gradlew :sharedUI:testAndroidHostTest :sharedLogic:testAndroidHostTest`
- iOS tests: `./gradlew :sharedLogic:iosSimulatorArm64Test`

广播协议测试覆盖桌面端要求的服务类型、TXT 字段、UUID 格式，以及中文／emoji 名称的 UTF-8 长度和控制字符边界。

### 发布与真机安装

首个 GitHub Release 为 `v1.0.0`，Android、iOS、Watch 与 Widget 的版本统一为 `1.0.0`，构建号为 `2`。Release 附件提供项目固定签名的 Android APK 及 SHA-256 校验文件；Apple 开发签名包用于本机设备安装，不作为公开附件或 App Store 发布。

构建依赖桌面仓库的共享 Rust bridge。本次发布使用桌面提交 `c705bb8f3d9720dfc9272e166812218631164bc6`；Android 可通过 `-PlokiDesktopRoot=/absolute/path/to/loki_metris` 指定源码位置，iOS 可通过 Xcode 构建设置 `LOKI_DESKTOP_ROOT=/absolute/path/to/loki_metris` 指定。Android 运行 `./gradlew :androidApp:assembleRelease`，签名配置见 [签名说明](signing/README.md)。iOS 使用 `iosApp` scheme 的 Release 配置，并显式提供原有 `TEAM_ID` 以保持应用标识和配对数据；同一包嵌入 Widget 和 Watch。实体 Watch 的安装与版本需单独核实，不能由 iPhone 安装成功推断。

---

Learn more about [Kotlin Multiplatform](https://www.jetbrains.com/help/kotlin-multiplatform-dev/get-started.html)…


### 提供商额度与主动查询

手机、平板、手表、悬浮窗及各尺寸组件均不显示“部分、估算、范围未知、待核对、完整／精确”等统计质量标签；底层质量字段保留，可用状态、真实数值、额度和时间照常显示。

桌面新版通过现有认证快照提供Codex、Claude、Cursor、Grok的额度：Cursor为每月，其它为每周及5h。Android手机／平板和iPhone／iPad继续在原Token卡片内整合额度：精简模式显示账户摘要；详细模式每个Agent使用两行，第一行名称与缩写总量左右排列，第二行在左侧按每月、每周、5h顺序放剩余百分比与细进度条，右侧保留完整Token整数。先给数字留足宽度再分配进度条长度，极窄或大字号时整条明细可横向查看。没有对应Token分项的账户仍单独保留，不重复铺设匹配额度分组。明细首行采用左“设备时区”、右来源时区结构。Watch与Android悬浮窗采用独立额度页以适应小屏，和Token、Hooks左右切换并记住最后页。各面板的窗口文字统一为每月、每周、5h，按此顺序显示剩余百分比及细条，缺失窗口单独隐藏，只有周或月额度也保留，零余额显示0%。所有模式标明额度自身的上游更新时间；内联条的读屏保留重置时间，独立额度页可显示当地时间的重置时刻；无Token时有效额度仍可查看。Agent展示名统一为Codex、Claude Code、Grok、WorkBuddy、Cursor等标准写法，原始身份与未知自定义名称不改动。手机展示台的“刷新”仅在当前桌面广告snapshotQueryV1后出现，沿同一加密连接读取最新已知快照；桌面上游读取仍按约五分钟节流，不把查询时刻当作新上游观测。

2026-10-21 起额度协议直接升级：provider 增加 `claude`（位于 codex 与 cursor 之间），窗口增加 `monthly`（当前只由 Cursor 提供），旧版终端会拒收新桌面的额度，需与桌面同版升级；Android 组件私有格式升级为 v3，仍可读取 v2 与更早格式。

主App只在当前连接内存保留额度，失联或换目标随完整投影清空；现有组件摘要保留最近同步额度和原观测时间，HTTP及Watch投影不会裁掉额度。终端不接收提供商凭据，不根据Token推算额度。旧桌面无能力时不发送新请求，旧快照缺少额度字段仍可读取。Android组件私有格式升级后兼容读取旧格式。iOS小／中尺寸组件显示全部已提供账户（最多四个），各自显示实际存在的每月、每周、5h窗口与静态细进度条；待机沿用小尺寸，不再只保留第一个账户。组件单色渲染使用明暗轨道区分比例，保留百分比文字。Android组件按高度显示一至三个账户，每个可见账户同时保留实际存在的每月、每周、5h窗口；隐藏账户以数量提示，最小窄款保留Token和真实同步时间。两端均不因额度覆盖完整整数；锁屏最小组件不强塞额度。

2026-10-21 额度卡片整合验证：Apple 97 项测试、Android 共享逻辑 47 项及共享UI 4 项宿主测试通过，Android Debug APK 和 iPhone／Watch 模拟器构建通过。42mm Watch 隔离预览覆盖首屏Token、滚动到额度及无Token但有额度；iOS小／中桌面组件使用生产视图和测试数据离屏检查，精确值、质量、窗口、更新时间均可读取。预览不等于真实账户或上游提供商取数验收。

同日追加三页与内联布局：42mm Watch 隔离预览确认首次Token、独立额度页和重启恢复；Android模拟器确认悬浮窗双向手势、边界不循环及服务销毁重建后恢复最后页。详细卡片移除重复额度分组和总量下方的强制留白，手机、Pad、大字号以生产视图配合测试数据检查。97项Apple与51项Android共享测试再次通过，Android Debug及iPhone／Watch真机签名构建通过，最新iPhone包已保留数据覆盖安装；嵌入Watch签名有效不等于实体手表已安装。真实桌面认证HTTP已取到Codex与Grok周额度，移动端当前保存的旧桌面身份与运行实例不同，真实移动显示仍需连接对应桌面后验收。

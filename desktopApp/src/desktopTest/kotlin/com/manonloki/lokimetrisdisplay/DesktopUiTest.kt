package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.v2.runComposeUiTest
import androidx.compose.ui.unit.dp
import java.awt.Color
import java.awt.GradientPaint
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.util.Comparator
import javax.imageio.ImageIO
import kotlin.test.*

/** 隔离样例只在测试中生成，不会写入用户身份目录，也不会进入应用的数据源。 */
@OptIn(ExperimentalTestApi::class)
class DesktopUiTest {
    @Test fun tabletSplitResizesToNarrowWindowAndClearsDisconnectedContent() = runComposeUiTest {
        var width by mutableIntStateOf(1024)
        var view by mutableStateOf(sampleView())
        val image = sampleImage()
        val hash = imageHash(image)
        setContent {
            Box(Modifier.size(width.dp, 768.dp).testTag("test-window")) {
                App(view, {}, {}, { false }, {}, panelConfiguration = PanelConfiguration(hookLayout = HookLayout.GRID),
                    imageHashes = setOf(hash), motionEnabled = false, quotaTimestamp = ::quotaTimestamp,
                    image = { _, description, _ -> DesktopHookImage(image, description) })
            }
        }
        onNodeWithTag("usage-card").assertIsDisplayed()
        onNodeWithTag("hook-card-1").assertIsDisplayed()
        val wideUsage = onNodeWithTag("usage-card").fetchSemanticsNode().boundsInRoot
        val wideHooks = onNodeWithTag("hooks-pane").fetchSemanticsNode().boundsInRoot
        assertTrue(wideUsage.right <= wideHooks.left, "Tablet width must place usage and Hooks side by side")
        assertTrue(onNodeWithTag("menu-panel").fetchSemanticsNode().boundsInRoot.left < wideUsage.left)
        waitForIdle()
        screenshot("desktop-tablet-panel.png")

        runOnIdle { width = 640 }
        val narrowUsage = onNodeWithTag("usage-card").fetchSemanticsNode().boundsInRoot
        val narrowHooks = onNodeWithTag("hooks-pane").fetchSemanticsNode().boundsInRoot
        assertTrue(narrowUsage.bottom <= narrowHooks.top, "Narrow window must stack usage and Hooks")
        assertTrue(onNodeWithTag("menu-panel").fetchSemanticsNode().boundsInRoot.top > narrowHooks.top)
        screenshot("desktop-narrow-panel.png")

        runOnIdle { view = view.withoutLiveDisplay() }
        onNodeWithTag("hook-card-1").assertDoesNotExist()
        onNodeWithTag("hook-placeholder-0").assertIsDisplayed()
        onAllNodesWithText("等待同步").assertCountEquals(5)
        screenshot("desktop-disconnected.png")
    }

    @Test fun panelSettingsPersistAndMouseCanPageAndOpenHookDetails() {
        val directory = Files.createTempDirectory("lokimetris-ui-test-")
        try {
            val settings = DesktopDeviceSettings(directory)
            runComposeUiTest {
                var panel by mutableStateOf(settings.panel)
                val image = sampleImage()
                setContent {
                    Box(Modifier.size(1024.dp, 768.dp).testTag("test-window")) {
                        App(sampleView(), {}, {}, settings::saveName, {}, panelConfiguration = panel,
                            onSavePanel = { value -> settings.savePanel(value).also { if (it) panel = value } },
                            imageHashes = setOf(imageHash(image)), motionEnabled = false, quotaTimestamp = ::quotaTimestamp,
                            image = { _, description, _ -> DesktopHookImage(image, description) })
                    }
                }
                onNodeWithTag("menu-settings").performMouseInput { click() }
                onNodeWithTag("settings-usage-detailed").performScrollTo().performMouseInput { click() }
                onNodeWithTag("settings-hooks-2x2").performScrollTo().performMouseInput { click() }
                onNodeWithTag("settings-usage-detailed").assertIsSelected()
                onNodeWithTag("settings-hooks-2x2").assertIsSelected()
                screenshot("desktop-settings.png")
                assertEquals(UsageDetail.DETAILED, DesktopDeviceSettings(directory).panel.usageDetail)
                assertEquals(HookLayout.GRID, DesktopDeviceSettings(directory).panel.hookLayout)

                onNodeWithTag("menu-panel").performMouseInput { click() }
                onNodeWithTag("hook-card-1").assertIsDisplayed()
                onNodeWithTag("hooks-page-next").performMouseInput { click() }
                onNodeWithTag("hook-card-5").assertIsDisplayed()
                onNodeWithTag("hook-card-5").performMouseInput { click() }
                onNodeWithTag("hook-detail").assertIsDisplayed()
                onNodeWithText("测试正文：第五个 Agent 正在等待确认。").assertIsDisplayed()
                screenshot("desktop-hook-detail.png", "hook-detail")
                onNodeWithTag("hook-detail-close").performMouseInput { click() }
                onNodeWithTag("hook-detail").assertDoesNotExist()
                onNodeWithTag("hooks-page-previous").performMouseInput { click() }
                onNodeWithTag("hook-card-1").assertIsDisplayed()
            }
        } finally {
            Files.walk(directory).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) } }
        }
    }

    private fun ComposeUiTest.screenshot(name: String, tag: String = "test-window") {
        val directory = Path.of("build/screenshots")
        Files.createDirectories(directory)
        ImageIO.write(onNodeWithTag(tag).captureToImage().toAwtImage(), "png", directory.resolve(name).toFile())
    }

    private fun sampleView(): TerminalLinkView {
        val bytes = sampleImage(); val hash = imageHash(bytes)
        val start = java.time.Instant.parse("2026-10-21T16:00:00Z").toEpochMilli()
        val amount = TerminalAmount("12345678", "available", "complete", "exact")
        val snapshot = TerminalSnapshot(1,
            TerminalTokens(TerminalDay("2026-10-22", "Asia/Shanghai", start, start + 86_400_000), start + 10_000,
                amount, listOf(TerminalAgent("Codex", amount), TerminalAgent("Claude Code", TerminalAmount("4200000", "available", "complete", "exact")))),
            null, true, listOf("Codex", "Claude Code", "Cursor", "Grok", "WorkBuddy").mapIndexed { index, agent ->
                TerminalHook(agent, index + 1, listOf("running", "idle", "asking", "error", "asking")[index],
                    if (index == 4) "测试正文：第五个 Agent 正在等待确认。" else "测试正文：$agent 的当前任务。", false, hash)
            }, listOf(TerminalAsset(hash, "image/png", bytes.size.toLong())), null,
            ProviderQuotaSnapshot(start / 1000, listOf(
                ProviderQuotaEntry("codex", "Pro", ProviderQuotaWindow("fiveHour", 230, start / 1000 + 3600), ProviderQuotaWindow("weekly", 540, null)),
                ProviderQuotaEntry("cursor", "Ultra", null, null, ProviderQuotaWindow("monthly", 180, null)),
            )))
        snapshot.validate()
        return TerminalLinkView("45a30786-bc7a-4b58-9101-f0731db03876", "书房 Desktop 显示端",
            hosts = listOf(TerminalHost("7547b9ca-236f-4bc0-a895-1ea378604baa", "工作站", true, true)),
            selectedId = "7547b9ca-236f-4bc0-a895-1ea378604baa", status = "已连接，正在同步", connected = true,
            snapshot = snapshot, receivedAtMs = start + 10_000)
    }

    private fun imageHash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun sampleImage(): ByteArray {
        val image = BufferedImage(512, 320, BufferedImage.TYPE_INT_RGB)
        val graphics = image.createGraphics()
        try {
            graphics.paint = GradientPaint(0f, 0f, Color(0x16, 0x50, 0x66), 512f, 320f, Color(0x42, 0x27, 0x78))
            graphics.fillRect(0, 0, 512, 320)
            graphics.color = Color(0x67, 0xe8, 0xf9, 150)
            graphics.fillOval(146, 50, 220, 220)
            graphics.color = Color(0x08, 0x0d, 0x17)
            graphics.fillOval(174, 78, 164, 164)
        } finally { graphics.dispose() }
        return ByteArrayOutputStream().use { output -> check(ImageIO.write(image, "png", output)); output.toByteArray() }
    }
}

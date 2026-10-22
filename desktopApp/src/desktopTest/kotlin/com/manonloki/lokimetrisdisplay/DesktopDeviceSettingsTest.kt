package com.manonloki.lokimetrisdisplay

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFileAttributeView
import java.nio.file.attribute.PosixFilePermissions
import java.util.Comparator
import java.util.Properties
import kotlin.test.*

class DesktopDeviceSettingsTest {
    @Test fun identityNameAndPanelSurviveRestart() = withDirectory { directory ->
        val first = DesktopDeviceSettings(directory)
        assertTrue(MdnsProtocol.isCanonicalDeviceId(first.deviceId))
        assertTrue(first.saveName("书房 Desktop 🖥"))
        val panel = PanelConfiguration(false, true, UsageDetail.DETAILED, HookLayout.GRID)
        assertTrue(first.savePanel(panel))
        val restored = DesktopDeviceSettings(directory)
        assertEquals(first.deviceId, restored.deviceId)
        assertEquals("书房 Desktop 🖥", restored.name)
        assertEquals(panel, restored.panel)
    }

    @Test fun invalidNamesAndFailedAtomicWritesKeepPreviousValues() = withDirectory { directory ->
        val settings = DesktopDeviceSettings(directory)
        val previous = settings.name
        assertFalse(settings.saveName("bad\nname"))
        assertFalse(settings.saveName(" "))
        val file = directory.resolve("settings.properties")
        Files.delete(file); Files.createDirectory(file)
        assertFalse(settings.saveName("不可写入"))
        assertFalse(settings.savePanel(PanelConfiguration(showUsage = false)))
        assertEquals(previous, settings.name)
        assertEquals(PanelConfiguration.defaults(), settings.panel)
        Files.list(directory).use { assertEquals(listOf("settings.properties"), it.map { path -> path.fileName.toString() }.toList()) }
    }

    @Test fun corruptPreferencesRecoverWithoutChangingIdentity() = withDirectory { directory ->
        val first = DesktopDeviceSettings(directory)
        write(directory, Properties().apply {
            setProperty("device_id", first.deviceId)
            setProperty("device_name", "bad\nname")
            setProperty("panel.show_usage", "bad")
            setProperty("panel.show_hooks", "false")
            setProperty("panel.usage_detail", "unsupported")
            setProperty("panel.hook_layout", "8x8")
        })
        val recovered = DesktopDeviceSettings(directory)
        assertEquals(first.deviceId, recovered.deviceId)
        assertEquals("Desktop 显示端", recovered.name)
        assertEquals(PanelConfiguration(showHooks = false), recovered.panel)
    }

    @Test fun corruptExistingIdentityFailsWithoutReplacingFile() = withDirectory { directory ->
        write(directory, Properties().apply { setProperty("device_id", "invalid-secret-looking-value") })
        val file = directory.resolve("settings.properties")
        val previous = Files.readAllBytes(file)
        val error = assertFailsWith<IllegalStateException> { DesktopDeviceSettings(directory) }
        assertEquals("device_identity_invalid", error.message)
        assertContentEquals(previous, Files.readAllBytes(file))
    }

    @Test fun settingsUseOwnerOnlyPermissionsAndRefuseSymbolicLinkTargets() = withDirectory { directory ->
        val settings = DesktopDeviceSettings(directory)
        val file = directory.resolve("settings.properties")
        if (Files.getFileAttributeView(file, PosixFileAttributeView::class.java) != null) {
            assertEquals(PosixFilePermissions.fromString("rw-------"), Files.getPosixFilePermissions(file))
            assertEquals(PosixFilePermissions.fromString("rwx------"), Files.getPosixFilePermissions(directory))
            val external = directory.resolve("outside.properties")
            Files.writeString(external, "preserve")
            Files.delete(file); Files.createSymbolicLink(file, external)
            assertFalse(settings.saveName("replacement"))
            assertEquals("preserve", Files.readString(external))
            assertTrue(Files.isSymbolicLink(file))
        }
    }

    private fun write(directory: Path, values: Properties) {
        Files.newOutputStream(directory.resolve("settings.properties")).use { values.store(it, null) }
    }

    private fun withDirectory(block: (Path) -> Unit) {
        val directory = Files.createTempDirectory("lokimetris-settings-test-")
        try { block(directory) }
        finally { Files.walk(directory).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) } } }
    }
}

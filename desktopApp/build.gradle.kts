import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.composeMultiplatform)
    alias(libs.plugins.composeCompiler)
}

kotlin {
    jvm("desktop") {
        compilerOptions { jvmTarget = JvmTarget.JVM_11 }
    }
    sourceSets {
        val desktopMain by getting
        desktopMain.dependencies {
            implementation(project(":sharedLogic"))
            implementation(project(":sharedUI"))
            implementation(compose.desktop.currentOs)
            implementation(libs.compose.material3)
            implementation(libs.json)
        }
        val desktopTest by getting
        desktopTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(libs.compose.uiTestJUnit4)
        }
    }
}

compose.desktop {
    application {
        mainClass = "com.manonloki.lokimetrisdisplay.DesktopMainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "LokiMetrisDisplay"
            packageVersion = "1.0.7"
            vendor = "ManonLoki"
            description = "LokiMetris LAN display terminal"
            modules("java.naming", "jdk.unsupported")
            macOS { bundleID = "com.manonloki.lokimetrisdisplay.desktop" }
            linux { packageName = "lokimetris-display" }
        }
    }
}

// 沿用与移动端相同的 Rust 协议实现，只构建本机架构，不修改外部源码或下载工具。
val desktopSource = providers.gradleProperty("lokiDesktopRoot")
    .orElse(rootProject.layout.projectDirectory.dir("../../../my-work/ai/loki_metris").asFile.absolutePath)
// Windows 可显式指定完整 Python 可执行路径，避免命中系统商店的 python3 占位程序。
val desktopPython = providers.gradleProperty("lokiPython").orElse("python3")
val nativeOutput = layout.buildDirectory.dir("generated/desktopNative")
val buildDesktopNative = tasks.register<Exec>("buildDesktopNative") {
    // 同一工作区被不同宿主使用时，不得复用另一系统的 .dylib/.dll/.so。
    inputs.property("hostOs", System.getProperty("os.name"))
    inputs.property("hostArch", System.getProperty("os.arch"))
    inputs.property("javaHome", System.getProperty("java.home"))
    inputs.files(rootProject.file("scripts/build_desktop_native.py"), rootProject.file("androidApp/src/main/c/loki_metris_jni.c"))
    inputs.dir(desktopSource.map { file("$it/loki_metris_pairing/src") })
    inputs.dir(desktopSource.map { file("$it/loki_metris_mobile_bridge") })
    inputs.files(desktopSource.map { file("$it/Cargo.toml") }, desktopSource.map { file("$it/Cargo.lock") })
    outputs.dir(nativeOutput)
    commandLine(desktopPython.get(), rootProject.file("scripts/build_desktop_native.py"),
        "--desktop-root", desktopSource.get(), "--out", nativeOutput.get().asFile.absolutePath,
        "--java-home", System.getProperty("java.home"))
}
// 协议动态库随当前平台的 JAR 一起分发；加载器以私有临时目录装载，无开发机绝对路径。
tasks.named<ProcessResources>("desktopProcessResources") {
    dependsOn(buildDesktopNative)
    from(nativeOutput) { into("native") }
    from(rootProject.file("branding/app-icon.png")) { into("icons") }
}

// 集成测试启动隔离环回采集端，真实执行与现有采集端相同的 Rust 密码状态机。
val testServerOutput = layout.buildDirectory.dir("testServer")
val testServer = testServerOutput.map { it.file("desktop_link_fixture" + if (System.getProperty("os.name").startsWith("Windows")) ".exe" else "") }
val buildDesktopTestServer = tasks.register<Exec>("buildDesktopTestServer") {
    inputs.property("hostOs", System.getProperty("os.name"))
    inputs.property("hostArch", System.getProperty("os.arch"))
    inputs.files(rootProject.file("scripts/build_desktop_test_server.py"), file("src/desktopTest/rust/server.rs"))
    inputs.dir(desktopSource.map { file("$it/loki_metris_pairing") })
    inputs.files(desktopSource.map { file("$it/Cargo.lock") })
    outputs.file(testServer)
    commandLine(desktopPython.get(), rootProject.file("scripts/build_desktop_test_server.py"),
        "--desktop-root", desktopSource.get(), "--out", testServerOutput.get().asFile.absolutePath)
}
tasks.named<Test>("desktopTest") {
    dependsOn(buildDesktopTestServer)
    systemProperty("loki.desktop.testServer", testServer.get().asFile.absolutePath)
}

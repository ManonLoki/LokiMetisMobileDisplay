import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidMultiplatformLibrary)
}

kotlin {
    // Watch 双真机架构分别为 arm64_32 与 arm64；所有 Apple 模拟器仅配置 arm64。
    // macosArm64 供 SwiftPM 集成测试链接，不代表新增一个 macOS 产品。
    listOf(
        iosArm64(),
        iosSimulatorArm64(),
        watchosArm64(),
        watchosDeviceArm64(),
        watchosSimulatorArm64(),
        macosArm64(),
    ).forEach { appleTarget ->
        appleTarget.binaries.framework {
            baseName = "SharedLogic"
            isStatic = true
        }
    }
    
    android {
       namespace = "com.manonloki.lokimetrisdisplay.sharedLogic"
       compileSdk = libs.versions.android.compileSdk.get().toInt()
       minSdk = libs.versions.android.minSdk.get().toInt()
    
       compilerOptions {
           jvmTarget = JvmTarget.JVM_11
       }
       androidResources {
           enable = true
       }
       // 宿主测试包含公共业务规则及 Android 编解码/地址边界，使用 JVM 执行。
       withHostTest {
           isIncludeAndroidResources = true
       }
    }
    
    sourceSets {
        commonTest.dependencies {
            implementation(libs.kotlin.test)
        }
    }
}

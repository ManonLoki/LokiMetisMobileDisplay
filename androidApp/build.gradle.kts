import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.composeCompiler)
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_11
    }
}
dependencies {
    implementation(project(":sharedUI"))

    implementation(libs.androidx.activity.compose)
    implementation(libs.compose.material3)
    implementation(libs.compose.foundation)
    implementation(libs.compose.ui)

    implementation(libs.compose.uiToolingPreview)
    debugImplementation(libs.compose.uiTooling)
}

android {
    namespace = "com.manonloki.lokimetrisdisplay"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "com.manonloki.lokimetrisdisplay"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 7
        versionName = "1.0.5"
        // 配对桥仅提供这两种架构，避免依赖库让 APK 误报支持 32 位设备。
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }
    // 固定使用项目内签名；缺失时不悄悄切换为另一台机器的默认 debug 证书。
    val signingProperties = Properties().apply {
        val source = rootProject.file("signing/signing.properties")
        if (source.isFile) source.inputStream().use(::load)
    }
    val projectSigning = signingConfigs.create("projectLocal") {
        storeFile = rootProject.file("signing/lokimetris.keystore")
        storePassword = signingProperties.getProperty("storePassword")
        keyAlias = signingProperties.getProperty("keyAlias", "lokimetris")
        keyPassword = signingProperties.getProperty("keyPassword")
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    buildTypes {
        debug { signingConfig = projectSigning }
        release {
            signingConfig = projectSigning
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
    }
}

// 本地共享核心路径可由 -PlokiDesktopRoot 覆盖；不下载另一份协议实现。
val desktopSource = providers.gradleProperty("lokiDesktopRoot")
    .orElse(rootProject.layout.projectDirectory.dir("../../../my-work/ai/loki_metris").asFile.absolutePath)
val nativeOutput = layout.buildDirectory.dir("generated/mobileNative/jniLibs")
val nativeTask = tasks.register<Exec>("buildMobileNative") {
    inputs.files(rootProject.file("scripts/build_mobile_native.py"), file("src/main/c/loki_metris_jni.c"))
    inputs.dir(desktopSource.map { file("$it/loki_metris_pairing/src") })
    inputs.dir(desktopSource.map { file("$it/loki_metris_mobile_bridge") })
    inputs.files(desktopSource.map { file("$it/Cargo.toml") })
    outputs.dir(nativeOutput)
    commandLine("python3", rootProject.file("scripts/build_mobile_native.py"),
        "--desktop-root", desktopSource.get(), "--platform", "android", "--out", nativeOutput.get().asFile.absolutePath)
}
android.sourceSets.named("main") { jniLibs.directories.add(nativeOutput.get().asFile.absolutePath) }
tasks.named("preBuild") { dependsOn(nativeTask) }

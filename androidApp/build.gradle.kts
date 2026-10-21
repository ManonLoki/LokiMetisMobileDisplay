import org.jetbrains.kotlin.gradle.dsl.JvmTarget

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
        versionCode = 1
        versionName = "1.0"
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    buildTypes {
        release {
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

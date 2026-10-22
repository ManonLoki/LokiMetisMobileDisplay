rootProject.name = "LokiMetrisDisplay"

pluginManagement {
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
    }
}

// Android 与实验性 Desktop 共用 Compose 界面；Apple 界面由 Xcode target 编译。
include(":androidApp")
include(":sharedLogic")
include(":sharedUI")
include(":desktopApp")

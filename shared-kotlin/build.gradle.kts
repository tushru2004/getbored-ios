import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    id("org.jetbrains.kotlin.multiplatform")
    kotlin("plugin.serialization") version "2.3.21"
}

kotlin {
    val sharedCore = XCFramework("GetBoredSharedCore")

    iosArm64 {
        binaries.framework {
            baseName = "GetBoredSharedCore"
            isStatic = true
            sharedCore.add(this)
        }
    }

    iosSimulatorArm64 {
        binaries.framework {
            baseName = "GetBoredSharedCore"
            isStatic = true
            sharedCore.add(this)
        }
    }

    iosX64 {
        binaries.framework {
            baseName = "GetBoredSharedCore"
            isStatic = true
            sharedCore.add(this)
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}

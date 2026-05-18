import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    id("org.jetbrains.kotlin.multiplatform")
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
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}

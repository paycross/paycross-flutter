import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val demoKeystore = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun demoSigning(property: String, variable: String): String? =
    demoKeystore.getProperty(property) ?: System.getenv(variable)

android {
    namespace = "com.paycross.flutterdemo"
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.paycross.flutterdemo"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val store = demoSigning("storeFile", "DEMO_KEYSTORE_FILE")
            if (store != null) {
                storeFile = file(store)
                storePassword = demoSigning("storePassword", "DEMO_KEYSTORE_PASSWORD")
                keyAlias = demoSigning("keyAlias", "DEMO_KEY_ALIAS")
                keyPassword = demoSigning("keyPassword", "DEMO_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (demoSigning("storeFile", "DEMO_KEYSTORE_FILE") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

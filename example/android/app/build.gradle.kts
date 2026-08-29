plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.paycross.paycross_flutter_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.paycross.paycross_flutter_example"
        // flutter.minSdkVersion is 24 on the Flutter versions this plugin
        // supports, which is what the plugin itself requires. A merchant app
        // pinned lower must raise minSdk to 24 explicitly.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Debug keys are deliberate: this example is never distributed, and
            // signing it with them keeps `flutter run --release` working with no
            // keystore. A real app replaces this with its own signing config.
            signingConfig = signingConfigs.getByName("debug")
            // What a merchant's release pipeline does, and the reason D1
            // exists. The SDK passes PayCrossResult and Recovery through an
            // Intent and ships consumer rules to keep them; if those rules
            // ever stop being applied, R8 renames the classes, the result
            // never unmarshals, and every payment comes back as
            // error:resultUnknown instead of its real outcome. Only a
            // release build can show that, and only a real payment on one
            // can prove it does not.
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

import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Read from example/android/key.properties when it exists, otherwise from
// the environment -- which is what CI has. Absent means neither, and that is
// a supported state: `flutter run --release` on a developer's machine still
// works, debug-signed, exactly as it did before this app was distributed.
val demoKeystore = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun demoSigning(property: String, variable: String): String? =
    demoKeystore.getProperty(property) ?: System.getenv(variable)

android {
    namespace = "com.paycross.flutterdemo"
    // flutter_secure_storage 11.0.0 declares compileSdk 37 and the AAR
    // metadata check refuses to build against anything lower, while Flutter
    // 3.44.8 still defaults to 36. `maxOf` rather than a flat 37 so this
    // corrects itself the day Flutter's own default catches up, instead of
    // pinning the example one API behind it forever.
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.paycross.flutterdemo"
        // flutter.minSdkVersion is 24 on the Flutter versions this plugin
        // supports, which is what the plugin itself requires. A merchant app
        // pinned lower must raise minSdk to 24 explicitly.
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
            // The demo is distributed now, so the release build type signs
            // with the demo upload keystore when one is configured. Debug
            // keys remain the fallback rather than an error: without them
            // `flutter run --release` would need a keystore on every
            // machine, and the release script verifies the certificate
            // before anything is ever published.
            signingConfig = if (demoSigning("storeFile", "DEMO_KEYSTORE_FILE") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // What a merchant's release pipeline does, and the reason D1
            // exists. The SDK passes PayCrossResult and Recovery through an
            // Intent and ships consumer rules to keep them; if those rules
            // ever stop being applied, R8 renames the classes, the result
            // never unmarshals, and every payment comes back as
            // result:pending:result_lost: instead of its real outcome. Only
            // a release build can show that, and only a real payment on one
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

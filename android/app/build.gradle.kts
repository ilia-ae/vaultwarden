import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val useYubiKey = System.getenv("YUBIKEY_SIGN") == "1"

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (!useYubiKey && keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.vaultapprover.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.vaultapprover.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Read by MainActivity.kt to conditionally disable FLAG_SECURE.
        // Defaults to false → production builds keep screenshot protection.
        // Set to true ONLY when the screenshot-capture harness builds via
        //   flutter build apk --release -Pallow-screenshots=true
        // (see mobile-stores-cicd/android/commands/screenshots_capture.py).
        val allowScreenshots: String =
            (project.findProperty("allow-screenshots") as String?) ?: "false"
        buildConfigField("Boolean", "ALLOW_SCREENSHOTS", allowScreenshots)
    }

    buildFeatures {
        buildConfig = true     // enable BuildConfig generation
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = if (useYubiKey) {
                null // unsigned — will be signed externally with jarsigner + YubiKey
            } else if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

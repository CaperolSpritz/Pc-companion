plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

fun signingValue(name: String): String? =
    (project.findProperty(name) as String?) ?: System.getenv(name)

android {
    namespace = "net.oxog.phonebox.deskpanel"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.caperolspritz.pccompanion"
        minSdk = 28 // Android 9+ required for BluetoothHidDevice API
        targetSdk = 35
        versionCode = 7
        versionName = "1.4.0"
    }

    signingConfigs {
        val storeFile = signingValue("PHONEBOX_STORE_FILE")
        if (storeFile != null && file(storeFile).exists()) {
            create("release") {
                this.storeFile = file(storeFile)
                storePassword = signingValue("PHONEBOX_STORE_PASSWORD")
                keyAlias = signingValue("PHONEBOX_KEY_ALIAS")
                keyPassword = signingValue("PHONEBOX_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        fatal += "NewApi"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.webkit:webkit:1.12.1")
}

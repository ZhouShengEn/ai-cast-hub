import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ============================================================
// Release 正式签名（仅 CI 生效，本地开发完全无感）
// ============================================================
// CI 在构建前把 keystore（来自 GitHub Secrets 的 base64）还原到 android/app/，
// 并通过环境变量注入签名信息：
//   ANDROID_KEYSTORE_PATH      还原后的 .jks 文件路径
//   ANDROID_KEYSTORE_PASSWORD  keystore 口令
//   ANDROID_KEY_ALIAS          密钥别名
//   ANDROID_KEY_PASSWORD       密钥口令
//
// 本地开发不设置这些变量 → hasReleaseSigning = false → release 仍回落到 debug 签名，
// `flutter run --release` / `flutter build apk --release` 的行为与改造前完全一致。
// 注意：keystore 文件本身绝不入库（android/.gitignore 已忽略 **/*.jks）。
val releaseKeystoreFile: File? =
    System.getenv("ANDROID_KEYSTORE_PATH")
        ?.takeIf { it.isNotBlank() }
        ?.let { file(it) }
        ?.takeIf { it.isFile }

val releaseKeystorePassword: String? = System.getenv("ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias: String? = System.getenv("ANDROID_KEY_ALIAS")
val releaseKeyPassword: String? = System.getenv("ANDROID_KEY_PASSWORD")

/** 环境变量齐全且 keystore 文件真实存在时，才启用正式签名 */
val hasReleaseSigning: Boolean =
    releaseKeystoreFile != null &&
        !releaseKeystorePassword.isNullOrBlank() &&
        !releaseKeyAlias.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank()

logger.lifecycle(
    if (hasReleaseSigning) {
        "[signing] release → 使用 CI 注入的正式签名（alias=$releaseKeyAlias）"
    } else {
        "[signing] release → 未检测到完整签名环境变量，回退 debug 签名（本地开发正常）"
    }
)

android {
    namespace = "com.example.ai_cast_hub"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        // 仅在 CI 环境变量齐全时创建 release 签名；否则不创建，
        // 避免本地开发者因缺少文件而在配置阶段报错。
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseKeystoreFile
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.ai_cast_hub"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 注意：单 ABI 包（app-arm64-v8a-debug.apk）由 CI 命令
        //   flutter build apk --debug --split-per-abi --target-platform android-arm64
        // 控制，不要在这里再加 ndk.abiFilters —— 它会与 --split-per-abi 自动设置的
        // splits.abi 过滤器冲突（Gradle 报 "Conflicting configuration"），导致 assembleDebug 失败。
    }

    buildTypes {
        release {
            // CI 注入正式签名环境变量时用 release 签名，否则沿用 debug 签名（本地开发）
            signingConfig = if (hasReleaseSigning) {
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

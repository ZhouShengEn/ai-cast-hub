# Android 正式签名与 Release 打包流水线

> 相关文件
>
> - `.github/workflows/release_apk.yml` —— 手动触发的正式签名发布流水线
> - `flutter-app/android/app/build.gradle.kts` —— release 签名配置（只读环境变量）
> - `flutter-app/android/.gitignore` —— 已忽略 `**/*.jks`、`**/*.keystore`、`key.properties`
>
> ⚠️ **密钥与口令严禁提交到 Git 仓库**。仓库里只保存「如何读取环境变量」的代码，不保存任何密钥material。

---

## 目录

1. [生成签名密钥（jks）](#1-生成签名密钥jks)
2. [密钥备份（必做）](#2-密钥备份必做)
3. [转 base64](#3-转-base64)
4. [配置 GitHub Secrets](#4-配置-github-secrets)
5. [触发流水线](#5-触发流水线)
6. [流水线内部流程与密钥生命周期](#6-流水线内部流程与密钥生命周期)
7. [本地用正式签名打包（可选）](#7-本地用正式签名打包可选)
8. [常见 CI 报错清单](#8-常见-ci-报错清单)
9. [安全自查清单](#9-安全自查清单)

---

## 1. 生成签名密钥（jks）

在**本地**（不要在任何共享环境）执行，JDK 17+ 自带 `keytool`：

```bash
keytool -genkeypair -v \
  -keystore ai-cast-hub-release.jks \
  -alias ai-cast-hub \
  -keyalg RSA -keysize 2048 \
  -validity 10950 \
  -storetype JKS \
  -dname "CN=AI Cast Hub, OU=Mobile, O=ZhouShengEn, L=Shenzhen, ST=Guangdong, C=CN"
```

执行后会**交互式提示输入口令**（storePassword，两次）与 keyPassword。

| 参数 | 说明 |
|------|------|
| `-alias` | 别名，后面 `ANDROID_KEY_ALIAS` 要填这个值 |
| `-keysize 2048` | ≥2048，2048 足够且兼容性最好 |
| `-validity 10950` | ≈30 年。Google Play 要求密钥有效期覆盖到 2033 年以后，别用默认 90 天 |
| `-storetype JKS` | 生成传统 `.jks`。JDK 9+ 默认是 PKCS12，**不显式指定时文件名虽为 `.jks` 但内容是 PKCS12** |

> 💡 建议**省略** `-storepass`/`-keypass` 参数，让 keytool 交互式输入：
> 命令行里明文写口令会留在 shell history 与进程列表里。

### 关于 JKS 的口令限制（重要）

JKS **不支持 storePassword ≠ keyPassword**。若传入不同的 `-keypass`，keytool 会警告
`Warning: Different store and key passwords not supported for JKS keystores.` 并忽略该值。

因此本仓库 4 个 Secret 中：

- 用 **JKS** → `ANDROID_KEY_PASSWORD` 必须与 `ANDROID_KEYSTORE_PASSWORD` **相同**
- 用 **PKCS12**（`-storetype PKCS12`）→ 两者可以不同

### 校验密钥

```bash
# 查看条目与别名（会提示输入 storePassword）
keytool -list -keystore ai-cast-hub-release.jks

# 更详细：打印证书指纹、有效期、签名算法（务必记录 SHA-256 指纹）
keytool -list -v -keystore ai-cast-hub-release.jks -alias ai-cast-hub
```

---

## 2. 密钥备份（必做）

> ❗密钥一旦丢失，**已上架的应用将无法再发布更新**（除非在 Google Play 后台重置上传密钥）。

至少保留 **3 份异构备份**：

| 位置 | 说明 |
|------|------|
| 本地加密磁盘 / 密码管理器附件 | 日常使用 |
| 私有云盘（加密压缩包） | 异地容灾 |
| 离线介质（U 盘 / 移动硬盘） | 防云账号被盗 |

备份必须包含 **4 项**（缺一不可）：

```
ai-cast-hub-release.jks   # 密钥文件
storePassword             # keystore 口令
keyPassword               # 密钥口令（JKS 时与上者相同）
alias                     # 别名：ai-cast-hub
```

压缩加密示例：

```bash
zip -e ai-cast-hub-signing-backup.zip ai-cast-hub-release.jks
# 备份文件本身也要设一个强口令，并单独记录
```

**绝对不要**：提交到 Git、贴进聊天工具、写进 CI 配置文件、放到公网可访问目录。

---

## 3. 转 base64

CI 通过 Secret 传递的是 base64 文本，本地先转好。

**Linux**

```bash
base64 -w 0 ai-cast-hub-release.jks > keystore.b64
# 直接进剪贴板
base64 -w 0 ai-cast-hub-release.jks | xclip -selection clipboard
```

**macOS**

```bash
base64 -i ai-cast-hub-release.jks | tr -d '\n' > keystore.b64
# 直接进剪贴板
base64 -i ai-cast-hub-release.jks | tr -d '\n' | pbcopy
```

**Windows PowerShell**

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("ai-cast-hub-release.jks")) |
  Set-Content -NoNewline -Encoding ascii keystore.b64
# 直接进剪贴板
[Convert]::ToBase64String([IO.File]::ReadAllBytes("ai-cast-hub-release.jks")) | Set-Clipboard
```

> 流水线里已用 `tr -d '\n\r\t '` 容错，即使 base64 带换行/空格也能正确解码。

---

## 4. 配置 GitHub Secrets

仓库 → **Settings → Secrets and variables → Actions → New repository secret**

| Secret 名称 | 值 |
|-------------|-----|
| `ANDROID_KEYSTORE_BASE64` | `keystore.b64` 的**完整内容**（一整行） |
| `ANDROID_KEYSTORE_PASSWORD` | storePassword |
| `ANDROID_KEY_ALIAS` | `ai-cast-hub` |
| `ANDROID_KEY_PASSWORD` | keyPassword（JKS 时同 storePassword） |

注意事项：

- 名称**大小写敏感**，必须与上表完全一致（流水线里是写死的）。
- 粘贴时不要带入首尾空格或换行；`ANDROID_KEYSTORE_BASE64` 建议用「复制文件内容」的方式粘贴。
- Secret 一旦保存**无法再查看原值**，只能重新设置；所以本地备份必须做好。
- 环境级 Secret（Environments）也可以，但本流水线读取的是仓库级 Secrets。

---

## 5. 触发流水线

GitHub → **Actions** → 左侧选择 **Release Android (正式签名)** → 右侧 **Run workflow**：

| 输入项 | 默认 | 说明 |
|--------|------|------|
| `build_appbundle` | `false` | 勾选后额外构建 `app-release.aab`（Google Play 上架包） |
| `create_release` | `true` | 构建完成后自动创建/更新 GitHub Release |
| `release_tag` | 空 | 留空自动生成 `v<版本>-build.<构建号>`，如 `v1.0.0-build.42` |
| `flutter_version` | `3.29.0` | 可临时指定其他 Flutter 版本 |

产物：

| 产物 | 路径 | 去向 |
|------|------|------|
| APK | `flutter-app/build/app/outputs/flutter-apk/app-release.apk` | artifact `release-apk`（保留 30 天）+ Release 附件 |
| AAB | `flutter-app/build/app/outputs/bundle/release/app-release.aab` | artifact `release-aab`（保留 30 天）+ Release 附件 |

> `release_tag` 填已存在的 Tag 时会改为**覆盖上传**产物到该 Release，不会报错。

---

## 6. 流水线内部流程与密钥生命周期

```
① Checkout
② Setup Flutter（subosito/flutter-action）
③ Setup Android SDK（复用 runner 预装 SDK，补齐 android-36 / NDK 27.0.12077973）
④ Restore release keystore from Secrets
     base64 → flutter-app/android/app/ci-release.jks   （chmod 600）
     keytool -list 校验：文件可解析 + alias 存在      （失败即中止，错误信息明确）
⑤ flutter pub get
⑥ flutter build apk --release        ← 签名来自环境变量
⑦ flutter build appbundle --release  ← 仅当 build_appbundle=true
⑧ Destroy keystore   （if: always()，shred -u 删除）
⑨ Verify APK is release-signed       （apksigner 断言不是 CN=Android Debug）
⑩ Upload artifact ×1~2
⑪ gh release create/upload
```

**密钥生命周期说明**

- 还原 → 构建 → 销毁，全程在**同一次一次性 runner 容器**内完成；任务结束容器即销毁。
- `Destroy keystore` 使用 `if: always()`，**构建失败、步骤报错时同样会删除**，用 `shred -u`（不可恢复擦除），失败则退回 `rm -f`。
- 销毁步骤紧跟在构建之后、上传/发布之前，尽量缩短密钥在磁盘上的存活时间。
- 密钥内容不会出现在日志里：Secret 引用（`${{ secrets.X }}`）会被 GitHub 自动打码；校验步骤只打印 alias 列表，不打印口令。

**签名是如何生效的**（`flutter-app/android/app/build.gradle.kts`）

```kotlin
val releaseKeystoreFile: File? =
    System.getenv("ANDROID_KEYSTORE_PATH")
        ?.takeIf { it.isNotBlank() }
        ?.let { file(it) }
        ?.takeIf { it.isFile }

val hasReleaseSigning: Boolean =
    releaseKeystoreFile != null &&
        !releaseKeystorePassword.isNullOrBlank() &&
        !releaseKeyAlias.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank()

android {
    signingConfigs {
        if (hasReleaseSigning) {
            create("release") { /* 从环境变量读取 */ }
        }
    }
    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")   // 本地开发：不受影响
            }
        }
    }
}
```

构建日志里会打印一行 `[signing] release → ...`，可直接确认是否识别到正式签名配置。

---

## 7. 本地用正式签名打包（可选）

需要验证正式包时，本地临时导出同样的 4 个环境变量即可（**不要**写进任何配置文件）：

**bash**

```bash
export ANDROID_KEYSTORE_PATH="$PWD/ai-cast-hub-release.jks"
read -rs ANDROID_KEYSTORE_PASSWORD && export ANDROID_KEYSTORE_PASSWORD
read -rs ANDROID_KEY_PASSWORD     && export ANDROID_KEY_PASSWORD
export ANDROID_KEY_ALIAS='ai-cast-hub'

cd flutter-app && flutter build apk --release
```

**PowerShell**

```powershell
$env:ANDROID_KEYSTORE_PATH = "$PWD\ai-cast-hub-release.jks"
$env:ANDROID_KEYSTORE_PASSWORD = Read-Host -AsSecureString | ConvertFrom-SecureString -AsPlainText
$env:ANDROID_KEY_PASSWORD = $env:ANDROID_KEYSTORE_PASSWORD
$env:ANDROID_KEY_ALIAS = 'ai-cast-hub'

cd flutter-app; flutter build apk --release
```

验证签名（`apksigner` 位于 `$ANDROID_HOME/build-tools/<版本>/`）：

```bash
apksigner verify --print-certs flutter-app/build/app/outputs/flutter-apk/app-release.apk
```

**不设置**这 4 个变量时，release 会自动回落到 debug 签名，本地 `flutter run --release` /
`flutter build apk --release` 的体验与改造前**完全一致**（无报错、无需额外配置）。

---

## 8. 常见 CI 报错清单

| 报错 / 现象 | 原因 | 解决 |
|-------------|------|------|
| `::error::缺少 Secret: ANDROID_KEYSTORE_BASE64` | Secret 未配置、名称拼错或大小写不符 | 核对 §4 的 4 个名称，全部为仓库级 Secret |
| `::error::keystore 解析失败：ANDROID_KEYSTORE_BASE64 或 ANDROID_KEYSTORE_PASSWORD 不正确` | base64 内容被截断/粘贴不全，或 storePassword 错 | 重新执行 §3 生成并**整行**粘贴；确认口令无首尾空格 |
| `::error::keystore 中不存在别名 xxx` | `ANDROID_KEY_ALIAS` 与 jks 里的 alias 不一致 | `keytool -list -keystore ai-cast-hub-release.jks` 查看真实别名 |
| `Keystore was tampered with, or password was incorrect` | JKS 下 `keyPassword ≠ storePassword`（JKS 强制相同），或口令含特殊字符 | JKS 让两个 Secret 值一致；或改用 PKCS12 重新生成密钥 |
| `Cannot recover key` | `ANDROID_KEY_PASSWORD` 与 alias 对应密钥的口令不符 | 同上一行；PKCS12 下确认真实的 keypass |
| `Failed to read key ai-cast-hub from store ...` | alias 不存在，或 keystore 里有多个条目选错 | 用 `keytool -list` 核对 |
| 产物是 `CN=Android Debug` 签名 | 4 个变量没有全部传到 Gradle → 回落 debug 签名 | 检查构建步骤 `env` 是否 4 项齐全；看日志 `[signing] release → ...` 行 |
| `Execution failed for task ':app:validateSigningRelease'` | keystore 文件为空/损坏，或被 debug keystore 覆盖 | 检查还原步骤打印的字节数是否合理（一般 2KB 以上） |
| `sdkmanager --licenses` 退出码 1 / `Wrong version in preinstalled sdkmanager` | 历史问题：`android-actions/setup-android@v3` 重新下载 cmdline-tools 后崩溃 | 本仓库已改为直接用 runner 预装 SDK（见 `build_apk.yml` / `release_apk.yml` 的 Setup Android SDK 步骤） |
| `Could not determine the dependencies of task ':app:...'` + 缺少 `platforms;android-36` | 镜像未预装对应 SDK 平台 | 流水线已按需补装 `platforms;android-36` 与 `ndk;27.0.12077973`；如换 compileSdk 需同步改这两处 |
| `gh: command not found` | runner 不是 `ubuntu-latest`（或自建 runner 精简镜像） | 安装 GitHub CLI，或改用 `softprops/action-gh-release` |
| `403 Resource not accessible by integration` | Token 缺少写权限 | workflow 已声明 `permissions: contents: write`，不要删除 |
| 上传 artifact 报 `No files were found with the provided path` | 构建失败或产物路径变化 | 确认 `flutter build apk --release` 成功；产物固定为 `build/app/outputs/flutter-apk/app-release.apk` |
| `keytool: command not found` | runner 无 JDK | `ubuntu-latest` 自带 JDK 17；自建 runner 需自行安装 |
| Release 里出现两个同名附件 | `--clobber` 只在同 Tag 覆盖时生效，手动传过同名文件会冲突 | 让流水线统一管理 Release，或先删掉手工上传的附件 |

排查顺序建议：

1. 看 **Restore release keystore** 步骤输出 —— 密钥本身是否 OK（字节数、alias 校验）
2. 看 **Build Release APK** 步骤里的 `[signing] release → ...` 行 —— 是否识别到正式签名
3. 看 **Verify APK is release-signed** 步骤 —— 是否仍在用 debug 证书

---

## 9. 安全自查清单

提交任何改动前跑一遍：

```bash
# 1) 确认仓库里没有任何密钥文件
git ls-files | grep -iE '\.(jks|keystore)$|key\.properties' || echo "OK: 无密钥文件入库"

# 2) 确认 .gitignore 生效（下面的文件应当不被列出）
git status --porcelain --ignored | grep -iE '\.jks' || true
```

- [ ] `flutter-app/android/.gitignore` 含 `key.properties`、`**/*.keystore`、`**/*.jks`
- [ ] keystore 只放在本地 + 私有备份，**没有**进入 Git 历史（若曾误提交，需 `git filter-repo` 清理并**重新生成密钥**）
- [ ] 口令只存在于 GitHub Secrets 与离线备份，`build.gradle.kts` / workflow 文件里**没有任何明文口令**
- [ ] 构建产物不被提交：`flutter-app/.gitignore` 已忽略 `/build/`
- [ ] 发布流水线使用一次性的 `ubuntu-latest` runner（密钥随容器销毁）
- [ ] 已记录证书 **SHA-256 指纹**，便于日后比对发布包来源
- [ ] 密钥一旦泄漏：立刻在 Google Play 后台重置上传密钥（需已启用 Play App Signing），并重新生成 jks + 更新 4 个 Secret

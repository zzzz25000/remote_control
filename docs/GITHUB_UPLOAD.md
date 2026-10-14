# 上传到 GitHub 并准备移动端云构建

本指南适用于当前 Flutter Android / iOS 项目。源码上传和生成安装包是两个步骤；上传后需要在仓库中添加适配本项目的 GitHub Actions 工作流。不需要另建一个“转换文件”的仓库，也不需要把源码提交到别人的仓库。

## 上传哪些内容

根目录 `.gitignore` 和 `android/.gitignore` 已调整：

| 内容 | 处理 |
| --- | --- |
| `lib/`、`android/`、`ios/` 源码、资源、Xcode / Gradle 工程 | 保留，是双端构建所需内容 |
| `pubspec.yaml`、`pubspec.lock`、`.metadata`、`analysis_options.yaml` | 保留，锁定依赖并记录 Flutter 工程配置 |
| Android Gradle Wrapper 脚本、JAR 和配置 | 保留，供云端使用对应 Gradle 版本 |
| `test/`、`stm32/`、README、来源说明、`docs/` | 保留，供回归检查、协议核对和说明使用 |
| 将来添加的 `.github/workflows/*.yml` / `.yaml` | 保留，GitHub Actions 通过它们定义构建任务 |
| `.dart_tool/`、`build/`、Gradle / Pods 缓存、生成配置 | 忽略，在构建机器上重新生成 |
| `android/local.properties`、IDE 设置、Xcode 用户状态 | 忽略，它们含本机路径或个人配置 |
| APK、AAB、IPA、Xcode archive、符号输出 | 忽略，构建后通过 Actions Artifacts 或 Releases 下载 |
| 私钥、签名证书、描述文件、`key.properties`、`.env` | 忽略，需要的签名材料放自己的 Actions Secrets |
| `linux/`、`web/`、`windows/` | 忽略，本次只发布双端移动工程；本地文件没有删除 |

不要忽略 `pubspec.lock`、整个 `ios/Runner.xcodeproj`、`ios/Runner.xcworkspace`、共享 Runner scheme、Flutter xcconfig 模板或图标资源。iOS 当前使用 Flutter 的 Swift Package 集成，保留已有 Xcode 配置；不要为了套用旧工作流凭空创建 Podfile。

## 首次上传：GitHub 仓库是空的

在 PowerShell 中执行；把最后的远程地址替换为你仓库页面上的 HTTPS 地址。

```powershell
Set-Location 'D:\project\BLE\ble'
git init -b main
git add .
git update-index --chmod=+x android/gradlew
git status --short
git diff --cached --stat
git commit -m "Initial Android and iOS BLE remote controller"
git remote add origin 'https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git'
git remote -v
git push -u origin main
```

`git update-index` 的这一项让 Gradle 启动脚本在 Linux / macOS 检出后可执行。提交前检查暂存列表中没有缓存、私钥和签名证书。命令行首次连接可能触发 Git Credential Manager 浏览器登录；GitHub HTTPS 不使用账户密码进行 Git 身份验证。

如果 `git commit` 提示身份未配置，只给本项目设置身份后重新提交：

```powershell
git config user.name '你的显示名'
git config user.email '你的 GitHub 提交邮箱'
git commit -m "Initial Android and iOS BLE remote controller"
```

可以使用 GitHub 个人设置提供的 noreply 提交邮箱。此处的名称和邮箱用于提交记录，不是登录凭据。以后上传改动使用：

```powershell
git add .
git diff --cached --stat
git commit -m "Describe the change"
git push
```

## GitHub 仓库已经有 README / 许可证 / 忽略文件

不要使用 `git push --force` 覆盖已有提交。推荐先把远程仓库克隆到另一个文件夹，再把本工程需要的文件复制进去，让远程历史保留下来。

```powershell
Set-Location 'D:\project\BLE'
git clone 'https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git' 'ble-github'
```

从当前工程复制 `.gitignore`、`.metadata`、`pubspec.yaml`、`pubspec.lock`、`analysis_options.yaml`、README、来源说明，以及 `lib/`、`android/`、`ios/`、`test/`、`stm32/`、`docs/`。包括目录内的 `.gitignore`，按需要合并仓库原有 README；保留已有许可证。不要复制 `build/`、`.dart_tool/`、本机路径和签名材料，也不要用当前工程覆盖克隆目录的 `.git/`。

然后在克隆目录执行：

```powershell
Set-Location 'D:\project\BLE\ble-github'
git add .
git update-index --chmod=+x android/gradlew
git status --short
git diff --cached --stat
git commit -m "Add Flutter BLE remote controller"
git push
```

如果分支不是 `main`，使用克隆后现有分支。Web 页面手动拖拽不会应用 `.gitignore`，所以这个项目优先使用 Git 上传。

## 使用现成构建工作流时必须匹配的配置

当前项目配置：Flutter 3.47.7 / Dart 3.13.5，Dart 约束 `^3.13.5`；Gradle 9.3.1；Android Gradle Plugin 9.1.0；JVM 编译目标 17。Android 工作流应准备兼容的 Java、Android SDK、Flutter，然后在仓库根目录构建整个 Flutter 工程，而不是只编译 Kotlin 目录。旧 Flutter 或只面向原生 Android 的模板不能直接照搬。

Android 构建步骤通常包含：

```sh
flutter pub get
flutter analyze lib test --no-pub
flutter test --no-pub
flutter build apk --release
```

APK 路径通常为 `build/app/outputs/flutter-apk/app-release.apk`。工作流还要使用 artifact 上传步骤保留该文件；成功后在仓库 Actions 的对应运行页面下载。上传源码本身不会自动生成 APK。

当前 Android release 配置沿用模板的 debug 签名，可供安装测试；如果希望后续 APK 能持续覆盖更新，需要配置并复用自己的固定签名密钥。私钥不放普通源码仓库，使用你自己的 Actions Secrets 提供。

iOS 需要 GitHub 的 macOS 运行器和兼容 Xcode，使用相同 Flutter 版本及现有 Xcode 工程。当前最低 iOS 版本是 15.0。无签名验证可以运行：

```sh
flutter pub get
flutter build ios --release --no-codesign
```

该命令验证设备版本编译，产物不能直接安装到普通 iPhone。可安装的 IPA 需要有效证书、Bundle ID、开发者 Team 和匹配的 provisioning profile，签名导出使用 `flutter build ipa` / Xcode；个人测试可选择 Ad Hoc 或 TestFlight。仅把无签名 `.app` 打成 `.ipa` 并不能免除安装签名要求。

复用他人仓库时，复用的是工作流/Action 的构建步骤，并将它们配置为检出你自己的项目。Fork 他人的原生 Android 应用不会自动构建这个 Flutter 项目。当前还没有选定工作流，也未添加或运行 `.github/workflows`；本指南不表示双端云构建已经验证成功。

## 官方说明

- [GitHub：上传本地代码](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)
- [GitHub：命令行身份验证](https://docs.github.com/en/get-started/git-basics/about-remote-repositories)
- [GitHub：为 macOS 工作流安装 Apple 签名证书](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Flutter：Android 构建与签名](https://docs.flutter.dev/deployment/android)
- [Flutter：iOS 构建与分发](https://docs.flutter.dev/deployment/ios)

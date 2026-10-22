# Android 固定签名

Debug 与 Release 都使用本目录的 `lokimetris.keystore` 和 `signing.properties`，不会自动退回机器默认签名。

首次在本机执行：

```sh
python3 scripts/prepare_android_signing.py
```

默认将原 `~/.android/debug.keystore` 中的开发证书复制为项目固定签名，使用随机密码重新封装，证书与公私钥保持不变，方便原有开发安装继续覆盖升级。这仍是开发证书，适用于当前本地 APK 分发，不用于应用商店发布。

真正首次安装、没有旧签名需要兼容时，可显式使用 `--new-key` 生成项目专用自签名证书。脚本不会覆盖已有密钥；重复执行仅验证现有文件。

密钥和密码均留在项目本地且被 Git 忽略。迁移电脑时一起安全备份这两个文件；不要重新生成签名来替代遗失文件。公开证书及指纹可以分享，私钥和密码不要发布。

仓库中的 `lokimetris-certificate.pem` 是已保存的公开证书参考。实际 APK 身份取决于本机 keystore；`--new-key` 不会更新该 PEM，生成新签名后需以新 keystore／APK 的证书为准。

签名一致只保证系统允许覆盖升级。卸载会删除 Android 私有配对材料，重装后需要重新配对；固定签名不能恢复已删除的配对数据。

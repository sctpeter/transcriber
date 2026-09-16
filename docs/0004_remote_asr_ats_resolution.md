# 远程 ASR GUI TLS 失败：ATS 根因与处理

## 现象

`Transcriber.app` 由 Finder / LaunchServices 启动时，远程 ASR 的
`URLSessionWebSocketTask` 在 `ServerTrust passed` 后报
`NSURLErrorSecureConnectionFailed (-1200)`；同一可执行文件直接以命令行自测启动则成功。

## 结论

根因是 App Transport Security（ATS），不是私有 CA、VPN、服务器或 WebSocket 协议。
`URLSession` 的手动 `SecTrust` 校验通过，不会取消 ATS 继续施加的 TLS / 证书策略。

## 验证

将已安装 App 复制到 `/tmp`，仅在副本的 `Info.plist` 加入：

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>
```

经 LaunchServices 启动该副本后，用户确认远程 ASR 立即成功连接。因此该单变量 A/B
实验确认 ATS 为根因。

## 处理

正式 App 同样设置 `NSAllowsArbitraryLoads=true`。此设置仅影响 Transcriber，而非系统或
其他 App；远程 ASR 仍要求 `RemoteAsrRefiner` 用指定私有 CA 完成 pinning。若未来增加
其他网络功能，应重新评估改为按服务器限定的 ATS 例外，或将服务器升级至完全符合 ATS。

## 验证命令

```bash
./test/test_remote_asr.sh
plutil -p /Applications/Transcriber.app/Contents/Info.plist
```

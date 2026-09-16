# Qwen3-ASR-1.7B 远程转写服务 —— wangtian03 部署记录

记录 2026-09-15/16 在 `wangtian03`(SSH 配置里 `Hostname 203.0.113.5`,一个跑
Ubuntu 24.04 的笔记本节点,i7-13700H / 20 线程 / 15GB RAM / 无独立 GPU,只有核显)
上部署这套服务的完整过程,包含中间踩过的坑。按顺序照抄基本能复现;换机器要重新
判断每一步的前提是否成立(有没有 GPU、有没有装 conda、内存多大等)。

## 目标架构

```
Transcriber.app (Mac 客户端) ──wss+mTLS──▶ qwen3_asr_gateway.py ──http(127.0.0.1)──▶ llama-server
                                            (证书认证,协议转换)      (真正跑 Qwen3-ASR-1.7B 推理)
```

两个服务都用 pm2 管理,开机自启。详细协议设计见仓库里的
`docs/0003_remote_qwen3_asr_protocol.md`。

## 0. 前置侦察

```bash
ssh wangtian03 'whoami && hostname && df -h ~ && nproc && grep "model name" /proc/cpuinfo | head -1'
ssh wangtian03 'lspci | grep -iE "vga|3d|nvidia|amd"'   # 确认只有核显,走 CPU 推理
ssh wangtian03 'sudo -n true'                            # 确认没有免密 sudo
```

结论:CPU-only 部署;`peter` 用户没有免密 sudo,需要装系统包时用单独配置的
`wangtian03-root`(同一台机器的 root SSH 别名)。**原则:只在真正需要 root 的步骤
才用 `-root`,其余全部用 `peter` 普通用户权限。**

## 1. 网络:出网要走代理,内网传输另算

这台机器直接访问 GitHub/HuggingFace 不稳定,配置了一个 WireGuard 出口代理
`203.0.113.2:7890`(HTTP 代理协议)。**教训:这个代理对单个长连接大文件下载不稳定,
平均每 ~10MB 就断一次**,下 2GB+ 的模型文件如果硬扛会转很多次重试、耗时数小时。

最终选择的下载路径(按优先级):
1. **人在机房、能连服务器所在局域网时**:直接查服务器局域网 IP,走局域网传输,
   实测 ~300MB/s,几秒钟传完 2.5GB。
2. **本地网络到 HuggingFace 直连没问题时**:在本地机器下载,再 `rsync`/`scp` 传到
   服务器,比经代理在服务器上直接下快很多。
3. 万不得已才在服务器上直接经代理下,并且要用 `curl -C -`(断点续传)包一层重试
   循环,不能指望一次性下完。

```bash
# 查服务器局域网 IP(人在机房时用这个,不要用 WireGuard IP,后者延迟高很多)
ssh wangtian03 "ip -4 addr show | grep -v '127.0.0.1' | grep inet"
# 例如输出: inet 172.25.2.26/24 ... wlp0s20f3 (局域网,DHCP动态分配)
#          inet 203.0.113.5/24 ... wg0        (WireGuard 隧道,机房外也能连)

# 确认局域网直连可用
ping -c 3 172.25.2.26
ssh -o ConnectTimeout=5 peter@172.25.2.26 'echo ok'
```

## 2. llama.cpp:下预编译二进制,不本地编译

这台机器没装 `cmake`,而且是纯 CPU 推理,没必要从源码编译。llama.cpp 官方 release
里有现成的 `llama-b<版本号>-bin-ubuntu-x64.tar.gz`,自带针对不同 CPU 微架构的
`libggml-cpu-*.so`(运行时自动探测选用哪个),解压即用:

```bash
ssh wangtian03 '
cd ~/transcriber_server
curl -L -x http://203.0.113.2:7890 -o llama-bin.tar.gz \
  "https://github.com/ggml-org/llama.cpp/releases/download/b10991/llama-b10991-bin-ubuntu-x64.tar.gz"
mkdir -p llama.cpp && tar xzf llama-bin.tar.gz -C llama.cpp && rm llama-bin.tar.gz
'
# 验证:注意要设 LD_LIBRARY_PATH,二进制和 .so 在同一目录
ssh wangtian03 'cd ~/transcriber_server/llama.cpp/llama-b10991 && LD_LIBRARY_PATH=. ./llama-server --version'
```

去 `https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5` 找具体
版本号(GitHub 的 `.../releases/latest` 对 llama.cpp 这个仓库只会返回一个没有真实
二进制的 nightly 占位 tag,要看完整列表)。

## 3. 模型文件

Qwen3-ASR-1.7B 是多模态模型(音频编码器 + LLM),GGUF 格式需要**两个文件**:主模型
和 `mmproj-*`(音频编码器/projector),官方仓库
`ggml-org/Qwen3-ASR-1.7B-GGUF` 都有:

```
Qwen3-ASR-1.7B-Q8_0.gguf        2,165,034,944 bytes
mmproj-Qwen3-ASR-1.7B-Q8_0.gguf   355,709,344 bytes
```

下载(本地机器直连 HuggingFace 更快,见上面第 1 节的路径选择):

```bash
curl -L --retry 3 -o Qwen3-ASR-1.7B-Q8_0.gguf \
  "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/Qwen3-ASR-1.7B-Q8_0.gguf"
curl -L --retry 3 -o mmproj-Qwen3-ASR-1.7B-Q8_0.gguf \
  "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf"
```

传到服务器后**务必校验 sha256**,大文件传输中途断线很常见,校验和对不上就是没传完:

```bash
shasum -a 256 *.gguf                              # 本地
ssh wangtian03 'sha256sum ~/transcriber_server/models/*.gguf'   # 远端
```

局域网内用 `rsync -av --progress --partial`(支持断点续传)比 `scp`(不支持断点续传,
断了要从头来)更稳妥:

```bash
rsync -av --progress --partial -e ssh \
  Qwen3-ASR-1.7B-Q8_0.gguf mmproj-Qwen3-ASR-1.7B-Q8_0.gguf \
  peter@172.25.2.26:~/transcriber_server/models/
```

## 4. Python 环境:用 conda,不用 venv

**教训**:第一次图省事直接 `python3 -m venv`,被指出这台机器/这个人平时的习惯是
conda,应该先确认再动手,不要自己拍板换工具链。系统自带 python3 甚至缺
`ensurepip`(装 venv 得先 `apt install python3.12-venv`,这一步要 root)。

```bash
ssh wangtian03 'command -v conda; ls -d ~/miniconda3'   # 先确认已装 conda
ssh wangtian03 '
source ~/miniconda3/etc/profile.d/conda.sh
conda create -y -n transcriber-asr python=3.11
conda activate transcriber-asr
pip install --proxy http://203.0.113.2:7890 -q websockets aiohttp
'
```

## 5. mTLS 证书:在开发机上生成,不在服务器上生成

CA 私钥不应该出现在服务器上。用仓库里的 `certs/make_remote_asr_certs.sh`,在**开发
机**(不是服务器)上跑:

```bash
cd certs
./make_remote_asr_certs.sh init                    # 生成私有 CA(只需一次)
./make_remote_asr_certs.sh server 203.0.113.5       # 用 WireGuard IP 签服务端证书
                                                     # (不要用局域网 IP,那个是 DHCP
                                                     #  动态分配的,不稳定;局域网访问
                                                     #  这次直接放弃,只走 VPN IP)
P12_PASS="$(openssl rand -base64 18)" ./make_remote_asr_certs.sh client transcriber-macbook-peter
# 密码随机生成,记下来填进 Transcriber 设置面板,不要用脚本默认密码
```

只把 `server.crt`、`server.key`、`ca.crt` 传到服务器;`ca.key` 和 `client.p12`
留在开发机(client.p12 是给 Transcriber.app 用的)。

```bash
scp certs/server/server.crt certs/server/server.key certs/ca/ca.crt \
    wangtian03:~/transcriber_server/certs/
```

## 6. 部署网关代码

```bash
scp server/qwen3_asr_gateway.py server/requirements.txt wangtian03:~/transcriber_server/
```

**踩坑**:llama-server 的转写输出不是纯文本(网关现走 `/v1/chat/completions`,见 docs/0006;
`/v1/audio/transcriptions` 的 `text` 与 chat 的 `message.content` 内容相同),实测(llama.cpp b10991 + Qwen3-ASR-1.7B-GGUF)是
`"language English<asr_text>实际转写内容"` 这种带标记的原始模型输出,不是纯文本。
`qwen3_asr_gateway.py` 里的 `extract_asr_text()` 专门处理这个(见该函数注释,升级
llama.cpp 版本后需要重新用真实音频验证这个格式有没有变)。

## 7. 用 pm2 跑起来 + 开机自启

服务器上已经有 `node`/`npm`(v18.19.1),但没有 pm2,且 npm 默认全局前缀
`/usr/local` 不可写。**不要为了装一个 npm 包就用 root**——改 npm 前缀到用户目录:

```bash
ssh wangtian03 '
mkdir -p ~/.npm-global
npm config set prefix "~/.npm-global"
npm install -g pm2
echo "export PATH=\$HOME/.npm-global/bin:\$PATH" >> ~/.zshrc
'
```

进程定义见仓库里的 `server/ecosystem.config.js`(两个 app:`qwen3-llama-server` 和
`qwen3-asr-gateway`)。**关键点**:
- gateway 的 `script` 直接指向 conda env 里的 python3 绝对路径
  (`~/miniconda3/envs/transcriber-asr/bin/python3`),不要指望 `conda activate`——
  pm2 起子进程不经过登录 shell,`activate` 设的环境变量不会生效。
- llama-server 默认 `n_ctx_slot` 是从模型元数据读的(这个模型是 65536),乘以默认
  `n_parallel`(4)= 262144 token 的 KV cache,实测吃了 **9.4GB 内存**(这台机器只有
  15GB,压力很大)。Transcriber 单句最长 28 秒(`AsrEngine.VAD.maxSpeechDuration`),
  用不到这么大 context,加上 `--ctx-size 4096 --parallel 2` 后降到 **2.9GB**。

```bash
scp server/ecosystem.config.js wangtian03:~/transcriber_server/
ssh wangtian03 '
export PATH=$HOME/.npm-global/bin:$PATH
cd ~/transcriber_server
pm2 start ecosystem.config.js
pm2 save
'
```

开机自启需要 root 注册一次 systemd unit(`pm2 startup` 会打印出具体命令,复制粘贴
到 `-root` 会话里执行,不要自己瞎编命令):

```bash
ssh wangtian03 'export PATH=$HOME/.npm-global/bin:$PATH; pm2 startup'
# 会打印类似这样一行,拿到 wangtian03-root 上执行:
#   sudo env PATH=$PATH:/usr/bin /home/peter/.npm-global/lib/node_modules/pm2/bin/pm2 \
#     startup systemd -u peter --hp /home/peter
```

**踩坑**:如果 pm2 daemon 已经是手动(非 systemd)启动的,`systemctl restart pm2-peter`
会失败(`Failed with result 'protocol'`——Type=forking 的 unit 等不到新 PID 文件,
因为 `pm2 resurrect` 发现 daemon 已经在跑,不会重新 fork)。**解决:先 `pm2 kill`
彻底杀掉手动起的 daemon,再用 `systemctl restart pm2-peter`,让 systemd 从零建立
它期望的进程树**,这样验证的才是真实开机自启会走的路径,不是自欺欺人。

```bash
ssh wangtian03 'export PATH=$HOME/.npm-global/bin:$PATH; pm2 kill'
ssh wangtian03-root 'systemctl restart pm2-peter && systemctl status pm2-peter --no-pager'
ssh wangtian03 'export PATH=$HOME/.npm-global/bin:$PATH; pm2 list'   # 确认两个 app 都 online
```

## 8. 验证

分层验证,从底层往上:

```bash
# 1) llama-server 本身(不经过网关/证书)
ssh wangtian03 'curl -s http://127.0.0.1:8080/v1/audio/transcriptions \
  -F model=qwen3-asr-1.7b-q8_0 -F file=@/tmp/test.wav'

# 2) 网关 + mTLS + 完整协议,从 Transcriber 客户端二进制发起真实请求
#    (--selftest-remote-asr 是专门为这个场景加的 CLI flag,见 SelfTest.swift)
.build/debug/Transcriber --selftest-remote-asr \
  "wss://203.0.113.5:8765/v1/transcribe" \
  "certs/client/client.p12" "<密码>" "certs/ca/ca.crt" 30
```

第 2 步能看到 `RemoteAsrRefiner: 已连接 ...` 日志、且拿到(哪怕是空字符串的)结果,
就说明整条链路——证书握手、协议编解码、llama-server 推理、`extract_asr_text` 解析——
全部打通了。

## 关键路径清单

| 内容 | 路径 |
|---|---|
| 部署根目录 | `~/transcriber_server` |
| llama-server 二进制 | `~/transcriber_server/llama.cpp/llama-b10991/llama-server` |
| 模型文件 | `~/transcriber_server/models/{Qwen3-ASR-1.7B-Q8_0.gguf,mmproj-*.gguf}` |
| 网关代码 | `~/transcriber_server/qwen3_asr_gateway.py` |
| 证书(服务端看到的) | `~/transcriber_server/certs/{server.crt,server.key,ca.crt}` |
| conda 环境 | `transcriber-asr`(`~/miniconda3/envs/transcriber-asr`) |
| pm2 进程定义 | `~/transcriber_server/ecosystem.config.js` |
| 日志 | `~/transcriber_server/logs/{llama-server,gateway}.{out,err}.log` |
| systemd unit | `/etc/systemd/system/pm2-peter.service` |

## 日常运维

```bash
ssh wangtian03 'export PATH=$HOME/.npm-global/bin:$PATH; pm2 list'          # 状态
ssh wangtian03 'export PATH=$HOME/.npm-global/bin:$PATH; pm2 logs'          # 实时日志
ssh wangtian03 'export PATH=$HOME/.npm-global/bin:$PATH; pm2 restart all'   # 重启
# 改完 ecosystem.config.js 或换模型文件后:
ssh wangtian03 'export PATH=$HOME/.npm-global/bin:$PATH; pm2 reload ecosystem.config.js && pm2 save'
```

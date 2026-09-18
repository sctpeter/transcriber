// pm2 进程定义,部署在 wangtian03 的 ~/transcriber_server/ecosystem.config.js。
// 用法见 server/RUNBOOK.md。两个服务开机自启靠 `pm2 startup` + `pm2 save`
// (startup 那一步要 root,其余都是普通用户权限)。
module.exports = {
  apps: [
    {
      name: "qwen3-llama-server",
      cwd: "/home/peter/transcriber_server/llama.cpp/llama-b10991",
      script: "./llama-server",
      args: [
        "--model", "/home/peter/transcriber_server/models/Qwen3-ASR-1.7B-Q8_0.gguf",
        "--mmproj", "/home/peter/transcriber_server/models/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf",
        "--host", "127.0.0.1",
        "--port", "8080",
        // 默认 n_ctx_slot=65536 (从模型元数据读的) * n_slots=4 = 262144 token 的 KV
        // cache,实测吃了 ~9GB RAM(这台机器总共 15GB)。Transcriber 这边单句最长
        // 28s(AsrEngine.VAD.maxSpeechDuration),用不到这么大 context,4096 足够
        // 留大量余量,把内存占用压到 ~1GB 量级。
        // parallel=1:只有一个客户端,且网关 handle_connection() 在同一连接上逐段
        // await,请求到 llama-server 本来就是严格串行的,第二个 slot 永远空闲。
        "--ctx-size", "4096",
        "--parallel", "1",
        // 关闭内存里的 prompt cache(默认上限 8192 MiB):每个请求只有模板 +
        // "Transcribe audio to text" 这几十个 token 相同,音频每句都不同,快照几乎
        // 复用不上;而每份快照都带整句音频的 KV,会让内存持续上涨(Linux 上该上限
        // 对多模态请求可能失效,见 llama.cpp issue #22629)。slot 自己的 KV cache
        // 不受影响。注意:启动日志仍会打印 "prompt cache is enabled, size limit:
        // 8192 MiB",这是已知的日志 bug(issue #22127),缓存实际已关闭。
        "--cache-ram", "0",
      ],
      env: { LD_LIBRARY_PATH: "." },
      autorestart: true,
      max_restarts: 10,
      out_file: "/home/peter/transcriber_server/logs/llama-server.out.log",
      error_file: "/home/peter/transcriber_server/logs/llama-server.err.log",
    },
    {
      name: "qwen3-asr-gateway",
      cwd: "/home/peter/transcriber_server",
      // 直接点 conda env 里的 python3,不走 `conda activate`(pm2 起进程不经过登录 shell,
      // activate 的环境变量设置不会生效)
      script: "/home/peter/miniconda3/envs/transcriber-asr/bin/python3",
      args: [
        "qwen3_asr_gateway.py",
        "--host", "0.0.0.0",
        "--port", "8765",
        "--cert", "certs/server.crt",
        "--key", "certs/server.key",
        // 2026-09-16 定的策略:私有局域网、人数少,不需要客户端证书认证,
        // 只做单向 TLS(还是校验服务端身份,只是不认证客户端是谁)。
        // 要重新收紧成双向 mTLS:取消下面这行注释,加上 CA 证书路径即可,
        // 客户端那边(Settings 面板)配上 clientIdentityPath 就会配合生效,
        // 不用改任何代码。
        // "--ca", "certs/ca.crt",
        "--llama-server-url", "http://127.0.0.1:8080",
        "--model-name", "qwen3-asr-1.7b-q8_0",
      ],
      autorestart: true,
      max_restarts: 10,
      min_uptime: "10s",
      restart_delay: 3000,
      out_file: "/home/peter/transcriber_server/logs/gateway.out.log",
      error_file: "/home/peter/transcriber_server/logs/gateway.err.log",
    },
  ],
};

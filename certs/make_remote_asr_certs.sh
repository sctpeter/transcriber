#!/bin/bash
# 生成远程 Qwen3-ASR 通道用的开发期 mTLS 证书体系:
#   1 个私有 CA + 1 张服务端证书(给部署 Qwen3-ASR 的远程机器)
#   + 1 张客户端证书(给跑 Transcriber.app 的本机,导出为 .p12 供 URLCredential 用)。
#
# 这套 CA 只用来认证"这个连接是不是我自己的 Transcriber 客户端/服务端",不需要也不
# 应该被系统信任库信任——Swift 端用 SecTrustSetAnchorCertificates 只信这一个 CA
# (见 docs/0003 / RemoteAsrRefiner.swift),Python 端用 ssl.SSLContext.load_verify_locations
# 同理。换机器不用重新生成整套 CA,只要用同一个 ca.key 再签一张新证书即可(见用法)。
#
# 用法:
#   ./certs/make_remote_asr_certs.sh init                     # 首次:生成 CA
#   ./certs/make_remote_asr_certs.sh server <hostname_or_ip>  # 签发服务端证书
#   ./certs/make_remote_asr_certs.sh client <client_name>     # 签发客户端证书(.p12)
set -euo pipefail
cd "$(dirname "$0")"

CA_DAYS=3650
LEAF_DAYS=825   # 公开 CA/浏览器早就不认 >825 天的证书了,自己的 CA 没这限制,但沿用这个惯例方便以后接商业 CA
P12_PASS="${P12_PASS:-transcriber-remote-asr}"

usage() {
    echo "用法:"
    echo "  $0 init"
    echo "  $0 server <hostname_or_ip>"
    echo "  $0 client <client_name>"
    exit 2
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage

case "$cmd" in
init)
    if [[ -f ca/ca.key ]]; then
        echo "✅ CA 已存在(ca/ca.key),跳过。要重新生成请先手动删除 certs/ca/"
        exit 0
    fi
    mkdir -p ca
    openssl req -new -newkey rsa:4096 -days "$CA_DAYS" -nodes -x509 \
        -subj "/CN=Transcriber Remote ASR Dev CA" \
        -keyout ca/ca.key -out ca/ca.crt \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    chmod 600 ca/ca.key
    echo "✅ CA 已生成: certs/ca/ca.{key,crt}(有效期 ${CA_DAYS} 天)"
    echo "   部署 Qwen3-ASR 网关和 Transcriber.app 的机器都需要 certs/ca/ca.crt(不需要 ca.key)"
    ;;

server)
    host="${2:-}"
    [[ -n "$host" ]] || { echo "用法: $0 server <hostname_or_ip>"; exit 2; }
    [[ -f ca/ca.key ]] || { echo "❌ 先跑: $0 init"; exit 1; }
    mkdir -p server
    # SAN 同时写 DNS 和 IP,openssl 不区分传的是哪种,写重复也无妨,握手按实际连接方式匹配其中一项
    openssl req -new -newkey rsa:2048 -nodes \
        -subj "/CN=$host" \
        -keyout server/server.key -out server/server.csr 2>/dev/null
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        san="subjectAltName=IP:$host"
    else
        san="subjectAltName=DNS:$host"
    fi
    openssl x509 -req -in server/server.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial \
        -days "$LEAF_DAYS" -out server/server.crt \
        -extfile <(printf "%s\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment" "$san")
    rm -f server/server.csr
    chmod 600 server/server.key
    echo "✅ 服务端证书已生成: certs/server/server.{key,crt}(CN=$host,有效期 ${LEAF_DAYS} 天)"
    echo "   部署到远程网关机器,配合 ca/ca.crt 一起用(见 server/README.md)"
    ;;

client)
    name="${2:-}"
    [[ -n "$name" ]] || { echo "用法: $0 client <client_name>"; exit 2; }
    [[ -f ca/ca.key ]] || { echo "❌ 先跑: $0 init"; exit 1; }
    mkdir -p client
    openssl req -new -newkey rsa:2048 -nodes \
        -subj "/CN=$name" \
        -keyout client/client.key -out client/client.csr 2>/dev/null
    openssl x509 -req -in client/client.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial \
        -days "$LEAF_DAYS" -out client/client.crt \
        -extfile <(printf "extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature") 2>/dev/null
    openssl pkcs12 -export -out client/client.p12 \
        -inkey client/client.key -in client/client.crt -certfile ca/ca.crt \
        -passout "pass:$P12_PASS" -name "$name"
    rm -f client/client.csr client/client.key client/client.crt
    chmod 600 client/client.p12
    echo "✅ 客户端证书已生成: certs/client/client.p12(CN=$name,密码见 \$P12_PASS 或默认值)"
    echo "   在 Transcriber 设置面板里把 remoteAsr.clientIdentityPath 指向这个文件"
    echo "   密码: ${P12_PASS}(生产环境请用 P12_PASS=xxx 环境变量覆盖,不要用默认密码)"
    ;;

*)
    usage
    ;;
esac

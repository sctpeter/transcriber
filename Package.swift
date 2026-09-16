// swift-tools-version: 5.10
import Foundation
import PackageDescription

// 包根目录的绝对路径(用于链接 third_party 预编译库)
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sherpaLib = "\(packageRoot)/third_party/sherpa-onnx/lib"
let deepFilterLib = "\(packageRoot)/third_party/deepfilternet/lib"

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    targets: [
        // sherpa-onnx C API(预编译动态库,由 fetch_sherpa.sh 下载到 third_party/)
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        // DeepFilterNet 官方 libdf C API(本地编译产物,由 fetch_deepfilter.sh 生成到 third_party/,
        // 见该脚本注释:upstream 没发布这个 C ABI 库的预编译包,只能本地 cargo-c 编译)
        .systemLibrary(name: "CDeepFilter", path: "Sources/CDeepFilter"),
        .executableTarget(
            name: "Transcriber",
            dependencies: ["CSherpaOnnx", "CDeepFilter"],
            path: "Sources/Transcriber",
            swiftSettings: [
                // 隐私:去掉二进制中内嵌的本机绝对路径(#file、断言信息等)
                .unsafeFlags(["-file-prefix-map", "\(packageRoot)=Transcriber"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(sherpaLib)",
                    "-lsherpa-onnx-c-api",
                    "-L\(deepFilterLib)",
                    "-ldeepfilter",
                    // 运行时查找顺序:app bundle 的 Frameworks → 开发目录的 third_party
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", sherpaLib,
                    "-Xlinker", "-rpath", "-Xlinker", deepFilterLib,
                ])
            ]
        ),
    ]
)

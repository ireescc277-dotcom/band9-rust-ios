# Band 9 Rust iOS

小米手环 9 自用客户端的第一阶段：**Rust 协议核心 + 原生 iOS 蓝牙诊断 App**。在 Windows 编辑代码和测试核心，通过 GitHub Actions 的 macOS runner 构建 iPhone 安装包。

## 当前能做什么

- 前台扫描 BLE，手动选择设备并连接。
- 列出实际发现的服务、特征及读写/通知属性。
- 将清单送入真正链接到 App 的 Rust 库，识别小米 V2 或旧 BLE 的候选通道。
- 按需读取标准电量、订阅候选 005E 通知，并导出诊断 JSON。
- Rust 核心提供有界 SPP V2 拆帧、CRC16、ACK/会话配置构造，以及 HMAC/HKDF/AES-CCM/AES-CTR 算法；这些由公开合成向量测试。

**这版没有进行手环认证，没有同步健康历史，也没有写入 Apple Health。** 发现 FE95/005E/005F 或读到电量不代表认证成功。手环 9 的具体固件、地区及 NFC 版本需要通过你的实机清单核实。

## 获取安装包

1. 打开 [GitHub 仓库](https://github.com/ireescc277-dotcom/band9-rust-ios)。
2. 打开 **Actions → Rust checks and unsigned iOS build**，查看 Rust 检查与 iOS 构建。
3. 在成功运行的 Artifacts 中下载 iOS 构建产物。解压后包含 `Band9Diagnostics-unsigned.ipa`、SHA256 和构建记录。
4. 使用自己的签名方式对 IPA 签名后安装。**unsigned IPA 是待签名包，不能直接安装。** 首版没有 HealthKit 等额外 entitlement，也不要求将 Apple 证书上传仓库。

工作流也支持 Actions 页手动运行。仓库可以公开；不要将设备密钥、签名证书或真实诊断导出提交进来。签名后能否安装仍需要真实设备验证。

## 手机上怎么测

1. 打开 App，点开始扫描，允许蓝牙权限，保持手环靠近。
2. 选择自己的手环。等待连接、服务和特征发现完成。
3. 查看 Rust 的通道判型和实际 UUID。连接失败或清单不完整时，保留日志，不要恢复出厂或解除原有绑定。
4. 可以手动读取标准电量或订阅 005E。该操作不发送小米认证和健康文件消费命令。
5. 导出诊断 JSON，回传用于下一轮适配。导出文件含设备名、系统分配的设备标识和蓝牙服务清单；请勿直接放进公开仓库。

## 开发结构

```text
crates/band9-core/       Rust 封包、校验、密码算法和协议测试
crates/band9-ffi/        Rust 设备判型与小型 C ABI
ios/Band9Diagnostics/   SwiftUI / CoreBluetooth / JSON 导出
ios/project.yml         XcodeGen 工程定义
scripts/build-ios.sh    Rust 与 Xcode 构建、IPA 打包和校验
.github/workflows/      Linux 核心测试、macOS iOS 构建
```

首版只有三个跨语言入口，通过 C ABI 传递 JSON 和版本字符串。这样无需在 iOS 里嵌入异步 Rust 运行时。蓝牙对象及回调由 Swift 管理，协议计算保留在 Rust；以后需要更丰富的类型接口时可以迁移到 UniFFI。

## Windows 本地测试

需要 Rust 和 MSVC C++ Build Tools。推荐将下载、编译及临时缓存放在空间充足的磁盘：

```powershell
$env:CARGO_HOME = 'F:\CodexBuild\band9-rust-ios\cargo-home'
$env:CARGO_TARGET_DIR = 'F:\CodexBuild\band9-rust-ios\target'
$env:TEMP = 'F:\CodexBuild\band9-rust-ios\temp'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Force $env:CARGO_HOME,$env:CARGO_TARGET_DIR,$env:TEMP | Out-Null
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```

工具链固定在 `rust-toolchain.toml`。若已有名为 stable、版本同为 1.98.1 的工具链，本地可用 `cargo +stable` 避免再次下载同版本；CI 仍安装固定版本。`Cargo.lock` 纳入版本控制。

## 构建和证据边界

- Windows 测试验证算法、流处理、UUID 判型和 FFI 逻辑。
- GitHub macOS 构建验证 Rust/Swift 实际编译链接和 iPhone ARM64 包结构。
- 成功构建不能验证签名安装、蓝牙连通、认证或健康数据准确性。
- 真机测试阶段才确认该手环的通道、固件行为和系统权限表现。

后续顺序：完成实际通道确认 → 接入设备密钥和认证 → 保留并解析健康原始文件 → Apple Health → 后台恢复。

## 协议资料

本项目新增源码依据公开协议事实独立编写，不包含 my-band 的 Swift 源码或 Gadgetbridge 的生成 schema。依赖由 Cargo 管理，各自许可随依赖适用。后续直接移植外部代码或 schema 时需另行记录来源许可。

- [my-band 固定参考版本](https://github.com/matheusdanoite/my-band/tree/56a8109bff3760bf05ba06c19e26ce2c51f6eea8)
- [Gadgetbridge 手环 9 支持说明](https://gadgetbridge.org/gadgets/wearables/xiaomi/#mi-band-9)
- [Gadgetbridge 固定归档源码](https://github.com/Freeyourgadget/Gadgetbridge/tree/a0948ee1cbc2a870f91d313f8e37df5f524465f7)

测试中的 nonce 和密钥都是公开合成值，不对应任何真实设备。V2 的 CTR 初始计数器等于方向会话密钥，是设备兼容要求，不用于设计新的加密协议。

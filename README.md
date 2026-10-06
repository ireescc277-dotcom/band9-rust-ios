# 手环伴侣 · Band 9 Rust iOS

Rust 协议核心 + SwiftUI / CoreBluetooth 客户端，iOS 17+。在 Windows 开发，通过公开 GitHub 仓库的标准 macOS runner 构建待签名 IPA。

## 0.3.0 功能

同一 App 提供三套原生界面，在首页右上角切换，设备连接、密钥和健康档案共用：

| 界面 | 主要用途 |
| --- | --- |
| Watch 管理版（默认） | 我的手表、表盘图库、发现；设备状态与分组设置 |
| 健康生活版 | 今天、记录、我的手环；活动卡片、按日期查看健康记录 |
| 数据分析版 | 概览、数据、设备；7/30 天活动趋势、样本数量与导出 |

表盘图库提供六种本机设计，可调整颜色、字形和信息组件并收藏；**尚不能上传到手环**。步数目标也是本 App 偏好，不会修改手环设置。各家 App 的功能与数据来源比较见 [产品研究](docs/PRODUCT-RESEARCH.md)。

- **发现与连接**：扫描附近设备，同时读取系统已连接的 FE95 / FEE0 / 180D 设备；保存的设备可按 UUID 重新查找。系统蓝牙“已连接”与本应用认证状态分开显示。
- **密钥与认证**：手动输入或文件导入 16 字节设备密钥，按设备保存到 Keychain；安全随机 nonce、V2 协商、HMAC 校验、CCM 认证、ACK、分片与有限重试在真实调用链中接通。
- **数据同步**：认证后读取设备信息和电量；手动同步今日/历史健康文件，串行下载、CRC32 核验、原始文件落盘、归一化和去重。
- **本地页面**：三种界面展示同一份真实记录；未同步时显示空状态，不填入模拟数值。每日汇总与分钟明细不会重复相加；缺样本日期不作为零计入日均。健康文件可由用户主动导出。
- **故障定位**：诊断放在二级页面，报告包含扫描候选、系统已连接候选、服务、连接/认证状态及日志；不包含设备密钥。

当前协议适配器支持 **FE95 服务下 RX=005E / TX=005F 的 V2 通道**。已在一只小米手环 9 陶瓷特别版（`miwear.watch.n66tc`）完成 BLE 连接、认证、加密电量请求以及活动文件同步和保存的实机验证。旧 0051/0052 和 Classic-only 通道不能直接使用这套适配器；其他型号、地区和固件尚需分别验证。

### 解析覆盖

| 文件布局 | 输出 |
| --- | --- |
| 每分钟活动 v1–4 | 步数、能量、距离、心率；v3+ 血氧 |
| 每日汇总 v3/v5 | 每日步数、能量 |
| 手动测量 v2 | 心率、血氧 |
| 睡眠转折点 v2 / 阶段包 v1–5 | 结构明确的睡眠分期 |

未知版本、运动/GPS及有歧义的布局会保留原始文件，界面说明未解析；不从睡眠汇总伪造阶段。没有实现表盘上传、通知转发、天气或 Apple Health 写入。本版保留后台连接但暂停主动同步，前台恢复；未实现持续后台同步服务。

## 安装与使用

1. 在 [Actions](https://github.com/ireescc277-dotcom/band9-rust-ios/actions/workflows/ci.yml) 下载最新成功运行的 `Band9Diagnostics-unsigned-*` 构建产物。
2. 对其中 IPA 签名安装。它是 iPhone arm64 **未签名包，不能直接安装**；保留 `org.band9lab.diagnostics` Bundle ID 可更新之前的诊断版。
3. 在 Watch 版点击“所有手表”，或在另外两版进入设备页。若已有导入文件，可点“从设备文件连接”，选择自己的设备记录；记录含有效蓝牙 UUID 时会直接尝试连接。把 `private-band-auth-key.json` 放在 App 的“文件”目录后，设备页会出现“导入已准备的手环”入口。
4. 也可查找附近手环并选择设备，再输入对应 auth key。已被系统或 Mi Fitness 连接的设备会尝试列入候选列表。App 按设备将密钥保存在 Keychain，并在匹配的 V2 通道上执行认证；名称本身不能确认设备型号。
5. 认证成功后点击同步，在健康、活动记录或分析页查看结果。未知格式可导出原始文件用于适配。

### 获取自己的 auth key

从 Mi Fitness **主动导出的文件**或已有本地备份中取得 `MHWCahe/.../VirtualDevice_registerList/manifest.sqlite`。导出目录不可见、缓存缺失或 USB 文件共享被 iOS 拒绝时，脚本不能绕过这个限制。

```powershell
python scripts/extract-auth-key.py 'F:\your-private-mi-fitness-export' --out 'F:\private-band-auth-key.json'
```

脚本只读所有 `registerList_*` 地区记录，不把密钥打印到终端，也不覆盖已有文件。输出文件可在 App 里导入；多设备时由用户选择。不要把真实密钥、原始导出、签名证书或诊断数据提交到公开仓库。普通第三方 iOS App 不能任意读取 Mi Fitness 私有容器。

## 开发与验证

```text
crates/band9-core/       帧、密码、Protobuf、认证会话、健康文件解析
crates/band9-ffi/        清单诊断与有生命周期的 C ABI 会话
 ios/Band9Diagnostics/  SwiftUI、蓝牙、Keychain、本地健康档案
scripts/                macOS 构建与本地只读密钥导入工具
```

Windows 需要 Rust 和 MSVC C++ Build Tools，缓存建议放在空间充足的磁盘：

```powershell
$env:CARGO_HOME = 'F:\CodexBuild\band9-rust-ios\cargo-home'
$env:CARGO_TARGET_DIR = 'F:\CodexBuild\band9-rust-ios\target'
$env:TEMP = 'F:\CodexBuild\band9-rust-ios\temp'
$env:TMP = $env:TEMP
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --all-targets --locked
python -m unittest discover -s scripts -p 'test_*.py'
```

工具链固定在 `rust-toolchain.toml`；已有相同版本 stable 时可用 `cargo +stable`。CI 验证 Rust，再在 macOS 编译链接 Swift 和 Rust，校验 IPA 的 ZIP、设备平台、架构和摘要。构建 4 已通过 CI，并在本地签名后通过 Wi-Fi 覆盖安装到 iPhone，读回确认版本 0.2.0 / 构建 4。实机验证了协议认证、加密电量请求、活动文件下载、原始文件 CRC、保存和重复同步去重；本次样本包含步数、距离和活动能量。心率、血氧及睡眠解析目前只有合成测试，尚无对应实机样本；数值与官方 App 的逐项对照也未完成。签名材料、设备标识、真实密钥和健康样本不在仓库中。

协议来源、密钥限制和验收步骤见 [协议说明](docs/PROTOCOL.md)。新增实现依据公开协议事实独立编写，没有复制 my-band 的 Swift 源码或 Gadgetbridge 的生成 schema。测试使用公开合成密钥；不发送健康文件消费命令 8/5。

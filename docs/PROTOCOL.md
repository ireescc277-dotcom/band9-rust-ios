# 后续协议接入

本文记录当前实现和验证边界。**构建 4 已在小米手环 9 陶瓷特别版（`miwear.watch.n66tc`）完成通道、协议认证、加密电量请求以及活动文件同步验证。** 当前实机样本覆盖步数、距离和活动能量；心率、血氧、睡眠及其他型号仍待对应样本验证。算法测试、iOS 构建成功和标准 GATT 电量读取不能替代这些协议验收。

## 先确认实际通道

从手机视角，候选 BLE 通道如下；UUID 都使用后缀 `-0000-1000-8000-00805F9B34FB`。

| 用途 | V2 候选 | 旧 BLE 候选 |
| --- | --- | --- |
| 服务 | `0000FE95` | `0000FE95` |
| RX：手环 → 手机，通知/指示 | `0000005E` | `00000051` |
| TX：手机 → 手环，写入 | `0000005F` | `00000052` |

V2 方向以 my-band 的实际常量及回调为准：**RX=005E，TX=005F**；该固定版本文件顶部注释曾写反，不能照抄。[my-band UUID 常量][my-uuid]、[接收回调][my-manager]针对其 Band 10 实现，不构成所有 Band 9 固件的验证。

必须在同一个 FE95 服务中同时找到属性正确的 RX/TX，再选择协议适配器。发现旧 BLE 候选时，不能只换 UUID 后继续发 V2 帧。Gadgetbridge 的[固定归档 Band 9 coordinator][gb-band9]使用 Bluetooth Classic；其[SPP 实现][gb-spp]先请求版本，响应首字节至少为 2 时才切换 V2。这些是 Android 参考实现的行为，不能推导为 Band 9 在 iOS 上一定可用或一定不可用。当前固件、地区、普通/NFC 版本均需记录。

## 已实现的 Rust 能力

| 模块/API | 当前作用 |
| --- | --- |
| `frame::build_frame`、`parse_frame`、`StreamDecoder::push/reset` | 有界封包、CRC16、分片/黏包与损坏数据后的重新同步 |
| `frame::build_ack`、`SessionConfig::build` | 构造传输 ACK、会话启动配置；session 模块实现单命令串行、有限重试和协商 |
| `crypto::SessionKeys::derive_verified`、`phone_hmac` | HKDF 派生方向密钥、验证手环证明、生成手机证明 |
| `encrypt_auth_info`、`ccm_encrypt/decrypt`、`encrypt_v2/decrypt_v2` | 认证 CCM 与 V2 CTR 字节计算；不负责随机数、连接或认证流程 |
| `battery_command()` | 返回只读电量请求的 Protobuf 字节，不发送请求 |
| C ABI 三个入口 | `band9_core_version`、`band9_diagnose_json`、`band9_string_free`；原有版本与清单诊断；另有 session_create/command/free 三个会话入口 |

`SessionKeys` 的 Debug 输出已隐藏密钥，持有的秘密数组在释放时清零。调用方仍须保护输入副本。当前已接入 Keychain 密钥导入、所需 Protobuf 字段、认证会话句柄和健康解析。未知布局与未实现的功能以 README 的覆盖表为准。

## V2 帧与认证

[Gadgetbridge V2 帧实现][gb-v2]采用以下顺序，长度与 CRC 均为小端：

```text
A5 A5 | type/flags:u8 | sequence:u8 | payloadLength:u16 | CRC16:u16 | payload
DATA payload = channel/flags:u8 | opcode:u8 | body
```

CRC 为 CRC-16/ARC，只覆盖 payload。帧 type 1/2/3 分别为传输 ACK、会话配置、DATA；DATA channel 1 为 Protobuf，5 为活动文件，2 为上传数据；opcode 1 为明文，2 为加密。一次 BLE 通知不保证是一帧。写入必须按 CoreBluetooth 实际允许的长度分块，并处理流控、断线和超时；不能把 `SessionConfig` 的配置数值当作已实现的发送窗口。

会话配置的版本 TLV 是对端报告的三字节版本，不要求与请求值 `[1, 0, 0]` 相等。实机回复 `[2, 1, 9]`，它不是手环固件版本。构建 3 错误地要求版本相等，导致收到第一条配置回复后就断开；构建 4 改为验证字段长度、记录对端版本并继续认证，同时保留 TLV 边界及重复字段校验。

[认证参考][gb-auth]使用 `Command(type=1, subtype=26)` 交换随机数，随后用 subtype 27 发送手机证明及设备信息。令 P/W 分别为手机/手环的 16 字节 nonce，K 为 16 字节 auth key：

- HKDF-SHA256：salt=`P || W`，IKM=`K`，info=`miwear-auth`，输出 64 字节。
- 输出 `[0..16)` 是 RX key，`[16..32)` 是 TX key，`[32..36)` / `[36..40)` 是 RX/TX nonce 前缀。
- 手环证明为 `HMAC-SHA256(RX key, W || P)`；手机证明为 `HMAC-SHA256(TX key, P || W)`。
- 认证设备信息用 AES-128-CCM：nonce=`TX 前缀 || 8 个零字节`，tag 4 字节，无 AAD。每次连接生成新的安全随机 P；这份认证 nonce 不重复用于多条消息。
- **认证后的 V2 body 使用 AES-128-CTR，初始计数器等于该方向的 session key**；不是继续使用 CCM。CTR 本身不提供消息认证，这是兼容现有设备协议的参数。

认证外层帧仍是明文 DATA；其中的设备信息字段单独做 CCM。Protobuf 必须保留需要显式发送的零值和字段存在性；不能默认套用省略零值的 proto3 行为。本仓库未包含外部 schema，已实现所需的最小字段和未知字段跳过能力。

## 自己设备的 auth key

[xiaomi-band-ios-export 的固定实现][key-source]在用户主动导出的 Mi Fitness 文件中寻找：

```text
MHWCahe/<用户目录>/VirtualDevice_registerList/manifest.sqlite
  → manifest.inline_data 中的二进制 plist
  → 设备记录的 encryptKey 或 encrypt_key
  → 32 位十六进制字符串，即 16 字节
```

该版本查询硬编码为 `registerList_de`；其他地区应先枚举实际 `registerList_*` 记录，不能宣称现成脚本已覆盖所有地区。按设备记录匹配自己的手环，并在手机本地导入 Keychain；不要把 key、整个导出目录或含密钥日志提交到仓库或 Actions。

[上游 README][key-readme]描述了从“文件 → 我的 iPhone → Mi Fitness”压缩导出的办法，并声明测试对象为 Band 10。**Files 只显示 App 主动开放的文档，不提供整个私有沙盒的任意读取权限**；对应版本不显示目录，或导出缺少缓存时，这条路径就尚不可用。普通自研 App 也不能直接读取另一 App 的私有容器。[Apple 文件共享说明][apple-files]说明共享的是应用 Documents 目录。不要为了提取 key 先解绑或恢复出厂；绑定关系变化后旧 key 可能失效。

## 健康同步与下一步

健康同步有两层：[Protobuf 控制命令][gb-health]请求今日/历史文件清单和指定文件；活动通道传回版本化二进制文件。[文件接收实现][gb-files]先重组分片，再检查文件尾 CRC32，按 7 字节 file ID 的类型、子类型、版本分发解析器。健康文件不能直接当成一整条 Protobuf 解码。

必须区分两种 ACK：V2 type 1 是维持传输的帧确认；健康命令 `type=8/subtype=5` 是文件消费确认，可能使设备将历史标记为已同步。原型继续发送必要的传输 ACK，但默认保留设备历史；完成原始文件持久化、CRC 验证及解析后，再决定是否启用消费确认。

实机验收记录：

1. FE95 同服务下的 005E 通知和 005F 写入已确认，完整服务发现和通知订阅成功。
2. Rust 会话经 C ABI 与 CoreBluetooth 完成配置协商、随机数交换、HMAC 校验、手机证明和认证响应验证。
3. 认证后的 CTR 加密电量请求已收到并解析对应回复。
4. 活动文件已完成下载、CRC32 校验、原始 JSON/二进制持久化；重复同步后文件和记录没有重复累加。
5. 尚待验证：健康数值与官方 App 逐项对照、心率/血氧/睡眠真实样本、其他固件和型号。Apple Health 写入未实现。

本文只整理协议事实和本仓库 API，没有复制外部源码或 schema。Gadgetbridge 参考代码为 AGPL-3.0-or-later；后续直接移植实现或 schema 时应另行记录来源及许可。

[my-uuid]: https://github.com/matheusdanoite/my-band/blob/56a8109bff3760bf05ba06c19e26ce2c51f6eea8/My%20Band/BLE/Services/MiBandUUID.swift#L20-L27
[my-manager]: https://github.com/matheusdanoite/my-band/blob/56a8109bff3760bf05ba06c19e26ce2c51f6eea8/My%20Band/BLE/BandManager.swift#L1469-L1472
[gb-band9]: https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/xiaomi/miband9/MiBand9Coordinator.java#L44-L53
[gb-spp]: https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/XiaomiSppSupport.java#L273-L293
[gb-v2]: https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/XiaomiSppPacketV2.java
[gb-auth]: https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/XiaomiAuthService.java
[key-source]: https://github.com/artyomxx/xiaomi-band-ios-export/blob/597568b79396d03a64ee5f57bcfa9ab2c98cbc4c/band_export/extract_key.py#L54-L95
[key-readme]: https://github.com/artyomxx/xiaomi-band-ios-export/blob/597568b79396d03a64ee5f57bcfa9ab2c98cbc4c/README.md
[apple-files]: https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/iPhoneOSKeys.html
[gb-health]: https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/services/XiaomiHealthService.java#L783-L862
[gb-files]: https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/activity/XiaomiActivityFileFetcher.java#L75-L150

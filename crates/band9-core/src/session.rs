//! Stateful V2 session. The platform supplies fresh secure randomness, a
//! monotonic millisecond clock, and ordered BLE writes. No historical-consumption
//! acknowledgement (command 8/5) is constructed anywhere in this engine.

use crate::{
    crypto::SessionKeys,
    frame::{self, Frame, SessionConfig, StreamDecoder},
    health::ActivityAssembler,
    proto::{self, Message},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashSet, VecDeque};
use zeroize::{Zeroize, Zeroizing};

const RESPONSE_TIMEOUT: u64 = 30_000;
const MAX_RETRIES: u8 = 2;
const MAX_FILES: usize = 512;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionOptions {
    #[serde(default)]
    pub key_hex: String,
    #[serde(default)]
    pub phone_nonce_hex: String,
    #[serde(default = "default_mtu")]
    pub mtu: usize,
    #[serde(default = "default_phone_name")]
    pub phone_name: String,
    #[serde(default = "default_api_level")]
    pub phone_api_level: f32,
    #[serde(default = "default_region")]
    pub region: String,
    #[serde(default = "default_device_type")]
    pub device_type: u32,
    #[serde(default = "default_capability")]
    pub app_capability: u32,
}

fn default_mtu() -> usize {
    20
}
fn default_phone_name() -> String {
    "iPhone".into()
}
fn default_api_level() -> f32 {
    18.0
}
fn default_region() -> String {
    "CN".into()
}
fn default_device_type() -> u32 {
    1
}
fn default_capability() -> u32 {
    224
}

impl Default for SessionOptions {
    fn default() -> Self {
        Self {
            key_hex: String::new(),
            phone_nonce_hex: String::new(),
            mtu: 20,
            phone_name: "iPhone".into(),
            phone_api_level: 18.0,
            region: "CN".into(),
            device_type: 1,
            app_capability: 224,
        }
    }
}

impl Drop for SessionOptions {
    fn drop(&mut self) {
        self.key_hex.zeroize();
        self.phone_nonce_hex.zeroize();
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionRequest {
    Battery,
    DeviceInfo,
    SyncHealth,
    RequestFile { file_id_hex: String },
    FileReceived { file_id_hex: String },
    Disconnect,
}

#[derive(Debug, Serialize)]
pub struct Outbound {
    pub hex: String,
    pub priority: u8,
}

#[derive(Debug, Serialize)]
pub struct SessionEvent {
    pub kind: String,
    pub message: String,
    pub data: Value,
}

#[derive(Debug, Serialize)]
pub struct SessionUpdate {
    pub state: String,
    pub outbound: Vec<Outbound>,
    pub events: Vec<SessionEvent>,
    pub error: Option<String>,
}

impl SessionUpdate {
    fn event(&mut self, kind: &str, message: impl Into<String>, data: Value) {
        self.events.push(SessionEvent {
            kind: kind.into(),
            message: message.into(),
            data,
        });
    }
    fn problem(&mut self, message: impl Into<String>) {
        let message = message.into();
        self.error = Some(message.clone());
        self.event("protocol_error", message, json!({}));
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Task {
    Negotiate,
    Nonce,
    Auth,
    Battery,
    DeviceInfo,
    Today,
    Past,
    File(String),
}

struct Pending {
    task: Task,
    frame: Vec<u8>,
    sequence: Option<u8>,
    sent_at: u64,
    progress_at: u64,
    retries: u8,
    acked: bool,
}

pub struct Session {
    key: Zeroizing<[u8; 16]>,
    nonce: Zeroizing<[u8; 16]>,
    device_info: Vec<u8>,
    keys: Option<SessionKeys>,
    decoder: StreamDecoder,
    state: &'static str,
    sequence: u8,
    mtu: usize,
    max_payload: usize,
    ack_timeout: u64,
    pending: Option<Pending>,
    queue: VecDeque<Task>,
    received: VecDeque<(u8, [u8; 32])>,
    assembler: ActivityAssembler,
    file_ids: HashSet<String>,
    sync_active: bool,
    sync_failures: usize,
    last_now: u64,
    pairing_until: Option<u64>,
}

impl Session {
    pub fn new(mut options: SessionOptions) -> Result<Self, String> {
        let key_result = decode_array::<16>(&options.key_hex, "key_hex");
        options.key_hex.zeroize();
        let key = Zeroizing::new(key_result?);
        let nonce_result = decode_array::<16>(&options.phone_nonce_hex, "phone_nonce_hex");
        options.phone_nonce_hex.zeroize();
        let nonce = Zeroizing::new(nonce_result?);
        if !(1..=1024).contains(&options.mtu) {
            return Err("mtu must be between 1 and 1024".into());
        }
        if options.phone_name.is_empty()
            || options.phone_name.len() > 96
            || options.region.len() != 2
            || !options.region.bytes().all(|c| c.is_ascii_uppercase())
            || !options.phone_api_level.is_finite()
            || options.phone_api_level <= 0.0
        {
            return Err("invalid phone information or two-letter uppercase region".into());
        }
        Ok(Self {
            key,
            nonce,
            device_info: proto::device_info(
                options.device_type,
                options.phone_api_level,
                &options.phone_name,
                options.app_capability,
                &options.region,
            ),
            keys: None,
            decoder: StreamDecoder::new(64512, 65536).map_err(|e| e.to_string())?,
            state: "idle",
            sequence: 0,
            mtu: options.mtu,
            max_payload: 64512,
            ack_timeout: 10_000,
            pending: None,
            queue: VecDeque::new(),
            received: VecDeque::new(),
            assembler: ActivityAssembler::new(),
            file_ids: HashSet::new(),
            sync_active: false,
            sync_failures: 0,
            last_now: 0,
            pairing_until: None,
        })
    }

    pub fn start(&mut self, now_ms: u64) -> SessionUpdate {
        let mut out = self.output();
        if self.state != "idle" {
            out.problem("create a fresh session with a fresh phone nonce before reconnecting");
            return out;
        }
        self.last_now = now_ms;
        self.state = "negotiating";
        let config = SessionConfig {
            transmit_window: 1,
            ..SessionConfig::default()
        }
        .build();
        self.set_pending(Task::Negotiate, config, None, now_ms, &mut out);
        out.event(
            "connecting",
            "正在协商手环通信",
            json!({"protocol":"spp_v2"}),
        );
        self.finish(out)
    }

    pub fn receive(&mut self, bytes: &[u8], now_ms: u64) -> SessionUpdate {
        let mut out = self.output();
        if !self.time(now_ms, &mut out) {
            return out;
        }
        if matches!(self.state, "idle" | "failed" | "disconnected") {
            out.problem("session is not receiving data");
            return out;
        }
        let batch = match self.decoder.push(bytes) {
            Ok(b) => b,
            Err(e) => {
                out.problem(e.to_string());
                return out;
            }
        };
        for error in batch.errors {
            out.event("frame_error", error.to_string(), json!({}));
        }
        for frame in batch.frames {
            if self.state == "failed" {
                break;
            }
            if let Err(error) = self.on_frame(frame, now_ms, &mut out) {
                if self.state == "ready" {
                    out.problem(error);
                } else {
                    self.fail(error, &mut out);
                }
            }
        }
        self.pump(now_ms, &mut out);
        self.finish(out)
    }

    pub fn tick(&mut self, now_ms: u64) -> SessionUpdate {
        let mut out = self.output();
        if !self.time(now_ms, &mut out) {
            return out;
        }
        let expired = self.pending.as_ref().is_some_and(|p| {
            if self.pairing_until.is_some_and(|until| now_ms < until) {
                return false;
            }
            if p.acked {
                now_ms.saturating_sub(p.progress_at) >= RESPONSE_TIMEOUT
            } else {
                now_ms.saturating_sub(p.sent_at) >= self.ack_timeout
            }
        });
        if let Some(mut pending) = if expired { self.pending.take() } else { None } {
            if pending.retries < MAX_RETRIES {
                pending.retries += 1;
                self.decoder.reset();
                pending.sent_at = now_ms;
                pending.progress_at = now_ms;
                if pending.acked {
                    // A semantic response/file stalled after its transport ACK.
                    // Start a fresh command sequence, rather than replaying an
                    // already acknowledged sequence the peer may suppress.
                    if let Some(sequence) = pending.sequence.as_mut() {
                        *sequence = self.next_sequence();
                        pending.frame[3] = *sequence;
                    }
                    if matches!(pending.task, Task::File(_)) {
                        self.assembler.reset();
                        self.received.clear();
                    }
                }
                pending.acked = false;
                self.emit(&pending.frame, 1, &mut out);
                out.event(
                    "retry",
                    "通信超时，正在重试",
                    json!({"attempt":pending.retries,"sequence":pending.sequence}),
                );
                self.pending = Some(pending);
            } else if self.state != "ready" {
                self.fail(
                    "手环认证或通信协商超时，请检查手环上的确认提示".into(),
                    &mut out,
                );
            } else {
                self.sync_failures += usize::from(matches!(
                    pending.task,
                    Task::Today | Task::Past | Task::File(_)
                ));
                self.assembler.reset();
                out.event(
                    "request_failed",
                    "手环未完成本次请求",
                    json!({"file_id":match pending.task { Task::File(id)=>Some(id), _=>None }}),
                );
            }
        }
        self.pump(now_ms, &mut out);
        self.finish(out)
    }

    pub fn request(&mut self, request: SessionRequest, now_ms: u64) -> SessionUpdate {
        let mut out = self.output();
        if !self.time(now_ms, &mut out) {
            return out;
        }
        if matches!(request, SessionRequest::Disconnect) {
            self.state = "disconnected";
            self.clear();
            return self.finish(out);
        }
        if self.state != "ready" {
            out.problem("手环尚未完成认证");
            return out;
        }
        if self.queue.len() >= MAX_FILES + 8 {
            out.problem("request queue is full");
            return out;
        }
        match request {
            SessionRequest::Battery => self.enqueue_unique(Task::Battery),
            SessionRequest::DeviceInfo => self.enqueue_unique(Task::DeviceInfo),
            SessionRequest::SyncHealth => {
                if self.sync_active {
                    out.event("sync_in_progress", "健康数据正在同步", json!({}));
                } else {
                    self.sync_active = true;
                    self.sync_failures = 0;
                    self.file_ids.clear();
                    self.enqueue_unique(Task::Today);
                    self.enqueue_unique(Task::Past);
                    out.event("sync_started", "正在读取健康数据目录", json!({}));
                }
            }
            SessionRequest::RequestFile { file_id_hex } => {
                match decode_array::<7>(&file_id_hex, "file_id_hex") {
                    Ok(id) => self.enqueue_unique(Task::File(hex::encode(id))),
                    Err(e) => out.problem(e),
                }
            }
            SessionRequest::FileReceived { .. } => {
                out.problem("file completion is verified internally from its CRC and identifier")
            }
            SessionRequest::Disconnect => {}
        }
        self.pump(now_ms, &mut out);
        self.finish(out)
    }

    fn on_frame(&mut self, frame: Frame, now: u64, out: &mut SessionUpdate) -> Result<(), String> {
        match frame.packet_type() {
            frame::TYPE_ACK => {
                if !frame.payload.is_empty() {
                    return Err("ACK unexpectedly contains a payload".into());
                }
                if let Some(pending) = self.pending.as_mut() {
                    if pending.sequence == Some(frame.sequence) {
                        pending.acked = true;
                    }
                }
            }
            frame::TYPE_SESSION_CONFIG => self.negotiate(&frame.payload, now, out)?,
            frame::TYPE_DATA => {
                self.emit(&frame::build_ack(frame.sequence), 0, out);
                let digest: [u8; 32] = Sha256::digest(&frame.payload).into();
                if self.received.contains(&(frame.sequence, digest)) {
                    return Ok(());
                }
                self.received.push_back((frame.sequence, digest));
                if self.received.len() > 32 {
                    self.received.pop_front();
                }
                let data = frame.data().map_err(|e| e.to_string())?;
                if ![1, 5].contains(&data.channel()) {
                    out.event("unsupported_channel", "保留了尚未支持的手环通道数据", json!({"channel":data.channel(),"opcode":data.opcode,"hex":hex::encode(data.bytes)}));
                    return Ok(());
                }
                let plain = match data.opcode {
                    1 if self.state != "ready" && data.channel() == 1 => data.bytes.to_vec(),
                    2 => self
                        .keys
                        .as_ref()
                        .ok_or("encrypted data arrived before keys were verified")?
                        .decrypt_v2(data.bytes)
                        .map_err(|e| e.to_string())?,
                    _ => {
                        return Err(format!(
                            "unsupported channel/opcode combination {}/{}",
                            data.channel(),
                            data.opcode
                        ))
                    }
                };
                if data.channel() == 5 {
                    if self.state != "ready" {
                        return Err("activity data arrived before authentication completed".into());
                    }
                    self.activity(&plain, now, out)?;
                } else {
                    self.command(&plain, now, out)?;
                }
            }
            kind => out.event(
                "unsupported_frame",
                "尚未支持的手环帧类型",
                json!({"packet_type":kind,"payload_hex":hex::encode(frame.payload)}),
            ),
        }
        Ok(())
    }

    fn negotiate(
        &mut self,
        payload: &[u8],
        now: u64,
        out: &mut SessionUpdate,
    ) -> Result<(), String> {
        if self.state == "ready" {
            out.event(
                "reconnect_required",
                "手环重新开启了通信会话，正在重新连接",
                json!({"fresh_nonce_required":true}),
            );
            self.fail(
                "watch restarted its session; create a new session with a fresh phone nonce".into(),
                out,
            );
            return Ok(());
        }
        if self.state != "negotiating" {
            return Ok(());
        }
        if payload.first() != Some(&2) {
            return Err("expected V2 START_SESSION_RESPONSE opcode 2".into());
        }
        let mut offset = 1;
        let mut seen = HashSet::new();
        while offset < payload.len() {
            if payload.len() - offset < 3 {
                return Err("truncated session configuration TLV".into());
            }
            let key = payload[offset];
            let size = usize::from(u16::from_le_bytes([
                payload[offset + 1],
                payload[offset + 2],
            ]));
            offset += 3;
            if size > payload.len() - offset || !seen.insert(key) {
                return Err("invalid or repeated session configuration TLV".into());
            }
            let value = &payload[offset..offset + size];
            offset += size;
            match key {
                1 if value != [1, 0, 0] => return Err("unsupported SPP V2 session version".into()),
                2 => {
                    if value.len() != 2 {
                        return Err("invalid peer packet size".into());
                    }
                    let max = usize::from(u16::from_le_bytes([value[0], value[1]]));
                    if max < 64 {
                        return Err("peer packet limit cannot carry authentication".into());
                    }
                    self.max_payload = self.max_payload.min(max.saturating_sub(8));
                }
                3 => {
                    if value.len() != 2 || value == [0, 0] {
                        return Err("invalid peer transmission window".into());
                    }
                }
                4 => {
                    if value.len() != 2 {
                        return Err("invalid peer send timeout".into());
                    }
                    self.ack_timeout =
                        u64::from(u16::from_le_bytes([value[0], value[1]])).clamp(1000, 30_000);
                }
                _ => {}
            }
        }
        self.pending = None;
        self.state = "awaiting_nonce";
        self.send_task(Task::Nonce, now, out)?;
        out.event("authenticating", "正在验证手环身份", json!({}));
        Ok(())
    }

    fn command(&mut self, input: &[u8], now: u64, out: &mut SessionUpdate) -> Result<(), String> {
        let cmd = Message::parse(input)?;
        let kind = cmd.uint(1)?.ok_or("command type is absent")?;
        let subtype = cmd.uint(2)?.ok_or("command subtype is absent")?;
        let status = cmd.uint(100)?;
        if kind == 1 {
            if subtype == 16 && matches!(self.state, "awaiting_nonce" | "awaiting_auth") {
                self.pairing_until = Some(now.saturating_add(120_000));
                if let Some(pending) = self.pending.as_mut() {
                    pending.acked = true;
                    pending.progress_at = now;
                }
                out.event(
                    "pairing_required",
                    "请在手环上确认连接",
                    json!({"timeout_seconds":120}),
                );
            }
            if status.is_some_and(|s| s != 0) {
                return Err(format!(
                    "authentication rejected with status {}",
                    status.unwrap()
                ));
            }
            if self.state == "awaiting_nonce" && (subtype == 26 || subtype == 16) {
                let auth = cmd.nested(3)?;
                let watch = auth.as_ref().map(|a| a.nested(31)).transpose()?.flatten();
                let Some(watch) = watch else {
                    if subtype == 16 {
                        return Ok(());
                    }
                    return Err("watch nonce response is missing".into());
                };
                let nonce = watch.bytes(1)?.ok_or("watch nonce is missing")?;
                let proof = watch.bytes(2)?.ok_or("watch proof is missing")?;
                self.keys = Some(
                    SessionKeys::derive_verified(
                        self.nonce.as_slice(),
                        nonce,
                        self.key.as_slice(),
                        proof,
                    )
                    .map_err(|e| e.to_string())?,
                );
                self.pending = None;
                self.state = "awaiting_auth";
                self.send_task(Task::Auth, now, out)?;
                return Ok(());
            }
            if subtype == 27
                && self.state == "awaiting_auth"
                && self.pending.as_ref().is_some_and(|p| p.task == Task::Auth)
                && self.keys.is_some()
            {
                // Require the explicit CMD_AUTH response at the expected stage,
                // after the nonce HMAC and phone proof, never an ACK alone.
                if let Some(auth) = cmd.nested(3)? {
                    if auth.uint(8)?.is_some_and(|s| s > 1) {
                        return Err("watch reported failed authentication".into());
                    }
                }
                self.pending = None;
                self.state = "ready";
                self.pairing_until = None;
                self.key.zeroize();
                self.nonce.zeroize();
                out.event(
                    "authenticated",
                    "手环认证成功",
                    json!({"command_status":status}),
                );
                self.enqueue_unique(Task::DeviceInfo);
                self.enqueue_unique(Task::Battery);
                return Ok(());
            }
            out.event(
                "unexpected_auth",
                "收到不符合当前阶段的认证消息",
                json!({"subtype":subtype,"status":status}),
            );
            return Ok(());
        }
        if self.state != "ready" {
            return Err("application command arrived before authentication completed".into());
        }
        let expected = match (kind, subtype) {
            (2, 1) => Some(Task::Battery),
            (2, 2) => Some(Task::DeviceInfo),
            (8, 1) => Some(Task::Today),
            (8, 2) => Some(Task::Past),
            _ => None,
        };
        let matches = expected
            .as_ref()
            .is_some_and(|t| self.pending.as_ref().is_some_and(|p| p.task == *t));
        if status.is_some_and(|s| s != 0) {
            out.event(
                "request_failed",
                "手环拒绝了请求",
                json!({"command_type":kind,"subtype":subtype,"status":status}),
            );
            if matches {
                if self.sync_active && kind == 8 {
                    self.sync_failures += 1;
                }
                self.pending = None;
            }
            return Ok(());
        }
        match (kind, subtype) {
            (2, 1) => {
                let system = cmd
                    .nested(4)?
                    .ok_or("battery response has no system data")?;
                let power = system
                    .nested(2)?
                    .ok_or("battery response has no power data")?;
                let battery = power
                    .nested(1)?
                    .ok_or("battery response has no battery data")?;
                let percent = battery.uint(1)?.ok_or("battery percentage is absent")?;
                if percent > 100 {
                    return Err("battery percentage exceeds 100".into());
                }
                let state = battery.uint(2)?;
                out.event(
                    "battery",
                    "已更新手环电量",
                    json!({"percent":percent,"charging":state==Some(1),"state":state}),
                );
            }
            (2, 2) => {
                let system = cmd.nested(4)?.ok_or("device response has no system data")?;
                let info = system.nested(3)?.ok_or("device information is absent")?;
                out.event("device_info","已读取手环信息",json!({"serial_number":info.text(1)?,"firmware":info.text(2)?,"model":info.text(4)?}));
            }
            (8, 1) | (8, 2) => {
                let health = cmd.nested(10)?;
                let ids = health
                    .as_ref()
                    .map(|h| h.bytes(2))
                    .transpose()?
                    .flatten()
                    .unwrap_or(&[]);
                if ids.len() % 7 != 0 {
                    return Err(
                        "health directory is not a sequence of seven-byte file identifiers".into(),
                    );
                }
                if ids.len() / 7 > MAX_FILES {
                    return Err("health directory exceeds 512 files".into());
                }
                let mut file_ids = Vec::new();
                for bytes in ids.as_chunks::<7>().0 {
                    if bytes.iter().all(|b| *b == 0) {
                        continue;
                    }
                    let id = hex::encode(bytes);
                    file_ids.push(id.clone());
                    if matches && self.sync_active && !self.file_ids.contains(&id) {
                        if self.file_ids.len() >= MAX_FILES {
                            return Err("health sync exceeds 512 unique files".into());
                        }
                        self.file_ids.insert(id.clone());
                        self.queue.push_back(Task::File(id));
                    }
                }
                out.event(
                    "health_file_list",
                    "已读取健康数据目录",
                    json!({"scope":if subtype==1 {"today"}else{"past"},"file_ids":file_ids}),
                );
            }
            _ => out.event(
                "raw_command",
                "已保留尚未解析的手环命令",
                json!({"command_type":kind,"subtype":subtype,"hex":hex::encode(input)}),
            ),
        }
        if matches {
            self.pending = None;
        }
        Ok(())
    }

    fn activity(&mut self, input: &[u8], now: u64, out: &mut SessionUpdate) -> Result<(), String> {
        let expected = match self.pending.as_ref().map(|p| &p.task) {
            Some(Task::File(id)) => id.clone(),
            _ => {
                out.event(
                    "unsolicited_activity",
                    "已保留非请求中的健康数据片段",
                    json!({"hex":hex::encode(input)}),
                );
                return Ok(());
            }
        };
        let file = self.assembler.push(input).map_err(|e| e.to_string())?;
        if let Some(pending) = self.pending.as_mut() {
            pending.acked = true;
            pending.progress_at = now;
        }
        if let Some(file) = file {
            if file.file_id.hex != expected {
                self.assembler.reset();
                return Err("received health file does not match requested identifier".into());
            }
            let data = serde_json::to_value(file).map_err(|e| e.to_string())?;
            out.event("health_file", "已下载并校验健康数据文件", data);
            self.pending = None;
            self.assembler.reset();
        }
        Ok(())
    }

    fn send_task(&mut self, task: Task, now: u64, out: &mut SessionUpdate) -> Result<(), String> {
        let command = match &task {
            Task::Nonce => proto::nonce_command(&self.nonce),
            Task::Auth => {
                let keys = self.keys.as_ref().ok_or("session keys are missing")?;
                let proof = keys.phone_hmac().map_err(|e| e.to_string())?;
                let info = keys
                    .encrypt_auth_info(&self.device_info)
                    .map_err(|e| e.to_string())?;
                proto::auth_command(&proof, &info)
            }
            Task::Battery => proto::command(2, 1, None),
            Task::DeviceInfo => proto::command(2, 2, None),
            Task::Today => proto::today_command(),
            Task::Past => proto::command(8, 2, None),
            Task::File(id) => {
                self.assembler.reset();
                proto::file_command(&decode_array::<7>(id, "file_id")?)
            }
            Task::Negotiate => return Err("negotiation is started separately".into()),
        };
        let encrypted = !matches!(task, Task::Nonce | Task::Auth);
        let body = if encrypted {
            self.keys
                .as_ref()
                .ok_or("session keys are missing")?
                .encrypt_v2(&command)
                .map_err(|e| e.to_string())?
        } else {
            command
        };
        let mut payload = vec![1, if encrypted { 2 } else { 1 }];
        payload.extend_from_slice(&body);
        if payload.len() > self.max_payload {
            return Err("command exceeds negotiated packet size".into());
        }
        let sequence = self.next_sequence();
        let frame = frame::build_frame(3, sequence, &payload).map_err(|e| e.to_string())?;
        self.set_pending(task, frame, Some(sequence), now, out);
        Ok(())
    }

    fn set_pending(
        &mut self,
        task: Task,
        frame: Vec<u8>,
        sequence: Option<u8>,
        now: u64,
        out: &mut SessionUpdate,
    ) {
        self.emit(&frame, 1, out);
        self.pending = Some(Pending {
            task,
            frame,
            sequence,
            sent_at: now,
            progress_at: now,
            retries: 0,
            acked: false,
        });
    }
    fn enqueue_unique(&mut self, task: Task) {
        if !self.queue.contains(&task) && !self.pending.as_ref().is_some_and(|p| p.task == task) {
            self.queue.push_back(task);
        }
    }
    fn pump(&mut self, now: u64, out: &mut SessionUpdate) {
        if self.state != "ready" || self.pending.is_some() {
            return;
        }
        if let Some(task) = self.queue.pop_front() {
            if let Err(error) = self.send_task(task, now, out) {
                out.problem(error);
            }
        } else if self.sync_active {
            self.sync_active = false;
            if self.sync_failures > 0 {
                out.event(
                    "sync_failed",
                    "部分健康数据未能下载，请再次同步",
                    json!({"failures":self.sync_failures}),
                );
            }
            out.event("sync_complete","本轮健康数据同步已结束",json!({"files":self.file_ids.len(),"failures":self.sync_failures,"device_history_preserved":true}));
        }
    }
    fn emit(&self, bytes: &[u8], priority: u8, out: &mut SessionUpdate) {
        for chunk in bytes.chunks(self.mtu) {
            out.outbound.push(Outbound {
                hex: hex::encode(chunk),
                priority,
            });
        }
    }
    fn next_sequence(&mut self) -> u8 {
        let sequence = self.sequence;
        self.sequence = self.sequence.wrapping_add(1);
        sequence
    }
    fn output(&self) -> SessionUpdate {
        SessionUpdate {
            state: self.state.into(),
            outbound: Vec::new(),
            events: Vec::new(),
            error: None,
        }
    }
    fn finish(&self, mut out: SessionUpdate) -> SessionUpdate {
        out.state = self.state.into();
        out
    }
    fn time(&mut self, now: u64, out: &mut SessionUpdate) -> bool {
        if now < self.last_now {
            out.problem("monotonic time moved backwards");
            false
        } else {
            self.last_now = now;
            true
        }
    }
    fn fail(&mut self, error: String, out: &mut SessionUpdate) {
        if self.sync_active {
            out.event("sync_failed", "健康数据同步已中断", json!({}));
        }
        out.problem(error);
        self.state = "failed";
        self.clear();
    }
    fn clear(&mut self) {
        self.pending = None;
        self.queue.clear();
        self.keys = None;
        self.key.zeroize();
        self.nonce.zeroize();
        self.decoder.reset();
        self.assembler.reset();
        self.received.clear();
        self.sync_active = false;
        self.pairing_until = None;
    }
}

fn decode_array<const N: usize>(input: &str, name: &str) -> Result<[u8; N], String> {
    if input.len() != N * 2 {
        return Err(format!(
            "{name} must contain exactly {} hex characters",
            N * 2
        ));
    }
    let mut bytes = [0u8; N];
    hex::decode_to_slice(input, &mut bytes).map_err(|_| format!("{name} contains invalid hex"))?;
    Ok(bytes)
}

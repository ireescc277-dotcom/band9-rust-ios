use serde::{Deserialize, Serialize};

const BASE_SUFFIX: &str = "-0000-1000-8000-00805F9B34FB";

#[derive(Deserialize)]
pub struct Inventory {
    pub services: Vec<Service>,
}

#[derive(Deserialize)]
pub struct Service {
    pub uuid: String,
    pub characteristics: Vec<Characteristic>,
}

#[derive(Deserialize)]
pub struct Characteristic {
    pub uuid: String,
    pub properties: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct Diagnosis {
    pub core_version: String,
    pub profile: String,
    pub summary: String,
    pub warnings: Vec<String>,
    pub suggested_notify_uuid: Option<String>,
    pub suggested_write_uuid: Option<String>,
}

impl Diagnosis {
    pub fn error(message: &str) -> Self {
        Self {
            core_version: env!("CARGO_PKG_VERSION").into(),
            profile: "unknown".into(),
            summary: "无法完成通道分析".into(),
            warnings: vec![message.into()],
            suggested_notify_uuid: None,
            suggested_write_uuid: None,
        }
    }
}

fn bluetooth_uuid(value: &str) -> Option<String> {
    let value = value.trim().to_ascii_uppercase();
    match value.len() {
        4 | 8 if value.bytes().all(|b| b.is_ascii_hexdigit()) => {
            Some(format!("{:0>8}{BASE_SUFFIX}", value))
        }
        36 if value.ends_with(BASE_SUFFIX) && value[..8].bytes().all(|b| b.is_ascii_hexdigit()) => {
            Some(value)
        }
        _ => None,
    }
}

fn is_uuid(value: &str, short: &str) -> bool {
    bluetooth_uuid(value) == bluetooth_uuid(short)
}

fn find_channel<'a>(service: &'a Service, uuid: &str, receive: bool) -> Option<&'a Characteristic> {
    service.characteristics.iter().find(|c| {
        is_uuid(&c.uuid, uuid)
            && c.properties.iter().any(|p| {
                if receive {
                    p == "notify" || p == "indicate"
                } else {
                    p == "write" || p == "writeWithoutResponse"
                }
            })
    })
}

pub fn diagnose(inventory: Inventory) -> Diagnosis {
    if inventory.services.len() > 128
        || inventory.services.iter().any(|s| {
            s.characteristics.len() > 128
                || s.uuid.len() > 128
                || s.characteristics.iter().any(|c| {
                    c.uuid.len() > 128
                        || c.properties.len() > 32
                        || c.properties.iter().any(|p| p.len() > 64)
                })
        })
    {
        return Diagnosis::error("服务清单超出诊断上限，请重新连接后导出。");
    }
    let mut result = Diagnosis {
        core_version: env!("CARGO_PKG_VERSION").into(),
        profile: "unknown".into(),
        summary: "尚未识别出可用的小米协议通道".into(),
        warnings: vec!["通道特征只能用于选择后续适配方向，不代表型号确认或认证成功。".into()],
        suggested_notify_uuid: None,
        suggested_write_uuid: None,
    };
    let xiaomi: Vec<_> = inventory
        .services
        .iter()
        .filter(|s| is_uuid(&s.uuid, "FE95"))
        .collect();
    if xiaomi.is_empty() {
        result
            .warnings
            .push("没有发现 FE95 服务；请保留诊断清单，不要据此断言设备不支持 iOS。".into());
        return result;
    }
    for (rx, tx, profile, summary) in [
        (
            "005E",
            "005F",
            "xiaomi_v2_candidate",
            "发现小米 V2 候选通道",
        ),
        (
            "0051",
            "0052",
            "xiaomi_legacy_candidate",
            "发现小米旧 BLE 候选通道",
        ),
    ] {
        for service in &xiaomi {
            if let (Some(notify), Some(write)) = (
                find_channel(service, rx, true),
                find_channel(service, tx, false),
            ) {
                result.profile = profile.into();
                result.summary = summary.into();
                result.suggested_notify_uuid = bluetooth_uuid(&notify.uuid);
                result.suggested_write_uuid = bluetooth_uuid(&write.uuid);
                return result;
            }
        }
    }
    result
        .warnings
        .push("已发现 FE95，但通知和写入特征未组成已知通道，或属性不匹配。".into());
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str) -> Diagnosis {
        diagnose(serde_json::from_str(json).unwrap())
    }

    #[test]
    fn short_and_long_uuids_form_v2_only_with_correct_properties() {
        let d = parse(
            r#"{"services":[{"uuid":"fe95","characteristics":[{"uuid":"0000005e-0000-1000-8000-00805f9b34fb","properties":["notify"]},{"uuid":"005F","properties":["writeWithoutResponse"]}]}]}"#,
        );
        assert_eq!(d.profile, "xiaomi_v2_candidate");
        assert_eq!(
            d.suggested_write_uuid.as_deref(),
            Some("0000005F-0000-1000-8000-00805F9B34FB")
        );
        let reversed = parse(
            r#"{"services":[{"uuid":"FE95","characteristics":[{"uuid":"005E","properties":["write"]},{"uuid":"005F","properties":["notify"]}]}]}"#,
        );
        assert_eq!(reversed.profile, "unknown");
    }

    #[test]
    fn never_combine_different_services_or_similar_custom_uuids() {
        let split = parse(
            r#"{"services":[{"uuid":"FE95","characteristics":[{"uuid":"005E","properties":["notify"]}]},{"uuid":"180F","characteristics":[{"uuid":"005F","properties":["write"]}]}]}"#,
        );
        assert_eq!(split.profile, "unknown");
        assert!(!is_uuid("1000FE95-0000-1000-8000-00805F9B34FB", "FE95"));
        assert!(!is_uuid("0000FE95-0000-9999-8000-00805F9B34FB", "FE95"));
        assert!(!is_uuid("💡💡💡💡💡💡💡💡💡", "FE95"));
    }

    #[test]
    fn legacy_profile_is_not_mislabeled_v2() {
        let d = parse(
            r#"{"services":[{"uuid":"FE95","characteristics":[{"uuid":"0051","properties":["indicate"]},{"uuid":"0052","properties":["write"]}]}]}"#,
        );
        assert_eq!(d.profile, "xiaomi_legacy_candidate");
        assert!(d.warnings[0].contains("不代表"));
    }

    #[test]
    fn excessive_service_count_is_rejected() {
        let services = (0..129)
            .map(|_| Service {
                uuid: "FE95".into(),
                characteristics: vec![],
            })
            .collect();
        let d = diagnose(Inventory { services });
        assert_eq!(d.profile, "unknown");
        assert!(d.warnings[0].contains("上限"));
    }
}

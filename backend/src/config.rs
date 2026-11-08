//! Server-startup settings. No raw parser diagnostics or vocabulary on the wire.
use crate::launcher::NetworkIsolation;
use serde::Deserialize;
use std::fs::OpenOptions;
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

const INVALID: &str = "configuration_invalid";

#[derive(Clone)]
pub struct Config {
    editor_mode: String,
    model_id: String,
    network_isolation: NetworkIsolation,
    hotwords: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FileConfig {
    editor: Option<Editor>,
    model: Option<Model>,
    inference: Option<Inference>,
    vocabulary: Option<Vocabulary>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Editor {
    mode: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Model {
    id: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Inference {
    network_isolation: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Vocabulary {
    terms: Option<Vec<String>>,
}

impl Config {
    pub fn parse(text: &str) -> Result<Self, &'static str> {
        if text.len() > 65_536 {
            return Err(INVALID);
        }
        let raw: FileConfig = toml::from_str(text).map_err(|_| INVALID)?;
        let editor_mode = raw
            .editor
            .and_then(|e| e.mode)
            .unwrap_or_else(|| "standard".into());
        if !matches!(editor_mode.as_str(), "standard" | "vim") {
            return Err("configuration_invalid: editor.mode");
        }
        let model_id = crate::model::manifest().id;
        if let Some(id) = raw.model.and_then(|m| m.id)
            && id != model_id
            && id != "parakeet-tdt-0.6b-v2"
        {
            return Err("configuration_invalid: model.id");
        }
        let mode = raw.inference.and_then(|i| i.network_isolation);
        let network_isolation = match mode.as_deref().unwrap_or("required") {
            "required" => NetworkIsolation::Required,
            "disabled" => NetworkIsolation::Disabled,
            _ => return Err("configuration_invalid: inference.network_isolation"),
        };
        let terms = raw.vocabulary.and_then(|v| v.terms).unwrap_or_default();
        if terms.len() > 256
            || terms.iter().any(|term| {
                term.is_empty()
                    || term.len() > 128
                    || term.split(' ').any(str::is_empty)
                    || term.chars().any(|c| {
                        matches!(c, '/' | ':') || c.is_control() || (c.is_whitespace() && c != ' ')
                    })
            })
        {
            return Err("configuration_invalid: vocabulary.terms");
        }
        Ok(Self {
            editor_mode,
            model_id,
            network_isolation,
            hotwords: terms.join("/"),
        })
    }

    pub fn load() -> Result<Self, &'static str> {
        let base = match std::env::var_os("XDG_CONFIG_HOME") {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(std::env::var_os("HOME").ok_or(INVALID)?).join(".config"),
        };
        if !base.is_absolute() {
            return Err(INVALID);
        }
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(
                (rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32,
            )
            .open(base.join("hagig/config.toml"))
        {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Self::parse(""),
            Err(_) => return Err(INVALID),
        };
        if !file.metadata().map_err(|_| INVALID)?.is_file() {
            return Err(INVALID);
        }
        let mut text = String::new();
        file.take(65_537)
            .read_to_string(&mut text)
            .map_err(|_| INVALID)?;
        Self::parse(&text)
    }

    pub fn editor_mode(&self) -> &str {
        &self.editor_mode
    }
    pub fn model_id(&self) -> &str {
        &self.model_id
    }
    pub fn network_isolation(&self) -> NetworkIsolation {
        self.network_isolation
    }
    /// Syntax validation only. Pinned tokenizer representability is a separate gate.
    pub fn hotwords(&self) -> &str {
        &self.hotwords
    }
}

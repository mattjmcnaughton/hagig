//! Explicitly built experimental pinned candidate, never the trusted bootstrap.
//! Build with a verified local SHERPA_ONNX_LIB_DIR; upstream's default sys build
//! can download native binaries and must not be used as an acquisition path.
#![forbid(unsafe_code)]
use hagig::worker_protocol::{self, Reply};
use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig, OfflineTransducerModelConfig};
use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};

fn recognizer(model: &Path, hotwords: &str) -> Result<OfflineRecognizer, &'static str> {
    // Entirely inside the isolated process, after trusted bootstrap ACK/exec.
    hagig::model::validate(model)?;
    let mut bpe = String::new();
    std::fs::File::open(model.join("bpe.vocab"))
        .and_then(|f| f.take(131_073).read_to_string(&mut bpe))
        .map_err(|_| "model_invalid")?;
    if bpe.len() > 131_072 {
        return Err("model_invalid");
    }
    // The manifest hashes fix the tables inspected in PR18: singleton-closed
    // pieces, identical token prefix, sole extra blank. No approximate tokenizer
    // or Unicode normalization. Unknown scalars cannot be boosted usefully.
    let singletons: HashSet<char> = bpe
        .lines()
        .filter_map(|line| {
            let mut chars = line.split_ascii_whitespace().next()?.chars();
            let ch = chars.next()?;
            chars.next().is_none().then_some(ch)
        })
        .collect();
    if hotwords
        .split(['/', ' '])
        .any(|word| word.chars().any(|c| !singletons.contains(&c)))
    {
        return Err("worker_failed");
    }
    let asset = |name| {
        model
            .join(name)
            .to_str()
            .map(str::to_owned)
            .ok_or("model_invalid")
    };
    let mut config = OfflineRecognizerConfig::default();
    config.model_config.transducer = OfflineTransducerModelConfig {
        encoder: Some(asset("encoder.int8.onnx")?),
        decoder: Some(asset("decoder.int8.onnx")?),
        joiner: Some(asset("joiner.int8.onnx")?),
    };
    config.model_config.tokens = Some(asset("tokens.txt")?);
    config.model_config.bpe_vocab = Some(asset("bpe.vocab")?);
    config.model_config.modeling_unit = Some("bpe".into());
    config.model_config.model_type = Some("nemo_transducer".into());
    config.model_config.provider = Some("cpu".into());
    config.model_config.num_threads = 2;
    config.model_config.debug = false;
    config.decoding_method = Some("modified_beam_search".into());
    config.max_active_paths = 4;
    config.hotwords_score = 1.5;
    OfflineRecognizer::create(&config).ok_or("model_invalid")
}

fn run() -> Result<(), &'static str> {
    if std::env::args_os().len() != 1 {
        return Err("worker_failed");
    }
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    let mut warm: Option<(PathBuf, String, OfflineRecognizer)> = None;
    loop {
        let (request, samples) = worker_protocol::read_request(&mut input)?;
        let result = (|| {
            if warm.is_none() {
                warm = Some((
                    request.model.clone(),
                    request.hotwords.clone(),
                    recognizer(&request.model, &request.hotwords)?,
                ));
            }
            let (model, hotwords, recognizer) = warm.as_ref().unwrap();
            if model != &request.model || hotwords != &request.hotwords {
                return Err("worker_failed");
            }
            let stream = if hotwords.is_empty() {
                recognizer.create_stream()
            } else {
                recognizer.create_stream_with_hotwords(hotwords)
            };
            stream.accept_waveform(16_000, &samples);
            recognizer.decode(&stream);
            stream.get_result().map(|r| r.text).ok_or("worker_failed")
        })();
        let failed = result.is_err();
        let mut reply = Reply {
            version: 1,
            generation: request.generation,
            request_id: request.request_id,
            text: result.as_ref().ok().cloned(),
            code: result.err().map(str::to_owned),
        };
        match worker_protocol::write_reply(&mut output, &reply) {
            Err("result_too_large") => {
                reply.text = None;
                reply.code = Some("result_too_large".into());
                worker_protocol::write_reply(&mut output, &reply)?;
                return Err("result_too_large");
            }
            Err(error) => return Err(error),
            Ok(()) => (),
        }
        if failed {
            return Err("worker_failed");
        }
    }
}

fn main() -> std::process::ExitCode {
    if run().is_err() {
        std::process::ExitCode::FAILURE
    } else {
        std::process::ExitCode::SUCCESS
    }
}

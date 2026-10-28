//! Shared candidate configuration for the S1 benchmark and isolated worker probe.
use sherpa_onnx::{OfflineRecognizerConfig, OfflineTransducerModelConfig};
use std::path::Path;

pub fn candidate_config(model: &Path) -> Result<OfflineRecognizerConfig, &'static str> {
    for name in [
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "joiner.int8.onnx",
        "tokens.txt",
        "bpe.vocab",
    ] {
        if !model.join(name).is_file() {
            return Err("model_missing");
        }
    }
    let asset = |name| Some(model.join(name).to_str().unwrap().to_owned());
    let mut config = OfflineRecognizerConfig::default();
    config.model_config.transducer = OfflineTransducerModelConfig {
        encoder: asset("encoder.int8.onnx"),
        decoder: asset("decoder.int8.onnx"),
        joiner: asset("joiner.int8.onnx"),
    };
    config.model_config.tokens = asset("tokens.txt");
    config.model_config.bpe_vocab = asset("bpe.vocab");
    config.model_config.modeling_unit = Some("bpe".into());
    config.model_config.model_type = Some("nemo_transducer".into());
    config.model_config.provider = Some("cpu".into());
    config.model_config.num_threads = 2;
    config.model_config.debug = false;
    config.decoding_method = Some("modified_beam_search".into());
    config.max_active_paths = 4;
    config.hotwords_score = 1.5;
    Ok(config)
}

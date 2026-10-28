//! Synthetic/public fixtures only: deliberately emits transcripts as experiment evidence.
use hagig_inference_s1::candidate_config;
use sherpa_onnx::{OfflineRecognizer, Wave};
use std::{env, fs, path::Path, time::Instant};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 4 {
        return Err("usage: hagig-inference-s1 MODEL_DIR FIXTURE_DIR HOTWORDS_FILE".into());
    }
    let model = Path::new(&args[1]);
    let fixtures = Path::new(&args[2]);
    let hotwords = fs::read_to_string(&args[3])?.trim().replace('\n', "/");
    let config = candidate_config(model)?;

    let start = Instant::now();
    let recognizer = OfflineRecognizer::create(&config).ok_or("recognizer creation failed")?;
    println!(
        "{}",
        serde_json::json!({"event":"load", "seconds":start.elapsed().as_secs_f64()})
    );
    let corpus = fs::read_to_string(fixtures.join("corpus.tsv"))?;
    // Same recognizer, paired streams; reverse mode order on the second pass.
    // First decode is separately identified, not silently counted as warm.
    let mut decode_index = 0;
    for pass in 0..2 {
        for line in corpus.lines() {
            let fields: Vec<_> = line.split('\t').collect();
            let [id, kind, reference, _spoken] = fields.as_slice() else {
                return Err("invalid experiment corpus".into());
            };
            let wave = Wave::read(fixtures.join(format!("{id}.wav")).to_str().unwrap())
                .ok_or("fixture read failed")?;
            for boosted in if pass == 0 {
                [false, true]
            } else {
                [true, false]
            } {
                let start = Instant::now();
                let stream = if boosted {
                    recognizer.create_stream_with_hotwords(&hotwords)
                } else {
                    recognizer.create_stream()
                };
                stream.accept_waveform(wave.sample_rate(), wave.samples());
                recognizer.decode(&stream);
                let result = stream.get_result().ok_or("missing recognition result")?;
                println!(
                    "{}",
                    serde_json::json!({
                        "event":"decode", "id":id, "kind":kind, "reference":reference,
                        "pass":pass, "boosted":boosted, "decode_index":decode_index,
                        "seconds":start.elapsed().as_secs_f64(),
                        "audio_seconds":wave.samples().len() as f64 / wave.sample_rate() as f64,
                        "text":result.text
                    })
                );
                decode_index += 1;
            }
        }
    }
    Ok(())
}

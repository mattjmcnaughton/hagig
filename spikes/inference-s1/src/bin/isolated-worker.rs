//! One request per process. Invoke through worker_probe.py, not as a client CLI.
use hagig_inference_s1::candidate_config;
use sherpa_onnx::{OfflineRecognizer, Wave};
use std::{env, fs, fs::File, io::Write, os::fd::FromRawFd, path::Path};

fn transcribe(args: &[String]) -> Result<String, &'static str> {
    let config = candidate_config(Path::new(&args[1]))?;
    let hotwords = fs::read_to_string(&args[3]).map_err(|_| "vocabulary_unreadable")?;
    let hotwords = hotwords.trim().replace('\n', "/");
    let recognizer = OfflineRecognizer::create(&config).ok_or("model_invalid")?;
    let wave = Wave::read(&args[2]).ok_or("audio_invalid")?;
    let stream = recognizer.create_stream_with_hotwords(&hotwords);
    stream.accept_waveform(wave.sample_rate(), wave.samples());
    recognizer.decode(&stream);
    stream.get_result().map(|r| r.text).ok_or("worker_failed")
}

fn main() {
    let args: Vec<String> = env::args().collect();
    // Internal experimental arguments: model, WAV, vocabulary, result FD, mode.
    if args.len() != 6 {
        std::process::exit(2);
    }
    let fd: i32 = args[4].parse().expect("internal result descriptor");
    assert!(fd > 2);
    // SAFETY: the supervisor passes ownership of this dedicated pipe descriptor.
    let mut reply = unsafe { File::from_raw_fd(fd) };
    let outcome = transcribe(&args);
    let record = match &outcome {
        Ok(text) => serde_json::json!({"text":text}),
        Err(code) => serde_json::json!({"error":code}),
    };
    writeln!(reply, "{record}").expect("private result write");
    if outcome.is_ok() {
        match args[5].as_str() {
            // Opt-in fault seams occur AFTER actual inference and reply writing.
            "crash-after-result" => {
                println!("SYNTHETIC_STDOUT_DIAGNOSTIC");
                std::process::abort();
            }
            "hold-after-result" => {
                let mut input = String::new();
                std::io::stdin().read_line(&mut input).expect("test gate");
            }
            "normal" => (),
            _ => std::process::exit(2),
        }
    }
    std::process::exit(if outcome.is_ok() { 0 } else { 1 });
}

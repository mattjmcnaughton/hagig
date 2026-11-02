//! Lifecycle CLI; real transcription/model installation is not implemented.

#![forbid(unsafe_code)]

fn main() -> std::process::ExitCode {
    if let Err(error) = hagig::service::cli() {
        eprintln!("{error}");
        return std::process::ExitCode::from(if error == "busy" { 3 } else { 1 });
    }
    std::process::ExitCode::SUCCESS
}

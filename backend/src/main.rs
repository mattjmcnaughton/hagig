//! Content-safe CLI exit mapping; native diagnostics never reach this process.

#![forbid(unsafe_code)]

fn main() -> std::process::ExitCode {
    if let Err(error) = hagig::service::cli() {
        eprintln!("{error}");
        return std::process::ExitCode::from(match error {
            "busy" => 3,
            "interrupted" => 130,
            "unsupported_model"
            | "invalid_arguments"
            | "invalid_command"
            | "invalid_isolation_mode"
            | "invalid_audio" => 2,
            error if error.starts_with("configuration_invalid") || error.starts_with("usage:") => 2,
            _ => 1,
        });
    }
    std::process::ExitCode::SUCCESS
}

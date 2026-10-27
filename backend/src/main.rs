//! Scaffold entry point; not the future transcribe/server/model-install CLI.

#![forbid(unsafe_code)]

use hagig::launcher::PlatformLauncher;
use hagig::supervisor::Supervisor;

fn main() -> std::process::ExitCode {
    let mut supervisor = Supervisor::new(PlatformLauncher);
    if let Err(error) = supervisor.start() {
        eprintln!("{error}");
        return std::process::ExitCode::FAILURE;
    }
    std::process::ExitCode::SUCCESS
}

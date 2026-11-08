//! Trusted, inference-free bootstrap. Isolation and descriptor hygiene precede
//! exec here; native loading begins only after the fixed readiness ACK.
#![forbid(unsafe_code)]
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::process::Command;

fn main() -> std::process::ExitCode {
    let Ok(executable) = std::env::current_exe() else {
        return std::process::ExitCode::FAILURE;
    };
    if std::io::stdout()
        .write_all(hagig::launcher::WORKER_READY)
        .and_then(|_| std::io::stdout().flush())
        .is_err()
    {
        return std::process::ExitCode::FAILURE;
    }
    // Replace this process, not a descendant outside Supervisor ownership.
    // Never resolve native helpers or libraries through ambient PATH/env.
    let _ = Command::new(executable.with_file_name("hagig-inference-worker"))
        .env_clear()
        .current_dir("/")
        .exec();
    std::process::ExitCode::FAILURE
}

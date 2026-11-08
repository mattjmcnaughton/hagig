use std::fs;
use std::os::unix::fs::{DirBuilderExt, symlink};
use std::process::Command;

const MODEL: &str = "parakeet-tdt-0.6b-v2-int8-v1";

#[test]
fn explicit_install_rejects_unverified_input_without_publication_or_content_errors() {
    let root = std::env::temp_dir().join(format!("hagig-install-{}", std::process::id()));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    let source = root.join("private-source-canary");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("encoder.int8.onnx"), b"private-content-canary").unwrap();
    let invoke = |id: &str| {
        Command::new(env!("CARGO_BIN_EXE_hagig"))
            .env("XDG_DATA_HOME", root.join("data"))
            .args(["model", "install", id, "--from"])
            .arg(&source)
            .output()
            .unwrap()
    };
    let unknown = invoke("private-model-canary");
    assert_eq!(unknown.status.code(), Some(2));
    assert!(unknown.stdout.is_empty());
    assert_eq!(unknown.stderr, b"unsupported_model\n");

    let failed = invoke(MODEL);
    assert_eq!(failed.status.code(), Some(1));
    assert!(failed.stdout.is_empty());
    assert_eq!(failed.stderr, b"model_install_failed\n");
    let models = root.join("data/hagig/models");
    assert!(!models.join(MODEL).exists());
    assert_eq!(
        fs::read_dir(&models).unwrap().count(),
        1,
        "only persistent advisory lock remains, never staging"
    );
    assert!(models.join(".install-lock").is_file());
    assert_eq!(
        fs::read(source.join("encoder.int8.onnx")).unwrap(),
        b"private-content-canary"
    );

    // Never replace an existing installation, even when the incoming install fails.
    let installed = models.join(MODEL);
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&installed)
        .unwrap();
    fs::write(installed.join("preserve"), b"existing-installation").unwrap();
    let existing = invoke(MODEL);
    assert_eq!(existing.stderr, b"model_invalid\n");
    assert_eq!(
        fs::read(installed.join("preserve")).unwrap(),
        b"existing-installation"
    );
    fs::remove_dir_all(&installed).unwrap();

    // A symlink at the final installation is neither followed nor repaired.
    symlink(&source, &installed).unwrap();
    let linked = invoke(MODEL);
    assert_eq!(linked.stderr, b"model_invalid\n");
    assert!(
        fs::symlink_metadata(&installed)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert!(source.join("encoder.int8.onnx").exists());
    fs::remove_file(&installed).unwrap();

    // Local acquisition must reject a FIFO without waiting for a writer.
    fs::remove_file(source.join("encoder.int8.onnx")).unwrap();
    assert!(
        Command::new("/usr/bin/mkfifo")
            .args(["-m", "600"])
            .arg(source.join("encoder.int8.onnx"))
            .status()
            .unwrap()
            .success()
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_hagig"))
        .env("XDG_DATA_HOME", root.join("data"))
        .args(["model", "install", MODEL, "--from"])
        .arg(&source)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if std::time::Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            fs::remove_dir_all(&root).unwrap();
            panic!("local installation blocked on nonregular input");
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let fifo = child.wait_with_output().unwrap();
    assert_eq!(fifo.status.code(), Some(1));
    assert_eq!(fifo.stderr, b"model_install_failed\n");
    assert_eq!(fs::read_dir(&models).unwrap().count(), 1);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn installer_lock_is_released_after_process_death() {
    use std::fs::OpenOptions;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::process::Stdio;
    use std::time::{Duration, Instant};
    // Subprocess is solely a test lock holder, not a production CLI option.
    if let Some(root) = std::env::var_os("HAGIG_TEST_INSTALL_LOCK_ROOT") {
        let root = std::path::PathBuf::from(root);
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .open(root.join("data/hagig/models/.install-lock"))
            .unwrap();
        lock.lock().unwrap();
        fs::write(root.join("locked"), b"").unwrap();
        let _ = std::io::Read::read(&mut std::io::stdin(), &mut [0; 1]);
        return;
    }
    let root = std::env::temp_dir().join(format!("hg-lock-{}", std::process::id()));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    let models = root.join("data/hagig/models");
    fs::create_dir_all(&models).unwrap();
    for path in [models.parent().unwrap(), models.as_path()] {
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(models.join(".install-lock"))
        .unwrap();
    let inode = lock.metadata().unwrap().ino();
    drop(lock);
    let source = root.join("source");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("encoder.int8.onnx"), b"invalid-model").unwrap();
    let mut holder = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "installer_lock_is_released_after_process_death"])
        .env("HAGIG_TEST_INSTALL_LOCK_ROOT", &root)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !root.join("locked").exists() {
        assert!(holder.try_wait().unwrap().is_none());
        if Instant::now() >= deadline {
            holder.kill().unwrap();
            holder.wait().unwrap();
            panic!("test lock holder never acquired lock");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let invoke = || {
        Command::new(env!("CARGO_BIN_EXE_hagig"))
            .env("XDG_DATA_HOME", root.join("data"))
            .args(["model", "install", MODEL, "--from"])
            .arg(&source)
            .output()
            .unwrap()
    };
    let busy = invoke();
    assert_eq!(busy.stderr, b"model_install_busy\n");
    assert!(busy.stdout.is_empty());
    holder.kill().unwrap();
    holder.wait().unwrap();
    let retry = invoke();
    assert_eq!(
        retry.stderr, b"model_install_failed\n",
        "dead owner must not leave installer busy"
    );
    assert!(retry.stdout.is_empty());
    assert_eq!(
        fs::metadata(models.join(".install-lock")).unwrap().ino(),
        inode
    );
    assert_eq!(
        fs::read(source.join("encoder.int8.onnx")).unwrap(),
        b"invalid-model"
    );
    assert!(!models.join(MODEL).exists());
    fs::remove_dir_all(root).unwrap();
}

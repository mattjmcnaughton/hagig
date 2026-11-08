//! Explicit immutable model installation. Runtime validation never downloads.
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

type Result<T> = std::result::Result<T, &'static str>;
const FAILED: &str = "model_install_failed";
const ARCHIVE_LIMIT: u64 = 4 * 1024 * 1024 * 1024;

#[derive(Deserialize)]
pub struct Manifest {
    pub id: String,
    pub revision: String,
    model_url: String,
    tokenizer_url: String,
    tokenizer_archive_sha256: String,
    tokenizer_member: String,
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    bytes: u64,
    sha256: String,
}

pub fn manifest() -> Manifest {
    serde_json::from_str(include_str!("../model-manifest.json")).expect("tracked model manifest")
}

pub fn installation() -> Result<PathBuf> {
    let base = match std::env::var_os("XDG_DATA_HOME") {
        Some(p) => PathBuf::from(p),
        None => PathBuf::from(std::env::var_os("HOME").ok_or("configuration_invalid")?)
            .join(".local/share"),
    };
    if !base.is_absolute() {
        return Err("configuration_invalid");
    }
    Ok(base.join("hagig/models").join(manifest().id))
}

fn private_directory(path: &Path) -> Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => (),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => (),
        Err(_) => return Err(FAILED),
    }
    let m = fs::symlink_metadata(path).map_err(|_| FAILED)?;
    if !m.is_dir() || m.uid() != rustix::process::getuid().as_raw() || m.mode() & 0o7777 != 0o700 {
        return Err(FAILED);
    }
    Ok(())
}

fn input(path: &Path) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        // Do not block opening a FIFO before the regular-file check can run.
        .custom_flags((rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::other("not_regular"));
    }
    Ok(file)
}

fn copy_checked(
    reader: impl Read,
    mut output: impl Write,
    limit: u64,
    exact: bool,
    digest: &str,
) -> Result<()> {
    let mut reader = reader.take(limit + 1);
    let mut hash = Sha256::new();
    let mut bytes = 0_u64;
    let mut buffer = [0_u8; 65_536];
    loop {
        let n = reader.read(&mut buffer).map_err(|_| FAILED)?;
        if n == 0 {
            break;
        }
        bytes += n as u64;
        if bytes > limit {
            return Err(FAILED);
        }
        hash.update(&buffer[..n]);
        output.write_all(&buffer[..n]).map_err(|_| FAILED)?;
    }
    let actual: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if (exact && bytes != limit) || actual != digest {
        return Err(FAILED);
    }
    Ok(())
}

/// Read-only validation is intentionally separate from the explicit installer.
pub fn validate(path: &Path) -> Result<()> {
    check_directory(path)?;
    for asset in manifest().assets {
        let reader = input(&path.join(asset.name)).map_err(|_| "model_invalid")?;
        copy_checked(reader, io::sink(), asset.bytes, true, &asset.sha256)
            .map_err(|_| "model_invalid")?;
    }
    Ok(())
}

/// Server checks presence/ownership without loading model bytes before isolation.
pub(crate) fn check_directory(path: &Path) -> Result<()> {
    let m = fs::symlink_metadata(path).map_err(|e| {
        if e.kind() == io::ErrorKind::NotFound {
            "model_missing"
        } else {
            "model_invalid"
        }
    })?;
    if !m.is_dir() || m.uid() != rustix::process::getuid().as_raw() || m.mode() & 0o7777 != 0o700 {
        return Err("model_invalid");
    }
    Ok(())
}

fn output(path: &Path) -> Result<File> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|_| FAILED)
}

fn download(
    agent: &ureq::Agent,
    url: &str,
    path: &Path,
    limit: u64,
    exact: bool,
    hash: &str,
) -> Result<()> {
    let response = agent.get(url).call().map_err(|_| FAILED)?;
    let mut file = output(path)?;
    copy_checked(response.into_reader(), &mut file, limit, exact, hash)?;
    file.sync_all().map_err(|_| FAILED)
}

fn tokenizer(archive: &Path, stage: &Path, manifest: &Manifest) -> Result<()> {
    let mut reader = BufReader::new(input(archive).map_err(|_| FAILED)?);
    let gzip = reader
        .fill_buf()
        .map_err(|_| FAILED)?
        .starts_with(&[0x1f, 0x8b]);
    let reader: Box<dyn Read> = if gzip {
        Box::new(flate2::read::GzDecoder::new(reader))
    } else {
        Box::new(reader)
    };
    let mut tar = tar::Archive::new(reader.take(ARCHIVE_LIMIT + 1));
    let asset = manifest
        .assets
        .iter()
        .find(|a| a.name == "bpe.vocab")
        .expect("manifest tokenizer");
    let mut found = false;
    for entry in tar.entries().map_err(|_| FAILED)? {
        let entry = entry.map_err(|_| FAILED)?;
        // Compare literal member bytes; never unpack paths, permissions or links.
        if entry.path_bytes().as_ref() != manifest.tokenizer_member.as_bytes() {
            continue;
        }
        if found || !entry.header().entry_type().is_file() || entry.size() != asset.bytes {
            return Err(FAILED);
        }
        let mut dest = output(&stage.join(&asset.name))?;
        copy_checked(entry, &mut dest, asset.bytes, true, &asset.sha256)?;
        dest.sync_all().map_err(|_| FAILED)?;
        found = true;
    }
    if !found {
        return Err(FAILED);
    }
    Ok(())
}

// Own only the successfully created stage. Keep the advisory lock inode:
// unlinking it would let concurrent installers lock different files.
struct Staging {
    stage: PathBuf,
    _lock: File,
}
impl Drop for Staging {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.stage);
    }
}

pub fn install(id: &str, source: Option<&Path>) -> Result<()> {
    let manifest = manifest();
    if id != manifest.id {
        return Err("unsupported_model");
    }
    let target = installation()?;
    let models = target.parent().expect("model root");
    let hagig = models.parent().expect("app data root");
    fs::create_dir_all(hagig.parent().expect("data home")).map_err(|_| FAILED)?;
    private_directory(hagig)?;
    private_directory(models)?;
    // Immutable manifest IDs: do not repair/replace an existing target in place.
    if fs::symlink_metadata(&target).is_ok() {
        return validate(&target);
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags((rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32)
        .open(models.join(".install-lock"))
        .map_err(|_| FAILED)?;
    let metadata = lock.metadata().map_err(|_| FAILED)?;
    if !metadata.is_file()
        || metadata.uid() != rustix::process::getuid().as_raw()
        || metadata.mode() & 0o7777 != 0o600
        || metadata.nlink() != 1
    {
        return Err(FAILED);
    }
    lock.try_lock().map_err(|error| match error {
        std::fs::TryLockError::WouldBlock => "model_install_busy",
        _ => FAILED,
    })?;
    let stage = models.join(format!(".stage-{}", std::process::id()));
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&stage)
        .map_err(|_| FAILED)?;
    let cleanup = Staging { stage, _lock: lock };
    let agent = ureq::AgentBuilder::new()
        .https_only(true)
        .redirects(5)
        .timeout(Duration::from_secs(600))
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(Duration::from_secs(30))
        .build();
    for asset in &manifest.assets {
        if let Some(source) = source {
            let reader = input(&source.join(&asset.name)).map_err(|_| FAILED)?;
            let mut file = output(&cleanup.stage.join(&asset.name))?;
            copy_checked(reader, &mut file, asset.bytes, true, &asset.sha256)?;
            file.sync_all().map_err(|_| FAILED)?;
        } else if asset.name != "bpe.vocab" {
            download(
                &agent,
                &format!("{}/{}", manifest.model_url, asset.name),
                &cleanup.stage.join(&asset.name),
                asset.bytes,
                true,
                &asset.sha256,
            )?;
        }
    }
    if source.is_none() {
        let archive = cleanup.stage.join("original.nemo");
        download(
            &agent,
            &manifest.tokenizer_url,
            &archive,
            ARCHIVE_LIMIT,
            false,
            &manifest.tokenizer_archive_sha256,
        )?;
        tokenizer(&archive, &cleanup.stage, &manifest)?;
        fs::remove_file(archive).map_err(|_| FAILED)?;
    }
    validate(&cleanup.stage)?;
    // Recheck after staging, while the installer lock is still held.
    if fs::symlink_metadata(&target).is_ok() {
        return Err(FAILED);
    }
    File::open(&cleanup.stage)
        .and_then(|f| f.sync_all())
        .map_err(|_| FAILED)?;
    fs::rename(&cleanup.stage, &target).map_err(|_| FAILED)?;
    File::open(models)
        .and_then(|f| f.sync_all())
        .map_err(|_| FAILED)?;
    Ok(())
}

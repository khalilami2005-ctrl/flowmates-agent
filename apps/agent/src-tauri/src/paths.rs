//! Single source of truth for filesystem paths used by the agent.
//!
//! Motivation: every module (`auth`, `sync`, `jira`, `linear`, `agent`, `main`)
//! used to build `dirs::data_local_dir().unwrap().join("Flowmates")` on its own,
//! without guaranteeing the directory existed. On a fresh install (pre-login,
//! pre-`initialize_agent`) it does not, and any `Connection::open` or log write
//! failed silently.
//!
//! Every runtime path must go through here. Read-only resources shipped by the
//! Tauri installer resolve through `resource_local_llm_dir`, which needs an
//! `AppHandle`.

use std::path::PathBuf;

use serde_json::json;
use tauri::{AppHandle, Manager};

const APP_DIR_NAME: &str = "Flowmates";
const DB_FILE: &str = "dev-agent.db";
const SERVER_LOG_FILE: &str = "server.log";
const AGENT_ERROR_LOG_FILE: &str = "agent_error.log";
const CRASH_LOG_FILE: &str = "crash.log";
const SCREENSHOTS_TMP_DIR: &str = "screenshots_tmp";

/// Flowmates's local data folder inside the user profile, created if absent.
///
/// Resolved through `dirs::data_local_dir()` (Known Folders on Windows, the
/// equivalent elsewhere): a **real path on disk**, independent of the interface
/// language and of environment variables shown to the user in the UI.
///
/// It is the only writable location we use. It has to behave identically in dev,
/// in a portable release, and in a `Program Files` install — where the install
/// directory is NOT writable by a standard user.
pub fn app_data_dir() -> Result<PathBuf, String> {
    let base = dirs::data_local_dir().ok_or_else(|| "No local data dir available".to_string())?;
    let dir = base.join(APP_DIR_NAME);
    if !dir.exists() {
        std::fs::create_dir_all(&dir).map_err(|e| format!("Failed to create {:?}: {}", dir, e))?;
    }
    Ok(dir)
}

/// Path a `dev-agent.db`. Crea el directorio padre si hace falta.
pub fn db_path() -> Result<PathBuf, String> {
    Ok(app_data_dir()?.join(DB_FILE))
}

/// Variante infalible para sitios donde no podemos propagar Result (panic hooks,
/// static init). En ese caso cae a `.` que es subóptimo pero no panica.
pub fn db_path_or_fallback() -> PathBuf {
    db_path().unwrap_or_else(|_| PathBuf::from(DB_FILE))
}

pub fn server_log_path() -> Result<PathBuf, String> {
    Ok(app_data_dir()?.join(SERVER_LOG_FILE))
}

pub fn auth_log_path() -> Result<PathBuf, String> {
    Ok(app_data_dir()?.join("auth.log"))
}

pub fn agent_error_log_path() -> Result<PathBuf, String> {
    Ok(app_data_dir()?.join(AGENT_ERROR_LOG_FILE))
}

pub fn crash_log_path_or_fallback() -> PathBuf {
    app_data_dir()
        .map(|d| d.join(CRASH_LOG_FILE))
        .unwrap_or_else(|_| PathBuf::from(CRASH_LOG_FILE))
}

/// Persisted screenshot PNGs, for debugging only; the same tree as the database
/// and logs in [`app_data_dir`], subfolder `screenshots_tmp\` — never the Desktop
/// and never the install folder.
pub fn screenshots_tmp_dir() -> Result<PathBuf, String> {
    let dir = app_data_dir()?.join(SCREENSHOTS_TMP_DIR);
    if !dir.exists() {
        std::fs::create_dir_all(&dir).map_err(|e| format!("Failed to create {:?}: {}", dir, e))?;
    }
    Ok(dir)
}

/// Detecta bloqueos de escritura (p. ej. **Controlled Folder Access**, ACL, AV) antes de confiar en SQLite.
pub fn verify_app_dir_filesystem_writable() -> Result<(), String> {
    let dir = app_data_dir()?;
    let probe = dir.join(".flowmates_fs_write_probe");
    std::fs::write(&probe, b"ok").map_err(|e| {
        format!(
            "Cannot write application data under {} ({e}). On Windows 11 this may be Controlled Folder Access or Defender blocking an unsigned app—allow Flowmates or add an exclusion for this folder.",
            dir.display()
        )
    })?;
    let _ = std::fs::remove_file(&probe);
    Ok(())
}

/// Deletes `capture_*` debug screenshots older than `max_age` (retention / compliance).
pub fn prune_screenshots_tmp_older_than(max_age: std::time::Duration) -> Result<usize, String> {
    use std::time::SystemTime;

    let dir = screenshots_tmp_dir()?;
    let now = SystemTime::now();
    let mut removed = 0usize;
    let entries =
        std::fs::read_dir(&dir).map_err(|e| format!("Failed to read screenshots_tmp: {e}"))?;
    for ent in entries.filter_map(Result::ok) {
        let name = ent.file_name();
        let s = name.to_string_lossy();
        if !s.starts_with("capture_") {
            continue;
        }
        let Ok(meta) = ent.metadata() else {
            continue;
        };
        let Ok(mtime) = meta.modified() else {
            continue;
        };
        let Ok(elapsed) = now.duration_since(mtime) else {
            continue;
        };
        if elapsed > max_age {
            let p = ent.path();
            if std::fs::remove_file(&p).is_ok() {
                removed += 1;
            }
        }
    }
    Ok(removed)
}

/// Resuelve el directorio de recursos bundlados donde vive `local_llm/`.
///
/// In an installed `.exe`, Tauri unpacks `bundle.resources` into
/// `<install>\resources\`. In dev, `resource_dir` points at cargo's target
/// directory, so for the development case we fall back to the repository layout
/// (`<repo-root>\local_llm`) when the bundled files are not there.
pub fn resource_local_llm_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("resource_dir unavailable: {}", e))?;

    let bundled = resource_dir.join("local_llm");
    if bundled.join("bin").join("llama-server.exe").exists() {
        return Ok(bundled);
    }

    // Dev fallback: walk up from apps/agent/src-tauri/target/.../<exe> until
    // `local_llm/bin/llama-server.exe` turns up. Used in dev only.
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(|p| p.to_path_buf()).unwrap_or_default();
        for _ in 0..8 {
            let candidate = dir.join("local_llm");
            if candidate.join("bin").join("llama-server.exe").exists() {
                return Ok(candidate);
            }
            if !dir.pop() {
                break;
            }
        }
    }

    Err(format!(
        "local_llm runtime not found (looked in bundled resources at {:?} and dev tree)",
        bundled
    ))
}

fn sanitize_pdf_filename(name: &str) -> Result<String, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() || !trimmed.to_ascii_lowercase().ends_with(".pdf") {
        return Err("Invalid PDF filename".to_string());
    }
    let safe: String = trimmed
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .collect();
    if safe.len() < 5 {
        return Err("Invalid PDF filename".to_string());
    }
    Ok(safe)
}

fn unique_download_path(downloads: &std::path::Path, filename: &str) -> PathBuf {
    let mut path = downloads.join(filename);
    if !path.exists() {
        return path;
    }
    let stem = filename.strip_suffix(".pdf").unwrap_or(filename);
    for n in 2..=99 {
        let candidate = format!("{stem}_{n}.pdf");
        path = downloads.join(&candidate);
        if !path.exists() {
            return path;
        }
    }
    let stamp = chrono::Local::now().format("%H%M%S");
    downloads.join(format!("{stem}_{stamp}.pdf"))
}

/// Saves a PDF into the user's Downloads folder and returns the absolute path written.
#[tauri::command]
pub fn save_pdf_to_downloads(filename: String, bytes: Vec<u8>) -> Result<String, String> {
    let downloads = dirs::download_dir()
        .ok_or_else(|| "Downloads folder not available on this system".to_string())?;
    let safe = sanitize_pdf_filename(&filename)?;
    let path = unique_download_path(&downloads, &safe);
    std::fs::write(&path, &bytes).map_err(|e| format!("Failed to save PDF: {e}"))?;
    Ok(path.to_string_lossy().to_string())
}

/// Opens the folder containing `path` (for a file, opens its parent directory).
#[tauri::command]
pub fn open_path_in_file_manager(path: String) -> Result<(), String> {
    let p = PathBuf::from(path);
    let target = if p.is_file() {
        p.parent()
            .map(|parent| parent.to_path_buf())
            .unwrap_or(p)
    } else {
        p
    };
    open::that(&target).map_err(|e| format!("Could not open folder: {e}"))
}

#[tauri::command]
pub fn get_flowmates_user_paths() -> Result<serde_json::Value, String> {
    let dir = app_data_dir()?;
    Ok(json!({
        "appDataDir": dir.to_string_lossy(),
        "serverLog": server_log_path()?.to_string_lossy(),
        "authLog": auth_log_path()?.to_string_lossy(),
        "agentErrorLog": agent_error_log_path()?.to_string_lossy(),
    }))
}

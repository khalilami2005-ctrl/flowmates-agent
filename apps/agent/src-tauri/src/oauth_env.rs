//! OAuth: `TAURI_*` variables (preferred) are read by the binary only. Never use a
//! `VITE_` prefix for a secret — Vite exposes every `VITE_*` to the renderer. The
//! legacy `VITE_JIRA_*` / `VITE_LINEAR_*` names stay supported for compatibility.
//!
//! In CI: `TAURI_JIRA_CLIENT_ID=... cargo tauri build` bakes the value in through
//! `option_env!`.

fn first_non_empty<const N: usize>(keys: [&str; N]) -> Option<String> {
    for k in keys {
        if let Ok(v) = std::env::var(k) {
            if !v.is_empty() {
                return Some(v);
            }
        }
    }
    None
}

pub fn jira_client_id() -> String {
    first_non_empty(["TAURI_JIRA_CLIENT_ID", "VITE_JIRA_CLIENT_ID"])
        .or_else(|| option_env!("TAURI_JIRA_CLIENT_ID").map(str::to_string))
        .or_else(|| option_env!("VITE_JIRA_CLIENT_ID").map(str::to_string))
        .unwrap_or_else(|| "YOUR_ATLASSIAN_CLIENT_ID".to_string())
}

pub fn jira_client_secret() -> Option<String> {
    let from_env = first_non_empty(["TAURI_JIRA_CLIENT_SECRET", "VITE_JIRA_CLIENT_SECRET"]);
    let from_compile = option_env!("TAURI_JIRA_CLIENT_SECRET")
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| {
            option_env!("VITE_JIRA_CLIENT_SECRET")
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        });
    from_env.or(from_compile)
}

pub fn linear_client_id() -> String {
    first_non_empty(["TAURI_LINEAR_CLIENT_ID", "VITE_LINEAR_CLIENT_ID"])
        .or_else(|| option_env!("TAURI_LINEAR_CLIENT_ID").map(str::to_string))
        .or_else(|| option_env!("VITE_LINEAR_CLIENT_ID").map(str::to_string))
        .unwrap_or_default()
}

pub fn linear_client_secret() -> Option<String> {
    let from_env = first_non_empty(["TAURI_LINEAR_CLIENT_SECRET", "VITE_LINEAR_CLIENT_SECRET"]);
    let from_compile = option_env!("TAURI_LINEAR_CLIENT_SECRET")
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| {
            option_env!("VITE_LINEAR_CLIENT_SECRET")
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        });
    from_env.or(from_compile)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jira_client_id_prefers_tauri_env() {
        temp_env::with_vars(
            [
                ("TAURI_JIRA_CLIENT_ID", Some("from-tauri")),
                ("VITE_JIRA_CLIENT_ID", Some("from-vite")),
            ],
            || {
                assert_eq!(jira_client_id(), "from-tauri");
            },
        );
    }

    #[test]
    fn linear_client_id_falls_back_to_vite() {
        temp_env::with_vars(
            [
                ("TAURI_LINEAR_CLIENT_ID", None::<&str>),
                ("VITE_LINEAR_CLIENT_ID", Some("linear-vite")),
            ],
            || {
                assert_eq!(linear_client_id(), "linear-vite");
            },
        );
    }
}

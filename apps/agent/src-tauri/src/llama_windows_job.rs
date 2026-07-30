//! Windows 11+: a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so that
//! **`llama-server.exe` dies when the Tauri agent process ends** — on a crash, on
//! a `tauri dev` hot reload, or on a shutdown that never reached `stop_server`.
//!
//! Socket inheritance: on Windows, Rust's `TcpListener` creates non-inheritable
//! sockets by default; since the bundled `llama-server` will not take an inherited
//! FD, we make no attempt to hand it the parent's socket.
//!
//! ### "PortGuard" until `/health`
//! The parent process **cannot** hold a listener on `(127.0.0.1, PORT)` until
//! `/health` answers if the child has to bind that same port itself: only **one**
//! `listen` fits there. Without an upstream `--fd`, we rely on the port range plus
//! retries instead (`llama_port` / spawn).

#![cfg_attr(not(windows), allow(dead_code))]

#[cfg(windows)]
mod win {
    use std::io;
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;
    use std::ptr::addr_of;
    use std::sync::Mutex;

    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    struct JobHandle(HANDLE);

    unsafe impl Send for JobHandle {}

    impl Drop for JobHandle {
        fn drop(&mut self) {
            let h = self.0;
            if !h.is_null() && h != INVALID_HANDLE_VALUE {
                unsafe { CloseHandle(h) };
            }
            self.0 = std::ptr::null_mut();
        }
    }

    static LLAMA_JOB: Mutex<Option<JobHandle>> = Mutex::new(None);

    fn lock_job_mu() -> std::sync::MutexGuard<'static, Option<JobHandle>> {
        match LLAMA_JOB.lock() {
            Ok(g) => g,
            Err(p) => {
                log::warn!("[Flowmates] LLAMA_WINDOWS_JOB mutex poisoned; recovering");
                p.into_inner()
            }
        }
    }

    fn create_kill_on_close_job() -> io::Result<JobHandle> {
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() || job == INVALID_HANDLE_VALUE {
                return Err(io::Error::last_os_error());
            }

            let mut extended: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            extended.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            let ok = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                addr_of!(extended).cast(),
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            if ok == 0 {
                let err = io::Error::last_os_error();
                CloseHandle(job);
                return Err(err);
            }

            Ok(JobHandle(job))
        }
    }

    pub fn assign_llama_child_to_kill_on_close_job(child: &Child) -> Result<(), String> {
        let proc = child.as_raw_handle() as HANDLE;
        if proc.is_null() || proc == INVALID_HANDLE_VALUE {
            return Err("child.as_raw_handle() invalid".into());
        }

        let mut guard = lock_job_mu();
        if guard.is_none() {
            *guard =
                Some(create_kill_on_close_job().map_err(|e| format!("CreateJobObjectW: {e}"))?);
        }
        let job_h = guard.as_ref().expect("job set").0;

        let ok = unsafe { AssignProcessToJobObject(job_h, proc) };
        if ok == 0 {
            let os = io::Error::last_os_error();
            log::warn!(
                "[Flowmates] AssignProcessToJobObject failed ({os}); llama-server may orphan on exit"
            );
            return Err(format!("AssignProcessToJobObject: {os}"));
        }
        Ok(())
    }

    pub fn reset_llama_job() {
        lock_job_mu().take();
    }
}

#[cfg(windows)]
pub(crate) use win::{assign_llama_child_to_kill_on_close_job, reset_llama_job};

#[cfg(not(windows))]
pub(crate) fn assign_llama_child_to_kill_on_close_job(
    _child: &std::process::Child,
) -> Result<(), String> {
    Ok(())
}

#[cfg(not(windows))]
pub(crate) fn reset_llama_job() {}

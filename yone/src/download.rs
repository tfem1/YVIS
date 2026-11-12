//! Parallel downloads with an aggregated progress line (speed + ETA).
//! `file://` and plain paths are copied directly (offline / local mirrors);
//! network URLs go through curl, trying each mirror in order.

use crate::error::Result;
use crate::ui::{human_bytes, human_eta, Ui};
use crate::{bail, util};
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub struct Job {
    pub label: String,
    pub urls: Vec<String>,
    pub dest: PathBuf,
    pub size: Option<u64>,
}

#[derive(Clone)]
enum St {
    Waiting,
    Running(PathBuf),
    Done(u64),
    Failed(String),
}

fn fetch_one(urls: &[String], part: &PathBuf) -> std::result::Result<(), String> {
    let mut last = String::from("no mirror configured");
    for url in urls {
        let local = url.strip_prefix("file://").or_else(|| {
            if url.contains("://") {
                None
            } else {
                Some(url.as_str())
            }
        });
        if let Some(p) = local {
            match fs::copy(p, part) {
                Ok(_) => return Ok(()),
                Err(e) => last = format!("{url}: {e}"),
            }
            continue;
        }
        let out = Command::new("curl")
            .args([
                "-fsSL",
                "--proto",
                "=https,http",
                "--retry",
                "2",
                "--connect-timeout",
                "20",
                "-o",
            ])
            .arg(part)
            .arg(url)
            .stdin(Stdio::null())
            .stderr(Stdio::piped())
            .output();
        match out {
            Ok(o) if o.status.success() => return Ok(()),
            Ok(o) => last = format!("{url}: {}", String::from_utf8_lossy(&o.stderr).trim()),
            Err(e) => last = format!("cannot run curl: {e}"),
        }
    }
    Err(last)
}

pub fn fetch_all(jobs: Vec<Job>, parallel: usize, ui: &Ui) -> Result<()> {
    if jobs.is_empty() {
        return Ok(());
    }
    let n = jobs.len();
    let total: u64 = jobs.iter().filter_map(|j| j.size).sum();
    let labels: Vec<String> = jobs.iter().map(|j| j.label.clone()).collect();
    let jobs = Arc::new(jobs);
    let next = Arc::new(AtomicUsize::new(0));
    let states = Arc::new(Mutex::new(vec![St::Waiting; n]));
    let workers = parallel.max(1).min(n);
    let mut handles = vec![];
    for _ in 0..workers {
        let (jobs, next, states) = (jobs.clone(), next.clone(), states.clone());
        handles.push(std::thread::spawn(move || loop {
            let i = next.fetch_add(1, Ordering::SeqCst);
            if i >= jobs.len() {
                break;
            }
            let job = &jobs[i];
            if let Some(parent) = job.dest.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let part = util::suffixed(&job.dest, ".part");
            states.lock().unwrap()[i] = St::Running(part.clone());
            let st = match fetch_one(&job.urls, &part)
                .and_then(|_| fs::rename(&part, &job.dest).map_err(|e| e.to_string()))
            {
                Ok(()) => St::Done(fs::metadata(&job.dest).map(|m| m.len()).unwrap_or(0)),
                Err(e) => {
                    let _ = fs::remove_file(&part);
                    St::Failed(e)
                }
            };
            states.lock().unwrap()[i] = st;
        }));
    }

    let start = Instant::now();
    let mut reported = vec![false; n];
    loop {
        let finished = handles.iter().all(|h| h.is_finished());
        let snapshot = states.lock().unwrap().clone();
        let (mut bytes, mut done) = (0u64, 0usize);
        for (i, s) in snapshot.iter().enumerate() {
            match s {
                St::Running(p) => bytes += fs::metadata(p).map(|m| m.len()).unwrap_or(0),
                St::Done(sz) => {
                    bytes += sz;
                    done += 1;
                    if !ui.tty && !reported[i] {
                        eprintln!("   downloaded {} ({})", labels[i], human_bytes(*sz));
                        reported[i] = true;
                    }
                }
                St::Failed(_) => done += 1,
                St::Waiting => {}
            }
        }
        if ui.tty {
            let el = start.elapsed().as_secs_f64().max(0.001);
            let speed = bytes as f64 / el;
            let frac = if total > 0 {
                bytes as f64 / total as f64
            } else {
                done as f64 / n as f64
            };
            let eta = if total > bytes && speed > 0.0 {
                human_eta((total - bytes) as f64 / speed)
            } else {
                "0:00".into()
            };
            ui.progress(&format!(
                " {} {} {:>3}%  {:>10}/s  ETA {}  {}",
                ui.dim(&format!("[{done}/{n}]")),
                ui.bar(frac, 28),
                (frac * 100.0).round() as u32,
                human_bytes(speed as u64),
                eta,
                ui.dim(&human_bytes(bytes))
            ));
        }
        if finished {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    ui.progress_end();
    for h in handles {
        let _ = h.join();
    }
    let failures: Vec<String> = states
        .lock()
        .unwrap()
        .iter()
        .zip(&labels)
        .filter_map(|(s, l)| {
            if let St::Failed(e) = s {
                Some(format!("{l}: {e}"))
            } else {
                None
            }
        })
        .collect();
    if !failures.is_empty() {
        bail!("download failed:\n  {}", failures.join("\n  "));
    }
    Ok(())
}

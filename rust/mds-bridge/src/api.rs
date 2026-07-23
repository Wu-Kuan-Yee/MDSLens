// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// API types and functions for Flutter bridge. Use JSON serialization for FFI.


#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct FrbSignalSpec {
    pub shot: String,
    pub y_expr: String,
    pub x_expr: String,
    pub experiment: String,
    pub server_ip: String,
    pub color_name: String,
    pub hidden: bool,
    pub read_mode: i32, // 0=Thin, 1=Medium, 2=Full (per-signal override)
}


#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct FrbPlotSpec {
    pub shot: String,
    pub title: String,
    pub x_label: String,
    pub y_label: String,
    pub extraction_points: i32,
    pub grid: bool,
    pub signal_specs: Vec<FrbSignalSpec>,
}


#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct FrbLayoutConfig {
    pub shot: String,
    pub columns: Vec<Vec<FrbPlotSpec>>,
}


#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct FrbSignalSeries {
    pub name: String,
    pub error: String,
    pub uniform_y: Vec<f32>,
    pub uniform_start: f64,
    pub uniform_step: f64,
    pub uniform_min_y: f64,
    pub uniform_max_y: f64,
    pub points: Vec<Vec<f64>>, // [[x,y], ...]
}


#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct FrbLoadedSignal {
    pub column: i32,
    pub row: i32,
    pub signal: i32,
    pub shot: String,
    pub series: FrbSignalSeries,
}


#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct FrbSshSettings {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub identity_file: String,
    pub mode: i32, // 0=Disabled, 1=Auto, 2=Always
}


#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct FrbShotInfo {
    pub shot: i32,
    pub ip: String,
    pub pulse: String,
    pub it: String,
    pub time: String,
}

// ── Converters ─────────────────────────────────────────────────────────

impl From<mds_core::types::SignalSpec> for FrbSignalSpec {
    fn from(s: mds_core::types::SignalSpec) -> Self {
        Self { shot: s.shot, y_expr: s.y_expr, x_expr: s.x_expr, experiment: s.experiment, server_ip: s.server_ip, color_name: s.color_name, hidden: s.hidden, read_mode: s.read_mode.map_or(0, |m| match m { mds_core::types::DataReadMode::Medium => 1, mds_core::types::DataReadMode::Full => 2, _ => 0 }) }
    }
}

impl From<mds_core::types::PlotSpec> for FrbPlotSpec {
    fn from(p: mds_core::types::PlotSpec) -> Self {
        Self { shot: p.shot, title: p.title, x_label: p.x_label, y_label: p.y_label, extraction_points: p.extraction_points, grid: p.grid, signal_specs: p.signal_specs.into_iter().map(Into::into).collect() }
    }
}

impl From<mds_core::types::LayoutConfig> for FrbLayoutConfig {
    fn from(c: mds_core::types::LayoutConfig) -> Self {
        Self {
            shot: c.shot,
            columns: c.columns.into_iter().map(|col| col.into_iter().map(Into::into).collect()).collect(),
        }
    }
}

impl From<mds_core::types::SignalSeries> for FrbSignalSeries {
    fn from(s: mds_core::types::SignalSeries) -> Self {
        let mut points: Vec<Vec<f64>> = s.points.iter().map(|p| p.to_vec()).collect();
        if points.is_empty() && s.has_uniform_data() {
            let n = s.uniform_y.len();
            points.reserve(n);
            for i in 0..n {
                let x = s.uniform_start + i as f64 * s.uniform_step;
                let y = s.uniform_y[i] as f64;
                points.push(vec![x, y]);
            }
        }
        Self { name: s.name, error: s.error, uniform_y: s.uniform_y, uniform_start: s.uniform_start, uniform_step: s.uniform_step, uniform_min_y: s.uniform_min_y, uniform_max_y: s.uniform_max_y, points }
    }
}

impl From<mds_core::types::LoadedSignal> for FrbLoadedSignal {
    fn from(ls: mds_core::types::LoadedSignal) -> Self {
        Self { column: ls.column, row: ls.row, signal: ls.signal, shot: ls.shot, series: ls.series.into() }
    }
}

// ── Reverse converters (Frb → Rust) ────────────────────────────────────

impl FrbLayoutConfig {
    pub fn into_rust(self) -> mds_core::types::LayoutConfig {
        mds_core::types::LayoutConfig {
            file_path: String::new(),
            shot: self.shot,
            columns: self.columns.into_iter().map(|col| {
                col.into_iter().map(|p| mds_core::types::PlotSpec {
                    shot: p.shot, title: p.title, x_label: p.x_label, y_label: p.y_label,
                    extraction_points: p.extraction_points, grid: p.grid,
                    signal_specs: p.signal_specs.into_iter().map(|s| mds_core::types::SignalSpec {
                        shot: s.shot, y_expr: s.y_expr, x_expr: s.x_expr,
                        experiment: s.experiment, server_ip: s.server_ip,
                        color_name: s.color_name, hidden: s.hidden,
                        read_mode: match s.read_mode { 1 => Some(mds_core::types::DataReadMode::Medium), 2 => Some(mds_core::types::DataReadMode::Full), _ => None },
                        ..Default::default()
                    }).collect(),
                    ..Default::default()
                }).collect()
            }).collect(),
            ..Default::default()
        }
    }
}

impl FrbSshSettings {
    pub fn into_rust(self) -> mds_ssh::settings::SshSettings {
        mds_ssh::settings::SshSettings {
            mode: match self.mode { 1 => mds_core::types::SshMode::Auto, 2 => mds_core::types::SshMode::Always, _ => mds_core::types::SshMode::Disabled },
            host: self.host, port: self.port, user: self.user,
            password: self.password, identity_file: self.identity_file,
        }
    }
}

// ── Environment I/O ────────────────────────────────────────────────────


pub fn parse_environment(path: String) -> FrbLayoutConfig {
    mds_core::env_io::parse_environment(&path).into()
}


pub fn write_environment(config: FrbLayoutConfig, path: String) -> Result<(), String> {
    let mut rust = config.into_rust();
    rust.file_path = path.clone();
    mds_core::env_io::write_environment_toml(&rust, &path)
}

pub fn encode_environment(config: FrbLayoutConfig) -> String {
    let rust = config.into_rust();
    mds_core::env_io::encode_environment_toml(&rust)
}

// ── API Auth ───────────────────────────────────────────────────────────


pub fn request_login(api_url: String, user: String, pass: String) -> Result<String, String> {
    mds_auth::http::request_api_token(&api_url, &user, &pass)
}


pub fn fetch_shot(api_url: String, token: String) -> Result<FrbShotInfo, String> {
    let info = mds_auth::http::fetch_latest_shot(&api_url, &token)?;
    Ok(FrbShotInfo { shot: info.shot, ip: info.ip, pulse: info.pulse, it: info.it, time: info.time })
}

pub fn fetch_shot_info(api_url: String, token: String, shot: String) -> Result<FrbShotInfo, String> {
    let info = mds_auth::http::fetch_shot_info(&api_url, &token, &shot)?;
    Ok(FrbShotInfo { shot: info.shot, ip: info.ip, pulse: info.pulse, it: info.it, time: info.time })
}

// ── SSH ────────────────────────────────────────────────────────────────


pub fn ssh_test(settings: FrbSshSettings) -> Result<(), String> {
    let s = mds_ssh::settings::SshSettings { host: settings.host, port: settings.port, user: settings.user, password: settings.password, identity_file: settings.identity_file, ..Default::default() };
    let mgr = mds_ssh::tunnel::SshTunnelManager::new();
    mgr.test_connection(&s)
}

// ── Data Fetch ─────────────────────────────────────────────────────────


pub fn fetch_signals(config_json: String, mode: i32) -> Vec<FrbLoadedSignal> {
    fetch_signals_inner(config_json, mode, None)
}

/// Fetch signals with SSH tunneling. The manager stays alive for the duration
/// of the blocking fetch and is then dropped, stopping its relay listeners.
pub fn fetch_signals_ssh(config_json: String, mode: i32, ssh_settings_json: String) -> Vec<FrbLoadedSignal> {
    let ssh_settings: Option<FrbSshSettings> = if ssh_settings_json.is_empty() {
        None
    } else {
        match serde_json::from_str(&ssh_settings_json) {
            Ok(s) => Some(s),
            Err(e) => return vec![FrbLoadedSignal {
                column: 0, row: 0, signal: 0, shot: "".into(),
                series: FrbSignalSeries { error: format!("SSH settings parse: {}", e), ..Default::default() },
            }],
        }
    };
    fetch_signals_inner(config_json, mode, ssh_settings)
}

fn fetch_signals_inner(config_json: String, mode: i32, ssh_settings: Option<FrbSshSettings>) -> Vec<FrbLoadedSignal> {
    let config: FrbLayoutConfig = match serde_json::from_str(&config_json) {
        Ok(c) => c,
        Err(e) => return vec![FrbLoadedSignal {
            column: 0, row: 0, signal: 0, shot: "".into(),
            series: FrbSignalSeries { error: format!("Config parse: {}", e), ..Default::default() },
        }],
    };
    let read_mode = match mode { 1 => mds_core::types::DataReadMode::Medium, 2 => mds_core::types::DataReadMode::Full, _ => mds_core::types::DataReadMode::Thin };
    let mut rust_config = config.into_rust();

    // Verify config was parsed correctly
    let total_signals: usize = rust_config.columns.iter()
        .flat_map(|c| c.iter())
        .map(|p| p.signal_specs.iter().filter(|s| !s.hidden).count())
        .sum();
    if total_signals == 0 {
        return vec![FrbLoadedSignal {
            column: 0, row: 0, signal: 0, shot: "".into(),
            series: FrbSignalSeries { error: "No signals in config".into(), ..Default::default() },
        }];
    }

    // Set up SSH tunnels if configured
    let _tunnel_manager: Option<mds_ssh::tunnel::SshTunnelManager> = if let Some(ssh) = ssh_settings {
        if !ssh.host.is_empty() && ssh.mode > 0 {
            let mut mgr = mds_ssh::tunnel::SshTunnelManager::new();
            mgr.reload_settings(ssh.into_rust());
            match mgr.prepare_layout(&mut rust_config) {
                Ok(rewrote) => {
                    if rewrote { eprintln!("[mds-bridge] SSH tunnels created for data fetch"); }
                    Some(mgr)
                }
                Err(e) => {
                    // Tunnel setup failed, log but continue with direct connection
                    eprintln!("[mds-bridge] SSH tunnel setup failed (will try direct): {}", e);
                    Some(mgr) // Keep mgr alive to avoid dropping active tunnels
                }
            }
        } else {
            None
        }
    } else {
        None
    };

    let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let callback: mds_ip::pipeline::SignalCallback = Box::new(|_| {});
    let results: Vec<FrbLoadedSignal> = mds_ip::pipeline::fetch_all(&rust_config, read_mode, &callback, &cancel)
        .into_iter().map(FrbLoadedSignal::from).collect();

    results
}

// ── Tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_convert_roundtrip_signal_spec() {
        let orig = mds_core::types::SignalSpec {
            y_expr: "\\pcrl01".into(), experiment: "pcs_east".into(),
            server_ip: "202.127.204.12".into(), ..Default::default()
        };
        let frb = FrbSignalSpec::from(orig.clone());
        assert_eq!(frb.y_expr, "\\pcrl01");
        assert_eq!(frb.experiment, "pcs_east");
    }

    #[test]
    fn test_convert_roundtrip_signal_series() {
        let orig = mds_core::types::SignalSeries {
            name: "test".into(), error: "err".into(),
            uniform_y: vec![1.0, 2.0], uniform_start: 0.0, uniform_step: 0.1,
            uniform_min_y: 1.0, uniform_max_y: 2.0,
            ..Default::default()
        };
        let frb = FrbSignalSeries::from(orig);
        assert_eq!(frb.name, "test");
        assert_eq!(frb.error, "err");
        assert_eq!(frb.uniform_y, vec![1.0, 2.0]);
    }

    #[test]
    fn test_convert_points_to_vec() {
        let orig = mds_core::types::SignalSeries {
            name: "pts".into(),
            points: vec![[0.0, 1.0], [2.0, 3.0]],
            ..Default::default()
        };
        let frb = FrbSignalSeries::from(orig);
        assert_eq!(frb.points.len(), 2);
        assert_eq!(frb.points[0], vec![0.0, 1.0]);
    }

    #[test]
    fn test_parse_environment_toml() {
        let toml_content = "version = 1\n\n[[panels]]\ncolumn = 1\nrow = 1\ntitle = \"Test\"\n\n[[panels.signals]]\ntree = \"pcs_east\"\nserver = \"202.127.204.12\"\ny = \"\\\\pcrl01\"\n";
        let tmp = std::env::temp_dir().join("frb_test.toml");
        std::fs::write(&tmp, toml_content).unwrap();
        let config = parse_environment(tmp.to_str().unwrap().to_string());
        assert_eq!(config.columns.len(), 1);
        assert_eq!(config.columns[0][0].title, "Test");
        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_write_environment_roundtrip() {
        let toml_content = "version = 1\n\n[[panels]]\ncolumn = 1\nrow = 1\ntitle = \"Plasma\"\n\n[[panels.signals]]\ntree = \"pcs_east\"\nserver = \"202.127.204.12\"\ny = \"\\\\pcrl01\"\n";
        let tmp1 = std::env::temp_dir().join("frb_rt1.toml");
        let tmp2 = std::env::temp_dir().join("frb_rt2.toml");
        std::fs::write(&tmp1, toml_content).unwrap();
        let config = parse_environment(tmp1.to_str().unwrap().to_string());
        write_environment(config, tmp2.to_str().unwrap().to_string()).unwrap();
        let config2 = parse_environment(tmp2.to_str().unwrap().to_string());
        assert_eq!(config2.columns[0][0].title, "Plasma");
        std::fs::remove_file(&tmp1).ok();
        std::fs::remove_file(&tmp2).ok();
    }

    #[test]
    fn test_encode_environment_without_file_io() {
        let config = FrbLayoutConfig {
            shot: "143850".into(),
            columns: vec![vec![FrbPlotSpec {
                title: "In-memory export".into(),
                signal_specs: vec![FrbSignalSpec {
                    experiment: "pcs_east".into(),
                    y_expr: "\\pcrl01".into(),
                    ..Default::default()
                }],
                ..Default::default()
            }]],
        };

        let encoded = encode_environment(config);
        assert!(encoded.starts_with("version = 1"));
        assert!(encoded.contains("shot = \"143850\""));
        assert!(encoded.contains("title = \"In-memory export\""));
        assert!(encoded.contains("tree = \"pcs_east\""));
        assert!(encoded.contains("y = \"\\\\pcrl01\""));
    }

    #[test]
    fn test_into_rust_config() {
        let frb = FrbLayoutConfig {
            shot: "143850".into(),
            columns: vec![vec![FrbPlotSpec {
                shot: "143850".into(), title: "Ip".into(),
                x_label: "s".into(), y_label: "kA".into(),
                extraction_points: 2000, grid: true,
                signal_specs: vec![FrbSignalSpec {
                    y_expr: "\\pcrl01".into(), experiment: "pcs_east".into(),
                    server_ip: "202.127.204.12".into(),
                    ..Default::default()
                }],
            }]],
        };
        let rust = frb.into_rust();
        assert_eq!(rust.shot, "143850");
        assert_eq!(rust.columns.len(), 1);
        assert_eq!(rust.columns[0][0].signal_specs[0].y_expr, "\\pcrl01");
    }

    #[test]
    fn test_ssh_settings_into_rust() {
        let frb = FrbSshSettings {
            host: "host".into(), port: 22, user: "user".into(),
            password: "pass".into(), identity_file: "".into(), mode: 1,
        };
        let rust = frb.into_rust();
        assert_eq!(rust.host, "host");
        assert_eq!(rust.port, 22);
    }

    #[test]
    fn test_serialize_config() {
        let frb = FrbLayoutConfig {
            columns: vec![],
            ..Default::default()
        };
        let json = serde_json::to_string(&frb).unwrap();
        let back: FrbLayoutConfig = serde_json::from_str(&json).unwrap();
        assert!(back.columns.is_empty());
    }
}

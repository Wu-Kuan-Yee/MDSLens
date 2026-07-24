// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Core data types for MdsScope.
//!
//! Ported from `src/mdsscope_app.hpp` and `src/core/mdsscope_internal.hpp`.

/// Data read mode controlling sampling quality vs speed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DataReadMode {
    /// Fast preview: server-side SetTimeContext averaging (~4s for 34 EAST signals).
    #[default]
    Thin,
    /// High-resolution stride sampling (~8-11s), preserves spike amplitude.
    Medium,
    /// All raw data, slowest, highest precision.
    Full,
}

/// Controls whether a signal is visible for the current and future shots.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SignalHideMode {
    /// Draw the signal normally.
    #[default]
    Visible,
    /// Hide only until the next full refresh or shot load.
    Temporary,
    /// Keep the signal hidden across refreshes and shot changes.
    Persistent,
}

/// Interaction mode for plot mouse/touch behavior.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InteractionMode {
    /// Rubber-band zoom + Shift-drag pan + scroll zoom.
    #[default]
    Zoom,
    /// Click to track data point, keyboard arrows to step.
    Point,
    /// Drag to pan.
    Pan,
}

/// Theme mode for light/dark appearance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ThemeMode {
    /// Follow OS color scheme.
    #[default]
    Auto,
    Light,
    Dark,
}

/// SSH tunnel mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SshMode {
    #[default]
    Disabled,
    /// Try direct TCP first (450ms probe), fall back to SSH.
    Auto,
    /// Always route through SSH tunnel.
    Always,
}

/// Describes a single MDSplus signal to fetch and plot.
#[derive(Debug, Clone, Default)]
pub struct SignalSpec {
    /// Per-signal shot override (empty = inherit from panel).
    pub shot: String,
    /// MDSplus Y expression (e.g. `\\pcrl01`).
    pub y_expr: String,
    /// Optional MDSplus X expression (empty = use dim_of(y)).
    pub x_expr: String,
    /// Optional user-facing legend label (empty = derive from y_expr).
    pub legend: String,
    /// MDSplus tree / experiment name (e.g. `pcs_east`).
    pub experiment: String,
    /// MDSIP server IP address.
    pub server_ip: String,
    /// Color name (hex) for this signal line.
    pub color_name: String,
    /// True if the user explicitly chose the color.
    pub manual_color: bool,
    /// Effective hidden state retained for backward-compatible consumers.
    pub hidden: bool,
    /// Whether hiding is temporary or persistent.
    pub hide_mode: SignalHideMode,
    /// Per-signal data read mode override.
    pub read_mode: Option<DataReadMode>,
}

impl SignalSpec {
    pub fn is_hidden(&self) -> bool {
        self.hidden || self.hide_mode != SignalHideMode::Visible
    }
}

/// Describes one plot panel (a single chart with axes).
#[derive(Debug, Clone)]
pub struct PlotSpec {
    /// Shot number for all signals in this panel (unless overridden per-signal).
    pub shot: String,
    /// Panel title displayed at top.
    pub title: String,
    /// X-axis label (default "s").
    pub x_label: String,
    /// Y-axis label (default "a.u.").
    pub y_label: String,
    /// Target number of extraction points for Thin/Medium modes.
    pub extraction_points: i32,
    /// Whether to show grid lines.
    pub grid: bool,
    /// True if X range is user-specified (not auto).
    pub custom_x_range: bool,
    pub custom_y_range: bool,
    pub xmin: f64,
    pub xmax: f64,
    pub ymin: f64,
    pub ymax: f64,
    /// Signals to display on this panel.
    pub signal_specs: Vec<SignalSpec>,
}

impl Default for PlotSpec {
    fn default() -> Self {
        Self {
            shot: String::new(),
            title: String::new(),
            x_label: String::new(),
            y_label: String::new(),
            extraction_points: 2000,
            grid: true,
            custom_x_range: false,
            custom_y_range: false,
            xmin: f64::NAN,
            xmax: f64::NAN,
            ymin: f64::NAN,
            ymax: f64::NAN,
            signal_specs: Vec::new(),
        }
    }
}

impl PlotSpec {
    pub fn new() -> Self {
        Self::default()
    }
}

/// The complete dashboard layout: a grid of plot panels.
#[derive(Debug, Clone, Default)]
pub struct LayoutConfig {
    /// Path to the environment file this was loaded from.
    pub file_path: String,
    /// Default shot used by all panels without an explicit override.
    pub shot: String,
    /// Columns of plot panels. Each column is a vector of panels (rows).
    pub columns: Vec<Vec<PlotSpec>>,
}

/// Fetched signal data, stored in one of two representations.
///
/// Ported from the C++ `SignalSeries` struct.
#[derive(Debug, Clone, Default)]
pub struct SignalSeries {
    /// Human-readable name (derived from MDS expression).
    pub name: String,
    /// Error message if fetch failed, empty on success.
    pub error: String,

    // --- Uniform representation (evenly-spaced timebase) ---
    /// Y values as f32 for memory efficiency (adequate for display).
    pub uniform_y: Vec<f32>,
    /// X value of uniform_y[0].
    pub uniform_start: f64,
    /// X step between consecutive uniform_y entries.
    pub uniform_step: f64,
    /// Precomputed min/max Y in uniform data (NaN if not computed).
    pub uniform_min_y: f64,
    pub uniform_max_y: f64,

    // --- Irregular representation (arbitrary X/Y pairs) ---
    /// Explicit (x, y) data points, stored as interleaved [x0, y0, x1, y1, ...].
    pub points: Vec<[f64; 2]>,

    // --- MinMax block index (for O(1) range queries) ---
    pub min_y_blocks: Vec<f32>,
    pub max_y_blocks: Vec<f32>,
    pub min_max_block_size: usize,
}

impl SignalSeries {
    /// Returns true if the signal has uniform (evenly-spaced) data.
    pub fn has_uniform_data(&self) -> bool {
        !self.uniform_y.is_empty()
    }

    /// Returns true if any data is present.
    pub fn has_data(&self) -> bool {
        self.has_uniform_data() || !self.points.is_empty()
    }

    /// Total number of data points.
    pub fn point_count(&self) -> usize {
        if self.has_uniform_data() {
            self.uniform_y.len()
        } else {
            self.points.len()
        }
    }

    /// Access point at index (handles both uniform and irregular).
    pub fn point_at(&self, index: usize) -> Option<[f64; 2]> {
        if self.has_uniform_data() {
            if index < self.uniform_y.len() {
                let x = self.uniform_start + index as f64 * self.uniform_step;
                let y = self.uniform_y[index] as f64;
                Some([x, y])
            } else {
                None
            }
        } else {
            self.points.get(index).copied()
        }
    }
}

/// Result of a completed signal fetch, ready to apply to a plot.
#[derive(Debug, Clone)]
pub struct LoadedSignal {
    pub column: i32,
    pub row: i32,
    pub signal: i32,
    pub shot: String,
    pub series: SignalSeries,
}

/// Font/UI size settings.
#[derive(Debug, Clone)]
pub struct FontSettings {
    pub family: String,
    pub legend_size: i32,
    pub axis_size: i32,
    pub unit_size: i32,
    pub ui_size: i32,
}

impl Default for FontSettings {
    fn default() -> Self {
        #[cfg(target_os = "windows")]
        let size = 10;
        #[cfg(not(target_os = "windows"))]
        let size = 14;

        Self {
            family: "Times New Roman".into(),
            legend_size: size,
            axis_size: size,
            unit_size: size,
            ui_size: size,
        }
    }
}

/// MDSplus API login result.
#[derive(Debug, Clone)]
pub struct ApiLoginResult {
    pub ok: bool,
    pub token: String,
    pub error: String,
}

/// Cached authentication data (API token + SSH settings).
#[derive(Debug, Clone, Default)]
pub struct CachedAuth {
    pub user_name: String,
    pub password: String,
    pub token: String,
    pub ssh: SshSettings,
}

/// SSH connection settings.
#[derive(Debug, Clone, Default)]
pub struct SshSettings {
    pub mode: SshMode,
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub identity_file: String,
}

// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Environment file I/O: TOML and WebScope (.webscp) format parsing and writing.
//!
//! Ported from `src/core/environment_io.cpp`.

use crate::types::{LayoutConfig, SignalHideMode};

fn toml_number_as_f64(value: &toml::Value) -> Option<f64> {
    value
        .as_float()
        .or_else(|| value.as_integer().map(|number| number as f64))
}

/// Parse an environment file, auto-detecting TOML (.toml) or WebScope (.webscp) format.
pub fn parse_environment(path: &str) -> LayoutConfig {
    if path.to_lowercase().ends_with(".toml") {
        parse_toml_environment(path)
    } else {
        parse_webscp_environment(path)
    }
}

/// Parse a TOML-format environment file.
///
/// Format:
/// ```toml
/// version = 1
///
/// [[panels]]
/// column = 1
/// row = 1
/// title = "Plasma current"
/// [[panels.signals]]
/// tree = "pcs_east"
/// server = "202.127.204.12"
/// y = "\\pcrl01"
/// ```
pub fn parse_toml_environment(path: &str) -> LayoutConfig {
    let mut config = LayoutConfig {
        file_path: path.to_string(),
        ..Default::default()
    };

    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("Cannot read {}: {}", path, e);
            return config;
        }
    };

    // Parse as TOML value to handle the array-of-tables structure
    let toml_value: toml::Value = match toml::from_str(&content) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("TOML parse error in {}: {}", path, e);
            return config;
        }
    };

    config.shot = ["shot", "default_shot", "global_shot"]
        .iter()
        .find_map(|key| toml_value.get(*key).and_then(|value| value.as_str()))
        .unwrap_or_default()
        .to_string();

    let panels = toml_value.get("panels").and_then(|v| v.as_array());
    let Some(panels) = panels else {
        return config;
    };

    let mut max_column: usize = 0;
    let mut panel_slots: Vec<PanelSlot> = Vec::new();

    for panel_table in panels {
        let table = match panel_table.as_table() {
            Some(t) => t,
            None => continue,
        };

        let column = table.get("column").and_then(|v| v.as_integer()).unwrap_or(1) as usize;
        let row = table.get("row").and_then(|v| v.as_integer()).unwrap_or(1) as usize;
        max_column = max_column.max(column);

        let mut plot = crate::types::PlotSpec::new();
        if let Some(v) = table.get("shot").and_then(|v| v.as_str()) {
            plot.shot = v.to_string();
        }
        if let Some(v) = table.get("title").and_then(|v| v.as_str()) {
            plot.title = v.to_string();
        }
        if let Some(v) = table.get("x_label").and_then(|v| v.as_str()) {
            plot.x_label = v.to_string();
        }
        if let Some(v) = table.get("y_label").and_then(|v| v.as_str()) {
            plot.y_label = v.to_string();
        }
        if let Some(v) = table.get("extraction_points").and_then(|v| v.as_integer()) {
            if v >= 2 {
                plot.extraction_points = v as i32;
            }
        }
        if let Some(v) = table.get("grid").and_then(|v| v.as_bool()) {
            plot.grid = v;
        }
        if let Some(v) = table.get("custom_x_range").and_then(|v| v.as_bool()) {
            plot.custom_x_range = v;
        }
        if let Some(v) = table.get("custom_y_range").and_then(|v| v.as_bool()) {
            plot.custom_y_range = v;
        }
        if let Some(v) = table.get("xmin").and_then(toml_number_as_f64) {
            plot.xmin = v;
        }
        if let Some(v) = table.get("xmax").and_then(toml_number_as_f64) {
            plot.xmax = v;
        }
        if let Some(v) = table.get("ymin").and_then(toml_number_as_f64) {
            plot.ymin = v;
        }
        if let Some(v) = table.get("ymax").and_then(toml_number_as_f64) {
            plot.ymax = v;
        }

        // Parse nested signals
        if let Some(signals) = table.get("signals").and_then(|v| v.as_array()) {
            for (i, sig_table) in signals.iter().enumerate() {
                let sig = sig_table.as_table();
                let Some(sig) = sig else { continue };

                let mut signal = crate::types::SignalSpec::default();
                if let Some(v) = sig.get("shot").and_then(|v| v.as_str()) {
                    signal.shot = v.to_string();
                }
                if let Some(v) = sig.get("tree").and_then(|v| v.as_str()) {
                    signal.experiment = v.to_string();
                }
                if let Some(v) = sig.get("server").and_then(|v| v.as_str()) {
                    signal.server_ip = v.to_string();
                }
                if let Some(v) = sig.get("y").and_then(|v| v.as_str()) {
                    signal.y_expr = v.to_string();
                }
                if let Some(v) = sig.get("x").and_then(|v| v.as_str()) {
                    signal.x_expr = v.to_string();
                }
                if let Some(v) = sig.get("legend").and_then(|v| v.as_str()) {
                    signal.legend = v.to_string();
                }
                if let Some(v) = sig.get("color").and_then(|v| v.as_str()) {
                    signal.color_name = v.to_string();
                    signal.manual_color = sig.get("manual_color")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                }
                if !signal.manual_color {
                    signal.color_name = crate::colors::color_for_index(i);
                }
                let legacy_hidden = sig.get("hidden").and_then(|v| v.as_bool()).unwrap_or(false);
                signal.hide_mode = match sig.get("hide_mode")
                    .and_then(|v| v.as_str())
                    .map(|v| v.trim().to_ascii_lowercase())
                    .as_deref()
                {
                    Some("temporary" | "current_shot" | "current-shot") => SignalHideMode::Temporary,
                    Some("persistent" | "always") => SignalHideMode::Persistent,
                    Some("visible" | "none" | "not_hidden" | "not-hidden") => SignalHideMode::Visible,
                    _ if legacy_hidden => SignalHideMode::Persistent,
                    _ => SignalHideMode::Visible,
                };
                signal.hidden = signal.hide_mode != SignalHideMode::Visible;
                if let Some(v) = sig.get("read_mode").and_then(|v| v.as_str()) {
                    signal.read_mode = match v {
                        "full" => Some(crate::types::DataReadMode::Full),
                        "medium" => Some(crate::types::DataReadMode::Medium),
                        _ => Some(crate::types::DataReadMode::Thin),
                    };
                }

                plot.signal_specs.push(signal);
            }
        }

        panel_slots.push(PanelSlot {
            column,
            row,
            plot,
        });
    }

    // Sort panels: column first, then row
    panel_slots.sort_by(|a, b| a.column.cmp(&b.column).then(a.row.cmp(&b.row)));

    // Build columns
    config.columns.resize(max_column.max(1), Vec::new());
    for slot in panel_slots {
        if slot.column > 0 {
            config.columns[slot.column - 1].push(slot.plot);
        }
    }

    config
}

/// Parse a legacy WebScope-format (.webscp) environment file.
pub fn parse_webscp_environment(path: &str) -> LayoutConfig {
    let map = read_key_value_file(path);
    let cols = parse_usize(&map, "cols", 1).max(1);
    let mut config = LayoutConfig {
        file_path: path.to_string(),
        shot: trim_quotes(
            map.get("shot")
                .or_else(|| map.get("shot_txt"))
                .or_else(|| map.get("global_shot"))
                .map(|value| value.as_str())
                .unwrap_or(""),
        ),
        columns: vec![Vec::new(); cols],
    };

    for c in 1..=cols {
        let rows_key = format!("{}.rows", c);
        let rows = parse_usize(&map, &rows_key, 0);
        for r in 1..=rows {
            let prefix = format!("{}_{}.", c, r);
            let mut plot = crate::types::PlotSpec::new();

            plot.shot = trim_quotes(map.get(&format!("{}shot_txt", prefix)).map(|s| s.as_str()).unwrap_or(""));
            plot.title = trim_quotes(map.get(&format!("{}title", prefix)).map(|s| s.as_str()).unwrap_or(""));
            plot.x_label = trim_quotes(map.get(&format!("{}xlabel", prefix)).map(|s| s.as_str()).unwrap_or(""));
            plot.y_label = trim_quotes(map.get(&format!("{}ylabel", prefix)).map(|s| s.as_str()).unwrap_or(""));
            plot.extraction_points = parse_i32(&map, &format!("{}extraction_points", prefix),
                parse_i32(&map, "Extraction_points", 2000));
            plot.grid = parse_i32(&map, &format!("{}grid_mode", prefix),
                parse_i32(&map, "Grid_Mode", 1)) != 0;
            plot.custom_x_range = parse_i32(&map, &format!("{}xseting_mode", prefix), 1) == 0;
            plot.custom_y_range = parse_i32(&map, &format!("{}yseting_mode", prefix), 1) == 0;

            if plot.custom_x_range {
                plot.xmin = parse_f64(map.get(&format!("{}xmin_custom", prefix)).map(|s| s.as_str()).unwrap_or(""));
                plot.xmax = parse_f64(map.get(&format!("{}xmax_custom", prefix)).map(|s| s.as_str()).unwrap_or(""));
            }
            if plot.custom_y_range {
                plot.ymin = parse_f64(map.get(&format!("{}ymin_custom", prefix)).map(|s| s.as_str()).unwrap_or(""));
                plot.ymax = parse_f64(map.get(&format!("{}ymax_custom", prefix)).map(|s| s.as_str()).unwrap_or(""));
            }

            let signal_count = parse_usize(&map, &format!("{}num_sig", prefix), 1).max(1);
            for s in 1..=signal_count {
                let _sig_prefix = format!("{}{}_", prefix, s);
                let mut sig = crate::types::SignalSpec::default();

                sig.shot = trim_quotes(map.get(&format!("{}shot_{}", prefix, s)).map(|v| v.as_str()).unwrap_or(""));
                sig.y_expr = trim_quotes(map.get(&format!("{}y_expr_{}", prefix, s)).map(|v| v.as_str()).unwrap_or(""));
                sig.x_expr = trim_quotes(map.get(&format!("{}x_expr_{}", prefix, s)).map(|v| v.as_str()).unwrap_or(""));
                sig.experiment = trim_quotes(map.get(&format!("{}experiment_{}", prefix, s)).map(|v| v.as_str()).unwrap_or(""));
                sig.server_ip = trim_quotes(map.get(&format!("{}server_ip_{}", prefix, s)).map(|v| v.as_str()).unwrap_or(""));
                sig.legend = trim_quotes(map.get(&format!("{}legend_name_{}", prefix, s)).map(|v| v.as_str()).unwrap_or(""));

                let color_name = trim_quotes(map.get(&format!("{}color_name_{}", prefix, s)).map(|v| v.as_str()).unwrap_or(""));
                sig.manual_color = parse_i32(&map, &format!("{}color_manual_{}", prefix, s), 0) != 0;
                if sig.manual_color && !color_name.is_empty() {
                    sig.color_name = color_name;
                } else {
                    sig.color_name = crate::colors::color_for_index(s - 1);
                }
                let legacy_hidden = parse_i32(&map, &format!("{}hidden_{}", prefix, s), 0) != 0;
                sig.hide_mode = match map.get(&format!("{}hide_mode_{}", prefix, s))
                    .map(|value| value.trim().to_ascii_lowercase())
                    .as_deref()
                {
                    Some("temporary" | "current_shot" | "current-shot") => SignalHideMode::Temporary,
                    Some("persistent" | "always") => SignalHideMode::Persistent,
                    Some("visible" | "none" | "not_hidden" | "not-hidden") => SignalHideMode::Visible,
                    _ if legacy_hidden => SignalHideMode::Persistent,
                    _ => SignalHideMode::Visible,
                };
                sig.hidden = sig.hide_mode != SignalHideMode::Visible;
                sig.read_mode = match map.get(&format!("{}read_mode_{}", prefix, s))
                    .map(|value| value.trim().to_ascii_lowercase())
                    .as_deref()
                {
                    Some("full") => Some(crate::types::DataReadMode::Full),
                    Some("medium") => Some(crate::types::DataReadMode::Medium),
                    Some("thin") => Some(crate::types::DataReadMode::Thin),
                    _ => None,
                };

                if !sig.y_expr.is_empty() {
                    plot.signal_specs.push(sig);
                }
            }

            config.columns[c - 1].push(plot);
        }
    }

    config
}

/// Encode a LayoutConfig as a WebScope-compatible flat key-value file.
///
/// Fields understood by the original WebScope format are emitted using their
/// traditional names. MDSLens-specific per-signal settings use additional
/// names that older readers safely ignore and MDSLens restores on re-import.
pub fn encode_environment_webscp(config: &LayoutConfig) -> String {
    use std::fmt::Write;

    fn value(input: &str) -> String {
        input.replace(['\r', '\n'], " ")
    }

    let default_shot = if !config.shot.trim().is_empty() {
        config.shot.trim()
    } else {
        config.columns.iter()
            .flat_map(|column| column.iter())
            .map(|plot| plot.shot.trim())
            .find(|shot| !shot.is_empty())
            .unwrap_or("")
    };
    let mut out = String::new();
    out.push_str("Title_Font: java.awt.Font[family=Times New Roman,name=Times New Roman,style=plain,size=16]\n");
    out.push_str("Measurement_Units: java.awt.Font[family=Times New Roman,name=Times New Roman,style=plain,size=14]\n");
    out.push_str("Coordinate_Axis: java.awt.Font[family=Times New Roman,name=Times New Roman,style=plain,size=12]\n");
    out.push_str("Grid_Mode:1\nX_Lines:5\nY_Lines:5\nExtraction_points:2000\n");
    out.push_str("Vertical_offset:0\nHorizontal_offset:0\n");
    writeln!(out, "shot_txt:{}", value(default_shot)).unwrap();
    writeln!(out, "cols:{}", config.columns.len().max(1)).unwrap();

    for (column_index, column) in config.columns.iter().enumerate() {
        writeln!(out, "{}.rows:{}", column_index + 1, column.len()).unwrap();
        for (row_index, plot) in column.iter().enumerate() {
            let prefix = format!("{}_{}.", column_index + 1, row_index + 1);
            let panel_shot = if plot.shot.trim().is_empty() {
                default_shot
            } else {
                plot.shot.trim()
            };
            writeln!(out, "{}shot_txt:{}", prefix, value(panel_shot)).unwrap();
            writeln!(out, "{}num_shot:1", prefix).unwrap();
            writeln!(out, "{}num_sig:{}", prefix, plot.signal_specs.len()).unwrap();
            writeln!(out, "{}title_position:0", prefix).unwrap();
            writeln!(out, "{}y_log:0", prefix).unwrap();
            writeln!(out, "{}legend:1", prefix).unwrap();
            writeln!(out, "{}legend_position:", prefix).unwrap();
            writeln!(out, "{}xseting_mode:{}", prefix, if plot.custom_x_range { 0 } else { 1 }).unwrap();
            writeln!(out, "{}yseting_mode:{}", prefix, if plot.custom_y_range { 0 } else { 1 }).unwrap();
            writeln!(out, "{}x_line_num:5", prefix).unwrap();
            writeln!(out, "{}y_line_num:5", prefix).unwrap();
            writeln!(out, "{}extraction_points:{}", prefix, plot.extraction_points.max(2)).unwrap();
            writeln!(out, "{}vertical_offset:0", prefix).unwrap();
            writeln!(out, "{}horizontal_offset:0", prefix).unwrap();
            writeln!(out, "{}grid_mode:{}", prefix, i32::from(plot.grid)).unwrap();
            writeln!(out, "{}xmin_custom:{}", prefix, if plot.custom_x_range && plot.xmin.is_finite() { plot.xmin.to_string() } else { String::new() }).unwrap();
            writeln!(out, "{}xmax_custom:{}", prefix, if plot.custom_x_range && plot.xmax.is_finite() { plot.xmax.to_string() } else { String::new() }).unwrap();
            writeln!(out, "{}ymin_custom:{}", prefix, if plot.custom_y_range && plot.ymin.is_finite() { plot.ymin.to_string() } else { String::new() }).unwrap();
            writeln!(out, "{}ymax_custom:{}", prefix, if plot.custom_y_range && plot.ymax.is_finite() { plot.ymax.to_string() } else { String::new() }).unwrap();
            writeln!(out, "{}title:{}", prefix, value(&plot.title)).unwrap();
            writeln!(out, "{}xlabel:{}", prefix, value(&plot.x_label)).unwrap();
            writeln!(out, "{}ylabel:{}", prefix, value(&plot.y_label)).unwrap();

            for (signal_index, signal) in plot.signal_specs.iter().enumerate() {
                let number = signal_index + 1;
                let signal_shot = if signal.shot.trim().is_empty() {
                    panel_shot
                } else {
                    signal.shot.trim()
                };
                writeln!(out, "{}shot_{}:{}", prefix, number, value(signal_shot)).unwrap();
                writeln!(out, "{}color_{}_{}:{}", prefix, row_index + 1, number, signal_index % 16).unwrap();
                writeln!(out, "{}markers_{}_{}:0", prefix, row_index + 1, number).unwrap();
                writeln!(out, "{}interpolate_{}_{}:1", prefix, row_index + 1, number).unwrap();
                writeln!(out, "{}y_expr_{}:{}", prefix, number, value(&signal.y_expr)).unwrap();
                writeln!(out, "{}x_expr_{}:{}", prefix, number, value(&signal.x_expr)).unwrap();
                writeln!(out, "{}experiment_{}:{}", prefix, number, value(&signal.experiment)).unwrap();
                writeln!(out, "{}server_ip_{}:{}", prefix, number, value(&signal.server_ip)).unwrap();
                writeln!(out, "{}legend_name_{}:{}", prefix, number, value(&signal.legend)).unwrap();
                writeln!(out, "{}color_name_{}:{}", prefix, number, value(&signal.color_name)).unwrap();
                writeln!(out, "{}color_manual_{}:{}", prefix, number, i32::from(signal.manual_color)).unwrap();
                let hide_mode = if signal.hide_mode == SignalHideMode::Visible && signal.hidden {
                    SignalHideMode::Persistent
                } else {
                    signal.hide_mode
                };
                writeln!(out, "{}hidden_{}:{}", prefix, number, i32::from(hide_mode != SignalHideMode::Visible)).unwrap();
                writeln!(out, "{}hide_mode_{}:{}", prefix, number, match hide_mode {
                    SignalHideMode::Temporary => "temporary",
                    SignalHideMode::Persistent => "persistent",
                    SignalHideMode::Visible => "visible",
                }).unwrap();
                writeln!(out, "{}read_mode_{}:{}", prefix, number, match signal.read_mode {
                    Some(crate::types::DataReadMode::Full) => "full",
                    Some(crate::types::DataReadMode::Medium) => "medium",
                    _ => "thin",
                }).unwrap();
            }
        }
    }
    out
}

/// Encode a LayoutConfig as TOML without touching the filesystem.
pub fn encode_environment_toml(config: &LayoutConfig) -> String {
    use std::fmt::Write;

    let mut out = String::new();
    out.push_str("version = 1\n\n");

    // Find most common shot as default
    let mut shot_counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for col in &config.columns {
        for plot in col {
            let shot = plot.shot.trim();
            if !shot.is_empty() {
                *shot_counts.entry(shot).or_default() += plot.signal_specs.len().max(1);
            }
        }
    }
    let default_shot = if config.shot.trim().is_empty() {
        shot_counts.into_iter()
        .max_by_key(|(_, count)| *count)
        .map(|(shot, _)| shot.to_string())
        .unwrap_or_default()
    } else {
        config.shot.trim().to_string()
    };
    if !default_shot.is_empty() {
        writeln!(out, "shot = {:?}\n", default_shot).unwrap();
    }

    for (c, column) in config.columns.iter().enumerate() {
        for (r, plot) in column.iter().enumerate() {
            let _panel_shot = plot.shot.trim();
            out.push_str("[[panels]]\n");
            writeln!(out, "column = {}", c + 1).unwrap();
            writeln!(out, "row = {}", r + 1).unwrap();
            if !plot.title.is_empty() {
                writeln!(out, "title = {:?}", plot.title).unwrap();
            }
            if !plot.x_label.is_empty() {
                writeln!(out, "x_label = {:?}", plot.x_label).unwrap();
            }
            if !plot.y_label.is_empty() {
                writeln!(out, "y_label = {:?}", plot.y_label).unwrap();
            }
            if plot.extraction_points != 2000 {
                writeln!(out, "extraction_points = {}", plot.extraction_points).unwrap();
            }
            if !plot.grid {
                writeln!(out, "grid = false").unwrap();
            }
            if plot.custom_x_range {
                writeln!(out, "custom_x_range = true").unwrap();
            }
            if plot.custom_y_range {
                writeln!(out, "custom_y_range = true").unwrap();
            }
            if plot.custom_x_range {
                if plot.xmin.is_finite() { writeln!(out, "xmin = {}", plot.xmin).unwrap(); }
                if plot.xmax.is_finite() { writeln!(out, "xmax = {}", plot.xmax).unwrap(); }
            }
            if plot.custom_y_range {
                if plot.ymin.is_finite() { writeln!(out, "ymin = {}", plot.ymin).unwrap(); }
                if plot.ymax.is_finite() { writeln!(out, "ymax = {}", plot.ymax).unwrap(); }
            }
            out.push('\n');

            for (s, signal) in plot.signal_specs.iter().enumerate() {
                out.push_str("[[panels.signals]]\n");
                let signal_shot = signal.shot.trim();
                let resolved_shot = if !signal_shot.is_empty() {
                    signal_shot
                } else if !plot.shot.trim().is_empty() {
                    plot.shot.trim()
                } else {
                    default_shot.as_str()
                };
                let resolved_color = if signal.color_name.trim().is_empty() {
                    crate::colors::color_for_index(s)
                } else {
                    signal.color_name.clone()
                };
                writeln!(out, "shot = {:?}", resolved_shot).unwrap();
                writeln!(out, "tree = {:?}", signal.experiment).unwrap();
                writeln!(out, "server = {:?}", signal.server_ip).unwrap();
                writeln!(out, "y = {:?}", signal.y_expr).unwrap();
                writeln!(out, "x = {:?}", signal.x_expr).unwrap();
                writeln!(out, "legend = {:?}", signal.legend).unwrap();
                writeln!(out, "color = {:?}", resolved_color).unwrap();
                writeln!(out, "manual_color = {}", signal.manual_color).unwrap();
                let hide_mode = if signal.hide_mode == SignalHideMode::Visible && signal.hidden {
                    // Old in-memory callers only had `hidden`; preserve their intent.
                    SignalHideMode::Persistent
                } else {
                    signal.hide_mode
                };
                writeln!(out, "hidden = {}", hide_mode != SignalHideMode::Visible).unwrap();
                writeln!(out, "hide_mode = {:?}", match hide_mode {
                    SignalHideMode::Temporary => "temporary",
                    SignalHideMode::Persistent => "persistent",
                    SignalHideMode::Visible => "visible",
                }).unwrap();
                match signal.read_mode {
                    Some(crate::types::DataReadMode::Full) => writeln!(out, "read_mode = \"full\"").unwrap(),
                    Some(crate::types::DataReadMode::Medium) => writeln!(out, "read_mode = \"medium\"").unwrap(),
                    _ => writeln!(out, "read_mode = \"thin\"").unwrap(),
                }
                out.push('\n');
            }
        }
    }

    out
}

/// Write a LayoutConfig as TOML.
pub fn write_environment_toml(config: &LayoutConfig, path: &str) -> Result<(), String> {
    let out = encode_environment_toml(config);
    std::fs::write(path, &out).map_err(|e| format!("Cannot write {}: {}", path, e))
}

/// Write a LayoutConfig as WebScope.
pub fn write_environment_webscp(config: &LayoutConfig, path: &str) -> Result<(), String> {
    let out = encode_environment_webscp(config);
    std::fs::write(path, &out).map_err(|e| format!("Cannot write {}: {}", path, e))
}

// ── Helpers ──────────────────────────────────────────────────────────────

struct PanelSlot {
    column: usize,
    row: usize,
    plot: crate::types::PlotSpec,
}

/// Read a flat key-value file (WebScope format).
/// Delimiters can be `:` or `=` (first occurrence of `=` wins if both present).
fn read_key_value_file(path: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return map,
    };

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Find delimiter: `=` takes priority if it appears before `:`
        let eq_pos = line.find('=');
        let colon_pos = line.find(':');

        let delim_pos = match (eq_pos, colon_pos) {
            (Some(e), Some(c)) => Some(e.min(c)),
            (Some(e), None) => Some(e),
            (None, Some(c)) => Some(c),
            (None, None) => None,
        };

        if let Some(pos) = delim_pos {
            let key = line[..pos].trim().to_string();
            let value = line[pos + 1..].trim().to_string();
            // Apply Java-style unescaping
            let value = value.replace("\\:", ":").replace("\\=", "=").replace("\\\\", "\\");
            map.insert(key, value);
        }
    }

    map
}

fn trim_quotes(s: &str) -> String {
    let s = s.trim();
    if s.len() >= 2 {
        let first = s.chars().next().unwrap();
        let last = s.chars().last().unwrap();
        if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
            return s[1..s.len() - 1].to_string();
        }
    }
    s.to_string()
}

fn parse_usize(map: &std::collections::HashMap<String, String>, key: &str, fallback: usize) -> usize {
    map.get(key)
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(fallback)
}

fn parse_i32(map: &std::collections::HashMap<String, String>, key: &str, fallback: i32) -> i32 {
    map.get(key)
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(fallback)
}

fn parse_f64(s: &str) -> f64 {
    s.trim().parse().unwrap_or(f64::NAN)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_toml_basic() {
        let toml_content = r#"
version = 1

[[panels]]
column = 1
row = 1
title = "Test Panel"
x_label = "s"
y_label = "kA"

[[panels.signals]]
tree = "pcs_east"
server = "202.127.204.12"
y = "\\pcrl01"
"#;
        let tmp = std::env::temp_dir().join("test_mds.toml");
        std::fs::write(&tmp, toml_content).unwrap();

        let config = parse_toml_environment(tmp.to_str().unwrap());
        assert_eq!(config.columns.len(), 1);
        assert_eq!(config.columns[0].len(), 1);
        let plot = &config.columns[0][0];
        assert_eq!(plot.title, "Test Panel");
        assert_eq!(plot.x_label, "s");
        assert_eq!(plot.y_label, "kA");
        assert_eq!(plot.signal_specs.len(), 1);
        assert_eq!(plot.signal_specs[0].y_expr, "\\pcrl01");
        assert_eq!(plot.signal_specs[0].experiment, "pcs_east");

        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_parse_webscp_basic() {
        let webscp_content = r#"
cols: 1
1.rows: 1
1_1.shot_txt: 143850
1_1.title: Test
1_1.xlabel: s
1_1.ylabel: kA
1_1.num_sig: 1
1_1.y_expr_1: \pcrl01
1_1.experiment_1: pcs_east
1_1.server_ip_1: 202.127.204.12
"#;
        let tmp = std::env::temp_dir().join("test_mds.webscp");
        std::fs::write(&tmp, webscp_content).unwrap();

        let config = parse_webscp_environment(tmp.to_str().unwrap());
        assert_eq!(config.columns.len(), 1);
        assert_eq!(config.columns[0].len(), 1);
        let plot = &config.columns[0][0];
        assert_eq!(plot.shot, "143850");
        assert_eq!(plot.title, "Test");
        assert_eq!(plot.signal_specs.len(), 1);
        assert_eq!(plot.signal_specs[0].y_expr, "\\pcrl01");

        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_toml_roundtrip() {
        let toml_content = r#"
version = 1

[[panels]]
column = 1
row = 1
title = "Plasma Current"

[[panels.signals]]
tree = "pcs_east"
server = "202.127.204.12"
y = "\\pcrl01"
"#;
        let tmp = std::env::temp_dir().join("test_roundtrip.toml");
        let tmp2 = std::env::temp_dir().join("test_roundtrip_out.toml");
        std::fs::write(&tmp, toml_content).unwrap();

        let config = parse_toml_environment(tmp.to_str().unwrap());
        let encoded = encode_environment_toml(&config);
        assert!(encoded.contains("title = \"Plasma Current\""));
        assert!(encoded.contains("y = \"\\\\pcrl01\""));
        write_environment_toml(&config, tmp2.to_str().unwrap()).unwrap();
        assert_eq!(std::fs::read_to_string(&tmp2).unwrap(), encoded);

        let config2 = parse_toml_environment(tmp2.to_str().unwrap());
        assert_eq!(config2.columns.len(), 1);
        assert_eq!(config2.columns[0][0].title, "Plasma Current");
        assert_eq!(config2.columns[0][0].signal_specs.len(), 1);
        assert_eq!(config2.columns[0][0].signal_specs[0].y_expr, "\\pcrl01");

        std::fs::remove_file(&tmp).ok();
        std::fs::remove_file(&tmp2).ok();
    }

    #[test]
    fn test_toml_roundtrip_preserves_default_shot() {
        let toml_content = r#"
version = 1
shot = "143850"

[[panels]]
column = 1
row = 1

[[panels.signals]]
tree = "pcs_east"
server = "202.127.204.12"
y = "\\pcrl01"
"#;
        let tmp = std::env::temp_dir().join("test_default_shot.toml");
        std::fs::write(&tmp, toml_content).unwrap();
        let config = parse_toml_environment(tmp.to_str().unwrap());
        assert_eq!(config.shot, "143850");
        let encoded = encode_environment_toml(&config);
        assert!(encoded.contains("shot = \"143850\""));
        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_toml_roundtrip_preserves_every_signal_setting() {
        let config = LayoutConfig {
            shot: "163900".into(),
            columns: vec![vec![crate::types::PlotSpec {
                signal_specs: vec![
                    crate::types::SignalSpec {
                        shot: "163899".into(),
                        y_expr: "\\FIRST".into(),
                        x_expr: "dim_of(\\FIRST)".into(),
                        legend: "Primary current".into(),
                        experiment: "tree_a".into(),
                        server_ip: "10.0.0.1".into(),
                        color_name: "#123456".into(),
                        manual_color: true,
                        hidden: true,
                        hide_mode: crate::types::SignalHideMode::Temporary,
                        read_mode: Some(crate::types::DataReadMode::Full),
                    },
                    crate::types::SignalSpec {
                        shot: "163900".into(),
                        y_expr: "\\SECOND".into(),
                        experiment: "tree_b".into(),
                        server_ip: "10.0.0.2".into(),
                        color_name: "#c44e52".into(),
                        manual_color: false,
                        hidden: false,
                        read_mode: Some(crate::types::DataReadMode::Medium),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }]],
            ..Default::default()
        };
        let encoded = encode_environment_toml(&config);
        assert!(encoded.contains("shot = \"163899\""));
        assert!(encoded.contains("x = \"dim_of(\\\\FIRST)\""));
        assert!(encoded.contains("legend = \"Primary current\""));
        assert!(encoded.contains("color = \"#123456\""));
        assert!(encoded.contains("manual_color = true"));
        assert!(encoded.contains("hidden = true"));
        assert!(encoded.contains("hide_mode = \"temporary\""));
        assert!(encoded.contains("read_mode = \"full\""));
        assert!(encoded.contains("shot = \"163900\""));
        assert!(encoded.contains("manual_color = false"));
        assert!(encoded.contains("hidden = false"));
        assert!(encoded.contains("hide_mode = \"visible\""));
        assert!(encoded.contains("read_mode = \"medium\""));

        let tmp = std::env::temp_dir().join("test_complete_signal_settings.toml");
        std::fs::write(&tmp, encoded).unwrap();
        let decoded = parse_toml_environment(tmp.to_str().unwrap());
        let first = &decoded.columns[0][0].signal_specs[0];
        let second = &decoded.columns[0][0].signal_specs[1];
        assert_eq!(first.shot, "163899");
        assert_eq!(first.x_expr, "dim_of(\\FIRST)");
        assert_eq!(first.legend, "Primary current");
        assert_eq!(first.color_name, "#123456");
        assert!(first.manual_color);
        assert!(first.hidden);
        assert_eq!(first.hide_mode, crate::types::SignalHideMode::Temporary);
        assert_eq!(first.read_mode, Some(crate::types::DataReadMode::Full));
        assert_eq!(second.shot, "163900");
        assert_eq!(second.color_name, crate::colors::color_for_index(1));
        assert!(!second.manual_color);
        assert!(!second.hidden);
        assert_eq!(second.hide_mode, crate::types::SignalHideMode::Visible);
        assert_eq!(second.read_mode, Some(crate::types::DataReadMode::Medium));
        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_toml_parser_preserves_more_than_six_panels() {
        let mut content = String::from("version = 1\nshot = \"163807\"\n\n");
        for index in 0..9 {
            let column = index / 3 + 1;
            let row = index % 3 + 1;
            content.push_str(&format!(
                "[[panels]]\ncolumn = {column}\nrow = {row}\n\
                 title = \"Panel {}\"\n\n[[panels.signals]]\n\
                 tree = \"pcs_east\"\nserver = \"202.127.204.12\"\n\
                 y = \"\\\\signal_{index}\"\n\n",
                index + 1,
            ));
        }
        let tmp = std::env::temp_dir().join("test_nine_panel_layout.toml");
        std::fs::write(&tmp, content).unwrap();
        let config = parse_toml_environment(tmp.to_str().unwrap());
        std::fs::remove_file(&tmp).ok();

        assert_eq!(config.columns.len(), 3);
        assert_eq!(config.columns.iter().map(Vec::len).sum::<usize>(), 9);
        assert_eq!(config.columns[2][2].title, "Panel 9");
        assert_eq!(config.columns[2][2].signal_specs[0].y_expr, "\\signal_8");
    }

    #[test]
    fn test_webscp_roundtrip_preserves_supported_panel_and_signal_settings() {
        let config = LayoutConfig {
            shot: "163999".into(),
            columns: vec![vec![crate::types::PlotSpec {
                shot: "163999".into(),
                title: "Plasma current".into(),
                x_label: "s".into(),
                y_label: "kA".into(),
                extraction_points: 4096,
                grid: false,
                custom_x_range: true,
                custom_y_range: true,
                xmin: -1.5,
                xmax: 8.25,
                ymin: -10.0,
                ymax: 600.0,
                signal_specs: vec![crate::types::SignalSpec {
                    shot: "164000".into(),
                    y_expr: "\\pcrl01".into(),
                    x_expr: "dim_of(\\pcrl01)".into(),
                    legend: "Ip".into(),
                    experiment: "pcs_east".into(),
                    server_ip: "202.127.204.12:8000".into(),
                    color_name: "#123456".into(),
                    manual_color: true,
                    hidden: true,
                    hide_mode: SignalHideMode::Persistent,
                    read_mode: Some(crate::types::DataReadMode::Full),
                }],
            }]],
            ..Default::default()
        };

        let encoded = encode_environment_webscp(&config);
        assert!(encoded.contains("cols:1"));
        assert!(encoded.contains("1_1.xmax_custom:8.25"));
        assert!(encoded.contains("1_1.ymax_custom:600"));
        assert!(encoded.contains("1_1.legend_name_1:Ip"));
        assert!(encoded.contains("1_1.read_mode_1:full"));

        let tmp = std::env::temp_dir().join("mdslens_complete.webscp");
        std::fs::write(&tmp, encoded).unwrap();
        let decoded = parse_webscp_environment(tmp.to_str().unwrap());
        std::fs::remove_file(&tmp).ok();

        let panel = &decoded.columns[0][0];
        assert_eq!(panel.title, "Plasma current");
        assert_eq!(panel.x_label, "s");
        assert_eq!(panel.y_label, "kA");
        assert_eq!(panel.extraction_points, 4096);
        assert!(!panel.grid);
        assert_eq!((panel.xmin, panel.xmax), (-1.5, 8.25));
        assert_eq!((panel.ymin, panel.ymax), (-10.0, 600.0));
        let signal = &panel.signal_specs[0];
        assert_eq!(signal.shot, "164000");
        assert_eq!(signal.legend, "Ip");
        assert_eq!(signal.color_name, "#123456");
        assert!(signal.manual_color);
        assert!(signal.hidden);
        assert_eq!(signal.hide_mode, SignalHideMode::Persistent);
        assert_eq!(signal.read_mode, Some(crate::types::DataReadMode::Full));
    }

    #[test]
    fn test_parser_repairs_zero_point_configs_from_older_flutter_builds() {
        let content = r#"
version = 1
shot = "163870"

[[panels]]
column = 1
row = 1
title = "Ip"
extraction_points = 0
grid = false
xmin = 0
xmax = 0
ymin = 0
ymax = 0

[[panels.signals]]
tree = "pcs_east"
server = "202.127.204.12"
y = "\\pcrl01"
"#;
        let tmp = std::env::temp_dir().join("mdslens_zero_points.toml");
        std::fs::write(&tmp, content).unwrap();
        let config = parse_toml_environment(tmp.to_str().unwrap());
        std::fs::remove_file(&tmp).ok();

        let plot = &config.columns[0][0];
        assert_eq!(plot.extraction_points, 2000);
        assert!(!plot.grid);
        assert_eq!(plot.xmin, 0.0);
        assert_eq!(plot.xmax, 0.0);
    }

    #[test]
    fn test_parse_empty_toml_layout() {
        let tmp = std::env::temp_dir().join("mdslens_empty_layout.toml");
        std::fs::write(&tmp, "version = 1\n").unwrap();
        let config = parse_toml_environment(tmp.to_str().unwrap());
        std::fs::remove_file(&tmp).ok();

        assert!(config.columns.is_empty());
    }

    #[test]
    fn test_parse_empty_webscp_layout() {
        let tmp = std::env::temp_dir().join("mdslens_empty_layout.webscp");
        std::fs::write(&tmp, "cols:1\n1.rows:0\n").unwrap();
        let config = parse_webscp_environment(tmp.to_str().unwrap());
        std::fs::remove_file(&tmp).ok();

        assert_eq!(config.columns.len(), 1);
        assert!(config.columns[0].is_empty());
    }
}

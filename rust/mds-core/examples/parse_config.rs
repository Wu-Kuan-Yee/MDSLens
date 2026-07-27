// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Demo: parse a real EAST config file and print its structure.

use mds_core::env_io::parse_environment;
use std::env;
use std::path::Path;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        let default = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../MDSLens/resources/environment/init.toml");
        eprintln!("Usage: {} <config.toml|config.webscp>", args[0]);
        eprintln!("  Default: {:?}", default);
        std::process::exit(1);
    }

    let path = &args[1];
    if !Path::new(path).exists() {
        eprintln!("Error: file not found: {}", path);
        std::process::exit(1);
    }

    let config = parse_environment(path);
    print_config(&config);
}

fn print_config(config: &mds_core::types::LayoutConfig) {
    println!("File: {}", config.file_path);
    println!("Columns: {}", config.columns.len());
    println!();

    for (c, column) in config.columns.iter().enumerate() {
        println!("Column {}: {} panels", c + 1, column.len());
        for (r, plot) in column.iter().enumerate() {
            println!("  Row {}: \"{}\" ({} signals)", r + 1, plot.title, plot.signal_specs.len());
            if !plot.x_label.is_empty() {
                println!("    X: {}", plot.x_label);
            }
            if !plot.y_label.is_empty() {
                println!("    Y: {}", plot.y_label);
            }
            if !plot.shot.is_empty() {
                println!("    Shot: {}", plot.shot);
            }
            if !plot.grid {
                println!("    Grid: off");
            }
            if plot.custom_x_range {
                println!("    X range: [{}, {}]", plot.xmin, plot.xmax);
            }
            if plot.custom_y_range {
                println!("    Y range: [{}, {}]", plot.ymin, plot.ymax);
            }
            if plot.extraction_points != 2000 {
                println!("    Points: {}", plot.extraction_points);
            }

            for (s, sig) in plot.signal_specs.iter().enumerate() {
                println!("    Signal {}: y={}, tree={}, server={}, color={}",
                    s + 1, sig.y_expr, sig.experiment, sig.server_ip, sig.color_name);
                if !sig.x_expr.is_empty() {
                    println!("      x={}", sig.x_expr);
                }
                if sig.hidden {
                    println!("      hidden");
                }
                if let Some(mode) = &sig.read_mode {
                    println!("      read_mode={:?}", mode);
                }
            }
        }
        println!();
    }

    // Statistics
    let total_panels: usize = config.columns.iter().map(|c| c.len()).sum();
    let total_signals: usize = config.columns.iter()
        .flat_map(|c| c.iter())
        .map(|p| p.signal_specs.len())
        .sum();
    let hidden_signals: usize = config.columns.iter()
        .flat_map(|c| c.iter())
        .flat_map(|p| p.signal_specs.iter())
        .filter(|s| s.hidden)
        .count();

    println!("---");
    println!("Total: {} panels, {} signals ({} hidden)",
        total_panels, total_signals, hidden_signals);
}

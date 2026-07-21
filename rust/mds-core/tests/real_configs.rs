// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Integration tests using real EAST configuration files.

use mds_core::env_io::{parse_environment, parse_toml_environment, parse_webscp_environment, write_environment_toml};
use std::path::Path;

fn resource_dir() -> &'static str {
    "../../../MdsScope/resources/environment"
}

fn assert_init_config_valid(config: &mds_core::types::LayoutConfig, source: &str) {
    assert_eq!(config.columns.len(), 2, "{}: expected 2 columns", source);

    // Column 1: Ip, R, Z (3 rows)
    let col1 = &config.columns[0];
    assert_eq!(col1.len(), 3, "{}: column 1 should have 3 rows", source);
    assert_eq!(col1[0].title, "Ip", "{}: col1 row1 title", source);
    assert_eq!(col1[1].title, "R", "{}: col1 row2 title", source);
    assert_eq!(col1[2].title, "Z", "{}: col1 row3 title", source);

    // Column 2: Vloop, Ne, Pf1 current (3 rows)
    let col2 = &config.columns[1];
    assert_eq!(col2.len(), 3, "{}: column 2 should have 3 rows", source);
    assert_eq!(col2[0].title, "Vloop", "{}: col2 row1 title", source);
    assert_eq!(col2[1].title, "Ne", "{}: col2 row2 title", source);
    assert_eq!(col2[2].title, "Pf1 current", "{}: col2 row3 title", source);

    // Check signal specs on first panel
    let ip_panel = &col1[0];
    assert_eq!(ip_panel.signal_specs.len(), 1);
    let ip_sig = &ip_panel.signal_specs[0];
    assert_eq!(ip_sig.y_expr, "\\pcrl01");
    assert_eq!(ip_sig.experiment, "pcs_east");
    assert_eq!(ip_sig.server_ip, "202.127.204.12");
    assert_eq!(ip_panel.extraction_points, 2000);
    assert!(ip_panel.grid);

    // All 6 panels should have 1 signal each with the same server/tree
    for (c, col) in config.columns.iter().enumerate() {
        for (r, panel) in col.iter().enumerate() {
            assert_eq!(
                panel.signal_specs.len(), 1,
                "{}: col{} row{} signal count", source, c + 1, r + 1
            );
            for (s, sig) in panel.signal_specs.iter().enumerate() {
                assert_eq!(sig.experiment, "pcs_east",
                    "{}: col{} row{} sig{} tree", source, c + 1, r + 1, s);
                assert_eq!(sig.server_ip, "202.127.204.12",
                    "{}: col{} row{} sig{} server", source, c + 1, r + 1, s);
                assert!(!sig.y_expr.is_empty(),
                    "{}: col{} row{} sig{} y_expr empty", source, c + 1, r + 1, s);
                // Color should be assigned from preset palette
                assert!(!sig.color_name.is_empty(),
                    "{}: col{} row{} sig{} color missing", source, c + 1, r + 1, s);
            }
        }
    }

    // Check expected signal expressions
    let expected_y: [&str; 6] = ["\\pcrl01", "\\lmsr", "\\lmsz", "\\pcvloop", "\\dfsdev", "\\pcpf1"];
    let mut actual_y: Vec<&str> = config.columns.iter()
        .flat_map(|col| col.iter())
        .flat_map(|panel| panel.signal_specs.iter())
        .map(|sig| sig.y_expr.as_str())
        .collect();
    actual_y.sort();
    let mut expected_sorted = expected_y.to_vec();
    expected_sorted.sort();
    assert_eq!(actual_y, expected_sorted, "{}: signal expressions mismatch", source);
}

#[test]
fn test_parse_init_toml() {
    let path = Path::new(resource_dir()).join("init.toml");
    assert!(path.exists(), "init.toml not found at {:?}", path);

    let config = parse_toml_environment(path.to_str().unwrap());
    assert_init_config_valid(&config, "init.toml");
}

#[test]
fn test_parse_init_webscp() {
    let path = Path::new(resource_dir()).join("init.webscp");
    assert!(path.exists(), "init.webscp not found at {:?}", path);

    let config = parse_webscp_environment(path.to_str().unwrap());
    assert_init_config_valid(&config, "init.webscp");
}

#[test]
fn test_auto_detect_format() {
    // parse_environment should auto-detect TOML vs webscp by extension
    let toml_path = Path::new(resource_dir()).join("init.toml");
    let webscp_path = Path::new(resource_dir()).join("init.webscp");

    let config_toml = parse_environment(toml_path.to_str().unwrap());
    let config_webscp = parse_environment(webscp_path.to_str().unwrap());

    // Both should produce equivalent structures
    assert_eq!(config_toml.columns.len(), config_webscp.columns.len());
    for c in 0..config_toml.columns.len() {
        assert_eq!(config_toml.columns[c].len(), config_webscp.columns[c].len());
        for r in 0..config_toml.columns[c].len() {
            let p1 = &config_toml.columns[c][r];
            let p2 = &config_webscp.columns[c][r];
            assert_eq!(p1.signal_specs.len(), p2.signal_specs.len());
            for s in 0..p1.signal_specs.len() {
                assert_eq!(p1.signal_specs[s].y_expr, p2.signal_specs[s].y_expr);
                assert_eq!(p1.signal_specs[s].experiment, p2.signal_specs[s].experiment);
                assert_eq!(p1.signal_specs[s].server_ip, p2.signal_specs[s].server_ip);
            }
        }
    }
}

#[test]
fn test_toml_roundtrip_real() {
    let path = Path::new(resource_dir()).join("init.toml");
    let config = parse_toml_environment(path.to_str().unwrap());

    // Write to temp file
    let tmp = std::env::temp_dir().join("mdsscope_test_roundtrip_real.toml");
    write_environment_toml(&config, tmp.to_str().unwrap()).unwrap();

    // Read back
    let config2 = parse_toml_environment(tmp.to_str().unwrap());

    // Compare structure
    assert_eq!(config2.columns.len(), config.columns.len(),
        "roundtrip: column count changed");
    for c in 0..config.columns.len() {
        assert_eq!(config2.columns[c].len(), config.columns[c].len(),
            "roundtrip: column {} row count changed", c);
        for r in 0..config.columns[c].len() {
            let p1 = &config.columns[c][r];
            let p2 = &config2.columns[c][r];
            assert_eq!(p2.title, p1.title, "roundtrip: col{} row{} title", c, r);
            assert_eq!(p2.signal_specs.len(), p1.signal_specs.len(),
                "roundtrip: col{} row{} signal count", c, r);
            for s in 0..p1.signal_specs.len() {
                assert_eq!(p2.signal_specs[s].y_expr, p1.signal_specs[s].y_expr,
                    "roundtrip: col{} row{} sig{} y_expr", c, r, s);
                assert_eq!(p2.signal_specs[s].experiment, p1.signal_specs[s].experiment,
                    "roundtrip: col{} row{} sig{} tree", c, r, s);
                assert_eq!(p2.signal_specs[s].server_ip, p1.signal_specs[s].server_ip,
                    "roundtrip: col{} row{} sig{} server", c, r, s);
                assert_eq!(p2.extraction_points, p1.extraction_points,
                    "roundtrip: col{} row{} extraction_points", c, r);
            }
        }
    }

    std::fs::remove_file(&tmp).ok();
}

#[test]
fn test_webscp_specific_fields() {
    // Verify that webscp format preserves specific field mappings
    let path = Path::new(resource_dir()).join("init.webscp");
    let config = parse_webscp_environment(path.to_str().unwrap());

    // All panels should have grid=true and extraction_points=2000 from webscp
    for col in &config.columns {
        for panel in col {
            assert!(panel.grid, "webscp grid should be true");
            assert_eq!(panel.extraction_points, 2000);
        }
    }
}

#[test]
fn test_toml_preserves_grid_and_points() {
    // TOML format should preserve grid and extraction_points
    let original_content = r#"
version = 1

[[panels]]
column = 1
row = 1
title = "Test"
grid = false
extraction_points = 1000

[[panels.signals]]
tree = "test"
server = "127.0.0.1"
y = "\\test"
read_mode = "full"
"#;

    let tmp = std::env::temp_dir().join("mdsscope_grid_test.toml");
    std::fs::write(&tmp, original_content).unwrap();

    let config = parse_toml_environment(tmp.to_str().unwrap());
    let panel = &config.columns[0][0];

    assert!(!panel.grid, "grid should be false when set in TOML");
    assert_eq!(panel.extraction_points, 1000);
    assert!(matches!(
        panel.signal_specs[0].read_mode,
        Some(mds_core::types::DataReadMode::Full)
    ));

    std::fs::remove_file(&tmp).ok();
}

#[test]
fn test_toml_handles_trailing_newline() {
    let content = "version = 1\n\n[[panels]]\ncolumn = 1\nrow = 1\n\n[[panels.signals]]\ntree = \"pcs_east\"\nserver = \"202.127.204.12\"\ny = \"\\\\pcrl01\"\n\n";
    let tmp = std::env::temp_dir().join("mdsscope_trailing_test.toml");
    std::fs::write(&tmp, content).unwrap();

    let config = parse_toml_environment(tmp.to_str().unwrap());
    assert_eq!(config.columns.len(), 1);
    assert_eq!(config.columns[0][0].signal_specs[0].y_expr, "\\pcrl01");

    std::fs::remove_file(&tmp).ok();
}

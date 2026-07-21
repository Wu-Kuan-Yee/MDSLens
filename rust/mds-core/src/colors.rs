// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Color palette and axis formatting utilities.
//!
//! Ported from `src/core/visuals.cpp`.

use crate::types::SignalSpec;

/// 16-color preset palette, ported from `colorForIndex()`.
const PRESET_COLORS: [&str; 16] = [
    "#2364aa", // blue
    "#c44e52", // red
    "#2f855a", // green
    "#805ad5", // purple
    "#d97706", // amber
    "#0f766e", // teal
    "#9f1239", // crimson
    "#4a5568", // gray
    "#db2777", // pink
    "#16a34a", // green
    "#ea580c", // orange
    "#0891b2", // cyan
    "#7c3aed", // violet
    "#ca8a04", // yellow
    "#0ea5e9", // sky
    "#be123c", // dark red
];

/// Return the preset color for a 0-based series index (wraps modulo 16).
pub fn color_for_index(index: usize) -> String {
    PRESET_COLORS[index % PRESET_COLORS.len()].to_string()
}

/// Assign preset colors to signal specs unless they have manual colors set.
pub fn normalize_preset_colors(specs: &mut [SignalSpec]) {
    for (i, spec) in specs.iter_mut().enumerate() {
        if !spec.manual_color {
            spec.color_name = color_for_index(i);
        }
    }
}

/// Format a single axis value compactly.
/// Ported from `compactAxisValue()`.
pub fn compact_axis_value(value: f64) -> String {
    if !value.is_finite() {
        return String::new();
    }
    let abs_value = value.abs();
    if abs_value >= 1000.0 {
        format!("{:.1e}", value)
    } else if abs_value > 0.0 && abs_value < 0.001 {
        format!("{:.2}", value)
    } else if abs_value >= 100.0 {
        format!("{:.0}", value)
    } else if abs_value >= 10.0 {
        format!("{:.1}", value)
    } else {
        // General format with up to 3 significant digits (port of QString::number(v, 'g', 3))
        let s = format!("{:.3}", value);
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

/// Format a vector of axis values with uniform precision, avoiding duplicate labels.
/// Ported from `uniformAxisValues()`.
pub fn uniform_axis_values(values: &[f64]) -> Vec<String> {
    let n = values.len();
    if n == 0 {
        return Vec::new();
    }

    // Determine if scientific notation is needed
    let mut scientific = false;
    let mut min_step = f64::INFINITY;

    for (i, &value) in values.iter().enumerate() {
        if !value.is_finite() {
            continue;
        }
        let abs_value = value.abs();
        if abs_value >= 1000.0 || (abs_value > 0.0 && abs_value < 0.001) {
            scientific = true;
        }
        if i > 0 && values[i - 1].is_finite() {
            let step = (value - values[i - 1]).abs();
            if step > 0.0 {
                min_step = min_step.min(step);
            }
        }
    }

    let mut decimals = if scientific {
        2usize
    } else if min_step.is_finite() && min_step > 0.0 {
        if min_step >= 10.0 {
            0
        } else {
            ((-min_step.log10()).ceil() as usize + 1).clamp(0, 5)
        }
    } else {
        0
    };

    // Build labels, increasing precision until no duplicates
    loop {
        let labels: Vec<String> = values
            .iter()
            .map(|&v| {
                if v.is_finite() {
                    if scientific {
                        format!("{:.1$e}", v, decimals)
                    } else {
                        format!("{:.1$}", v, decimals)
                    }
                } else {
                    String::new()
                }
            })
            .collect();

        if scientific || decimals >= 6 {
            return labels;
        }

        // Check for duplicates
        let mut seen = std::collections::HashSet::new();
        let has_duplicate = labels.iter().any(|l| !l.is_empty() && !seen.insert(l));
        if !has_duplicate {
            return labels;
        }
        decimals += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_color_for_index_wraps() {
        assert_eq!(color_for_index(0), "#2364aa");
        assert_eq!(color_for_index(16), "#2364aa");
        assert_eq!(color_for_index(1), "#c44e52");
    }

    #[test]
    fn test_compact_axis_value() {
        assert_eq!(compact_axis_value(1500.0), "1.5e3");
        assert_eq!(compact_axis_value(150.0), "150");
        assert_eq!(compact_axis_value(15.0), "15.0");
        assert_eq!(compact_axis_value(1.5), "1.5");
        assert_eq!(compact_axis_value(0.0005), "0.00");
        assert_eq!(compact_axis_value(f64::NAN), "");
    }

    #[test]
    fn test_uniform_axis_values_no_duplicates() {
        let values = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let labels = uniform_axis_values(&values);
        assert_eq!(labels.len(), 5);
        let unique: std::collections::HashSet<_> = labels.iter().collect();
        assert_eq!(unique.len(), 5);
    }

    #[test]
    fn test_normalize_preset_colors() {
        let mut specs = vec![
            SignalSpec::default(),
            SignalSpec::default(),
            SignalSpec::default(),
        ];
        normalize_preset_colors(&mut specs);
        assert_eq!(specs[0].color_name, "#2364aa");
        assert_eq!(specs[1].color_name, "#c44e52");
        assert_eq!(specs[2].color_name, "#2f855a");
    }
}

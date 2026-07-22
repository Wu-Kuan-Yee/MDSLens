// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! SSH connection settings. Ported from `src/ssh/ssh_settings.hpp`.

use mds_core::types::SshMode;

/// SSH connection configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshSettings {
    pub mode: SshMode,
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub identity_file: String,
}

impl Default for SshSettings {
    fn default() -> Self {
        Self {
            mode: SshMode::Disabled,
            host: String::new(),
            port: 22,
            user: String::new(),
            password: String::new(),
            identity_file: String::new(),
        }
    }
}

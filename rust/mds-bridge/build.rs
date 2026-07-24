use std::path::{Path, PathBuf};
use std::process::Command;

const MDS_SCOPE_VERSION: &str = "7.0";

fn git_output(repo: &Path, arguments: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(arguments)
        .current_dir(repo)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    (!value.is_empty()).then_some(value)
}

fn main() {
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap_or_default());
    let repo = manifest.join("../..");
    let git_dir = repo.join(".git");
    println!("cargo:rerun-if-changed={}", git_dir.join("HEAD").display());
    println!("cargo:rerun-if-changed={}", git_dir.join("refs").display());
    println!("cargo:rerun-if-env-changed=MDSSCOPE_VERSION");

    let public_version =
        std::env::var("MDSSCOPE_VERSION").unwrap_or_else(|_| MDS_SCOPE_VERSION.into());
    let hash = git_output(&repo, &["rev-parse", "--short=9", "HEAD"]);
    let tag = git_output(&repo, &["describe", "--tags", "--abbrev=0"]);
    let revision = tag
        .as_deref()
        .and_then(|tag| git_output(&repo, &["rev-list", "--count", &format!("{tag}..HEAD")]))
        .or_else(|| git_output(&repo, &["rev-list", "--count", "HEAD"]));
    let dirty =
        git_output(&repo, &["status", "--porcelain"]).is_some_and(|status| !status.is_empty());

    let git_version = match (hash, revision) {
        (Some(hash), Some(revision)) => format!(
            "{public_version}.r{revision}.g{hash}{}",
            if dirty { ".dirty" } else { "" }
        ),
        _ => "unknown".into(),
    };
    println!("cargo:rustc-env=MDS_SCOPE_GIT_VERSION={git_version}");
}

use std::path::{Path, PathBuf};
use std::process::Command;

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

fn ci_commit_short_hash() -> Option<String> {
    let value = std::env::var("GITHUB_SHA").ok()?;
    let value = value.trim();
    if value.len() < 9 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    Some(value[..9].to_ascii_lowercase())
}

fn release_version_from_tag(tag: &str) -> Option<([u64; 3], String)> {
    let version = tag.strip_prefix('v').unwrap_or(tag);
    let parts: Vec<&str> = version.split('.').collect();
    if !(2..=3).contains(&parts.len()) {
        return None;
    }
    let major = parts[0].parse().ok()?;
    let minor = parts[1].parse().ok()?;
    let patch = parts.get(2).map_or(Some(0), |value| value.parse().ok())?;
    Some(([major, minor, patch], version.to_string()))
}

fn latest_release_tag(repo: &Path) -> Option<(String, String)> {
    let tags = git_output(repo, &["tag", "--merged", "HEAD"])?;
    tags.lines()
        .filter_map(|tag| {
            release_version_from_tag(tag)
                .map(|(version, display)| (version, tag.to_string(), display))
        })
        .max_by_key(|(version, _, _)| *version)
        .map(|(_, tag, display)| (tag, display))
}

fn pubspec_version(repo: &Path) -> Option<String> {
    let contents = std::fs::read_to_string(repo.join("pubspec.yaml")).ok()?;
    contents.lines().find_map(|line| {
        line.trim()
            .strip_prefix("version:")
            .map(str::trim)
            .and_then(|value| value.split('+').next())
            .map(str::to_string)
    })
}

fn main() {
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap_or_default());
    let repo = manifest.join("../..");
    let git_dir = repo.join(".git");
    println!("cargo:rerun-if-changed={}", git_dir.join("HEAD").display());
    println!("cargo:rerun-if-changed={}", git_dir.join("refs").display());
    println!(
        "cargo:rerun-if-changed={}",
        git_dir.join("logs/HEAD").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo.join("pubspec.yaml").display()
    );
    println!("cargo:rerun-if-env-changed=MDSLENS_VERSION");
    println!("cargo:rerun-if-env-changed=MDSLENS_GIT_VERSION");
    println!("cargo:rerun-if-env-changed=GITHUB_SHA");
    println!("cargo:rerun-if-env-changed=GITHUB_REF_TYPE");
    println!("cargo:rerun-if-env-changed=GITHUB_REF_NAME");

    let github_tagged_version = (std::env::var("GITHUB_REF_TYPE").as_deref() == Ok("tag"))
        .then(|| std::env::var("GITHUB_REF_NAME").ok())
        .flatten()
        .and_then(|tag| release_version_from_tag(&tag).map(|(_, version)| (tag, version)));
    let tagged_version = github_tagged_version
        .clone()
        .or_else(|| latest_release_tag(&repo));
    let public_version = std::env::var("MDSLENS_VERSION")
        .ok()
        .map(|value| value.trim_start_matches('v').to_string())
        .or_else(|| tagged_version.as_ref().map(|(_, version)| version.clone()))
        .or_else(|| pubspec_version(&repo))
        .unwrap_or_else(|| "unknown".into());
    // Linux release jobs run inside a container whose checkout is owned by the
    // host runner user. Git can therefore reject the checkout as unsafe even
    // though the source and Cargo metadata are readable. The CI commit SHA is
    // an equally authoritative fallback for the displayed revision.
    let hash = git_output(&repo, &["rev-parse", "--short=9", "HEAD"]).or_else(ci_commit_short_hash);
    let revision = if github_tagged_version.is_some() {
        Some("0".into())
    } else {
        tagged_version
            .as_ref()
            .and_then(|(tag, _)| {
                git_output(&repo, &["rev-list", "--count", &format!("{tag}..HEAD")])
            })
            .or_else(|| git_output(&repo, &["rev-list", "--count", "HEAD"]))
            .or_else(|| ci_commit_short_hash().map(|_| "0".into()))
    };
    let dirty =
        git_output(&repo, &["status", "--porcelain"]).is_some_and(|status| !status.is_empty());

    let git_version = std::env::var("MDSLENS_GIT_VERSION")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| match (hash, revision) {
            (Some(hash), Some(revision)) => format!(
                "{public_version}.r{revision}.g{hash}{}",
                if dirty { ".dirty" } else { "" }
            ),
            _ => "unknown".into(),
        });
    println!("cargo:rustc-env=MDS_SCOPE_VERSION={public_version}");
    println!("cargo:rustc-env=MDS_SCOPE_GIT_VERSION={git_version}");
}

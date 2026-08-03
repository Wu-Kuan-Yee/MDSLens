#!/usr/bin/env bash
set -euo pipefail

# The Rocky Linux container's default mirrorlist can briefly advertise stale
# metadata (especially for the ARM64 repository).  The portable-runtime check
# only needs a small, deterministic verifier environment, so use Rocky's
# official direct repositories instead of an arbitrary mirror selected by the
# mirror manager.  This script runs inside a disposable CI container.

repo_dir=/etc/yum.repos.d
repo_key=/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
direct_repo="$repo_dir/mdslens-direct.repo"

if [[ ! -d "$repo_dir" || ! -f "$repo_key" ]]; then
  echo "Rocky Linux repository layout is not available" >&2
  exit 1
fi

for repo in "$repo_dir"/*.repo; do
  [[ -e "$repo" ]] || continue
  [[ "$repo" == "$direct_repo" ]] && continue
  mv "$repo" "$repo.disabled"
done

printf '%s\n' \
  '[baseos]' \
  'name=Rocky Linux 10 - BaseOS (direct)' \
  'baseurl=https://dl.rockylinux.org/pub/rocky/10/BaseOS/$basearch/os/' \
  'enabled=1' \
  'gpgcheck=1' \
  "gpgkey=file://$repo_key" \
  '' \
  '[appstream]' \
  'name=Rocky Linux 10 - AppStream (direct)' \
  'baseurl=https://dl.rockylinux.org/pub/rocky/10/AppStream/$basearch/os/' \
  'enabled=1' \
  'gpgcheck=1' \
  "gpgkey=file://$repo_key" \
  > "$direct_repo"

packages=(
  binutils
  git
  gtk3
  libepoxy
  libsecret
  libstdc++
  python3
  unzip
)

for attempt in 1 2 3 4; do
  dnf clean all >/dev/null 2>&1 || true
  if dnf --setopt=timeout=60 --setopt=retries=5 install -y "${packages[@]}"; then
    exit 0
  fi
  if [[ "$attempt" -lt 4 ]]; then
    delay=$((attempt * 10))
    echo "Enterprise Linux runtime installation failed; retrying in ${delay}s (${attempt}/4)" >&2
    sleep "$delay"
  fi
done

echo "Could not install the Enterprise Linux portable-runtime verifier dependencies" >&2
exit 1

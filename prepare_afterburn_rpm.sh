#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

# Shared help and error reporting.
usage() {
    echo "Usage: $0 [--prepare-only] [AFTERBURN_CHECKOUT [GIT_REF]]"
}
die() { echo "afterburn: $*" >&2; exit 1; }

# Select the checkout/ref; default to committed HEAD in ~/afterburn.
prepare_only=false
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
if [[ ${1:-} == --prepare-only ]]; then prepare_only=true; shift; fi
[[ $# -le 2 ]] || { usage >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
checkout=$(realpath -- "${1:-$HOME/afterburn}")
ref=${2:-HEAD}

# Prefer the user's Rust toolchain and check required host tools.
export PATH="$HOME/.cargo/bin:$PATH"
for tool in git cargo jq tar sha256sum make go rpm createrepo_c; do
    command -v "$tool" >/dev/null || die "Missing required tool: $tool"
done

# Reuse the Azure Linux 3.0 toolkit, cloning it on the first run.
build="$root/__build__/rpms_build_dir"
toolkit="$build/azurelinux/toolkit"
mkdir -p "$build"
if [[ ! -d $toolkit ]]; then
    git clone --branch 3.0-stable https://github.com/microsoft/azurelinux.git "$build/azurelinux"
fi

# Export only committed files into an isolated, retained build directory.
revision=$(git -C "$checkout" rev-parse --verify --end-of-options "$ref^{commit}")
work=$(mktemp -d "$root/__build__/afterburn.XXXXXX")
echo "Building Afterburn $revision; inputs and output: $work"
mkdir -p "$work/source" "$work/specs/rust-afterburn"
git -C "$checkout" archive "$revision" | tar -x -C "$work/source"
cd "$work/source"
# Keep Git patch operations from discovering this scripts repository.
export GIT_CEILING_DIRECTORIES="$work"

# Restore legacy providers and Flatcar flags, or accept an already-patched ref.
compat="$root/acl/afterburn-compat.patch"
if git apply --check "$compat"; then
    git apply "$compat"
elif git apply --reverse --check "$compat"; then
    echo "ACL compatibility patch is already applied."
else
    die "Port $compat to Afterburn $revision before building."
fi

# Resolve patched dependencies and translate Cargo's version into RPM syntax.
metadata=$(cargo metadata --format-version 1 --features cl-legacy)
package=$(jq -ce '. as $m | .packages[] | select(.name == "afterburn" and (.id as $id | $m.workspace_members | index($id)))' <<< "$metadata")
version=$(jq -r '.version' <<< "$package")
version=${version/-/~}
version=${version/+/.}
rust_version=$(jq -r '.rust_version // "0"' <<< "$package")

# bytes >= 1.11.1 contains the toolkit's CVE-2026-25541 fix.
while read -r bytes_version; do
    if ! sort -V -C <<< $'1.11.1\n'"$bytes_version"; then
        cargo update -p "bytes@$bytes_version" --precise 1.11.1
    fi
done < <(jq -r '.packages[] | select(.name == "bytes") | .version' <<< "$metadata")

# Bundle locked dependencies and verify they resolve without network access.
mkdir -p .cargo
cargo vendor --locked --respect-source-config vendor > .cargo/acl-vendor.toml
cargo --config .cargo/acl-vendor.toml metadata --locked --offline --features cl-legacy --format-version 1 >/dev/null
cp .cargo/acl-vendor.toml .cargo/config.toml

# Create separate source/vendor archives and reuse the toolkit's service files.
specs="$work/specs/rust-afterburn"
template="$toolkit/../SPECS/rust-afterburn"
cp "$template/"*.service "$specs/"
mv "$work/source" "$work/afterburn-$version"
tar -czf "$specs/rust-afterburn-$version.tar.gz" --exclude="afterburn-$version/vendor" -C "$work" "afterburn-$version"
tar -czf "$specs/afterburn-$version-azlcustomvendor.tar.gz" -C "$work/afterburn-$version" vendor

# Adapt the toolkit spec for local source, locked builds, and stripped binaries.
# Remove its patches and tests; retain its installation and service handling.
sed -E \
    -e "s/^Version:.*/Version:        $version/" \
    -e "s/^Release:.*/Release:        1.acl.${revision:0:12}%{?dist}/" \
    -e 's|^Source0:.*|Source0:        %{name}-%{version}.tar.gz|' \
    -e '/^Patch[0-9]+:/d' \
    -e '/^%bcond_without check$/d' \
    -e '/^%if %\{with check\}/,/^%endif$/d' \
    -e '/^# setting up \.cargo\/config/,/^EOF$/d' \
    -e '/^BuildRequires:  cargo/a BuildRequires:  rust >= '"$rust_version" \
    -e '/^%build/a export CARGO_PROFILE_RELEASE_STRIP=true CARGO_PROFILE_RELEASE_DEBUG=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1' \
    -e 's/cargo build /cargo build --locked /' \
    "$template/rust-afterburn.spec" > "$specs/rust-afterburn.spec"
# Record source hashes in the toolkit's expected signatures format.
(
    cd "$specs"
    sha256sum -- *.tar.gz *.service |
        jq -Rn '[inputs | split("  ") | {key: .[1], value: .[0]}] | {Signatures: from_entries}' > rust-afterburn.signatures.json
)
# Preparation-only mode stops before privileged compilation and staging.
$prepare_only && { echo "Prepared RPM inputs: $specs"; exit 0; }

# Optionally pin build dependencies to the same snapshot as the ACL image.
snapshot=()
if [[ -n ${PACKAGE_SNAPSHOT_TIME:-} ]]; then
    [[ $PACKAGE_SNAPSHOT_TIME =~ ^[1-9][0-9]{9}$ ]] || die "PACKAGE_SNAPSHOT_TIME must be a ten-digit Unix UTC timestamp."
    snapshot=("REPO_SNAPSHOT_TIME=$PACKAGE_SNAPSHOT_TIME")
fi

# Build only Afterburn in the Azure Linux environment, without running tests.
sudo make -C "$toolkit" build-packages -j"$(nproc)" \
    SRPM_PACK_LIST=rust-afterburn SPECS_DIR="$work/specs" \
    QUICK_REBUILD_PACKAGES=y PRECACHE=n CONFIG_FILE= REBUILD_TOOLS=y \
    GOFLAGS=-buildvcs=false BUILD_DIR="$build" OUT_DIR="$work/out" \
    RUN_CHECK=n LOG_LEVEL=info "${snapshot[@]}"
sudo chown -R "$(id -u):$(id -g)" "$work"

# Require both runtime RPMs for this exact source revision and host architecture.
release="$version-1.acl.${revision:0:12}.azl3"
rpms=()
for name in afterburn afterburn-dracut; do
    rpm_file="$work/out/RPMS/$(uname -m)/$name-$release.$(uname -m).rpm"
    [[ -f $rpm_file ]] || die "Missing expected RPM: $rpm_file"
    rpms+=("$rpm_file")
done

# Reject binaries linked against glibc newer than Azure Linux 3.0 provides.
glibc=$(rpm -qp --requires "${rpms[0]}" | sed -nE 's/.*libc\.so\.6\(GLIBC_([0-9.]+)\).*/\1/p' | sort -V | tail -1)
[[ -n $glibc ]] || die "No glibc requirement found in the Afterburn RPM."
sort -V -C <<< "$glibc"$'\n2.38' || die "RPM needs glibc $glibc; Azure Linux 3.0 provides 2.38."

# Preserve previous Afterburn RPMs so staging contains no competing versions.
staging="$root/__build__/rpm-staging"
mkdir -p "$staging" "$work/previous-rpms"
shopt -s nullglob
for old in "$staging"/afterburn-*.rpm; do
    name=$(rpm -qp --queryformat '%{NAME}' "$old")
    if [[ $name == afterburn || $name == afterburn-dracut ]]; then
        mv -- "$old" "$work/previous-rpms/"
    fi
done

# Publish both RPMs and refresh the local repository used by the image build.
cp -- "${rpms[@]}" "$staging/"
createrepo_c --update "$staging"
printf 'Staged: %s\n' "${rpms[@]##*/}"
echo "Next: ./acl/build_rpm_image.sh --rebuild (do not use --clean)"

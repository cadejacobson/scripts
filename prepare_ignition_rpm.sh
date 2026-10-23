#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

# Select committed source; leave the checkout and its existing builds untouched.
usage() { echo "Usage: $0 [--prepare-only] [IGNITION_CHECKOUT [GIT_REF]]"; }
die() { echo "ignition: $*" >&2; exit 1; }
prepare_only=false
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
if [[ ${1:-} == --prepare-only ]]; then prepare_only=true; shift; fi
[[ $# -le 2 ]] || { usage >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
checkout=$(realpath -- "${1:-$HOME/ignition}")
ref=${2:-HEAD}
for tool in git go jq tar sha256sum make rpm createrepo_c; do
    command -v "$tool" >/dev/null || die "Missing required tool: $tool"
done

# Reuse the same Azure Linux 3.0 toolkit and toolchain cache as ACL.
build="$root/__build__/rpms_build_dir"
toolkit="$build/azurelinux/toolkit"
mkdir -p "$build"
if [[ ! -d $toolkit ]]; then
    git clone --branch 3.0-stable https://github.com/microsoft/azurelinux.git "$build/azurelinux"
fi
revision=$(git -C "$checkout" rev-parse --verify --end-of-options "$ref^{commit}")
work=$(mktemp -d "$root/__build__/ignition.XXXXXX")
echo "Building Ignition $revision; inputs and output: $work"
mkdir -p "$work/source" "$work/specs/ignition-flatcar"
git -C "$checkout" archive "$revision" | tar -x -C "$work/source"
cd "$work/source"

# Use the most recent released version in the source's release notes as the base.
version=$(sed -nE '/^## Ignition [0-9]/{s/^## Ignition ([0-9]+\.[0-9]+\.[0-9]+).*/\1/;p;q;}' docs/release-notes.md)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Cannot determine the release version from docs/release-notes.md."
go_version=$(awk '$1 == "go" {print $2; exit}' go.mod)
module=$(awk '$1 == "module" {print $2; exit}' go.mod)
[[ -n $go_version && -n $module ]] || die "Missing Go version or module path in go.mod."

# Keep the committed vendor tree; never download or rewrite dependencies.
[[ -f vendor/modules.txt ]] || die "The selected ref must contain vendored Go dependencies."
GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go list -mod=vendor ./internal >/dev/null
specs="$work/specs/ignition-flatcar"
mv "$work/source" "$work/ignition-$version"
source_name="ignition-flatcar-$version.tar.gz"
tar -czf "$specs/$source_name" -C "$work" "ignition-$version"

# Retain the toolkit's package name, dependencies, and binary installation paths.
# Use upstream code, not its legacy Flatcar patches, and remove all RPM tests.
template="$toolkit/../SPECS/ignition-flatcar/ignition-flatcar.spec"
sed -E \
    -e "s/^Version:.*/Version:        $version/" \
    -e "s/^Release:.*/Release:        1.acl.${revision:0:12}%{?dist}/" \
    -e 's|^Source0:.*|Source0:        %{name}-%{version}.tar.gz|' \
    -e '/^Patch[0-9]+:/d' \
    -e '/^%bcond_with check$/d' \
    -e '/^%if %\{with check\}/,/^%endif$/d' \
    -e "s/^BuildRequires: golang$/BuildRequires: golang >= $go_version/" \
    -e '/^%build/a export CGO_ENABLED=1 GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off' \
    -e 's/export GOFLAGS=.*/export GOFLAGS="-mod=vendor -buildvcs=false"/' \
    -e "s|github.com/flatcar/ignition/v2|$module|g" \
    -e 's|internal/version.Raw=%\{version\}|internal/version.Raw=%{version}-%{release}|' \
    "$template" > "$specs/ignition-flatcar.spec"
hash=$(sha256sum "$specs/$source_name" | cut -d ' ' -f 1)
jq -n --arg name "$source_name" --arg hash "$hash" \
    '{Signatures: {($name): $hash}}' > "$specs/ignition-flatcar.signatures.json"
$prepare_only && { echo "Prepared RPM inputs: $specs"; exit 0; }

# Optionally use the same repository snapshot as the ACL image.
snapshot=()
if [[ -n ${PACKAGE_SNAPSHOT_TIME:-} ]]; then
    [[ $PACKAGE_SNAPSHOT_TIME =~ ^[1-9][0-9]{9}$ ]] || die "PACKAGE_SNAPSHOT_TIME must be a ten-digit Unix UTC timestamp."
    snapshot=("REPO_SNAPSHOT_TIME=$PACKAGE_SNAPSHOT_TIME")
fi

# Compile only Ignition inside Azure Linux; the host's libc is not used.
sudo make -C "$toolkit" build-packages -j"$(nproc)" \
    SRPM_PACK_LIST=ignition-flatcar SPECS_DIR="$work/specs" \
    QUICK_REBUILD_PACKAGES=y PRECACHE=n CONFIG_FILE= REBUILD_TOOLS=y \
    GOFLAGS=-buildvcs=false BUILD_DIR="$build" OUT_DIR="$work/out" \
    RUN_CHECK=n LOG_LEVEL=info "${snapshot[@]}"
sudo chown -R "$(id -u):$(id -g)" "$work"
rpm_file="$work/out/RPMS/$(uname -m)/ignition-flatcar-$version-1.acl.${revision:0:12}.azl3.$(uname -m).rpm"
[[ -f $rpm_file ]] || die "Missing expected RPM: $rpm_file"

# Reject binaries requiring a newer glibc than Azure Linux 3.0 provides.
glibc=$(rpm -qp --requires "$rpm_file" | sed -nE 's/.*libc\.so\.6\(GLIBC_([0-9.]+)\).*/\1/p' | sort -V | tail -1)
[[ -n $glibc ]] || die "No glibc requirement found in the Ignition RPM."
sort -V -C <<< "$glibc"$'\n2.38' || die "RPM needs glibc $glibc; Azure Linux 3.0 provides 2.38."

# Preserve previous main-package RPMs, then refresh ACL's local staging repo.
staging="$root/__build__/rpm-staging"
mkdir -p "$staging" "$work/previous-rpms"
shopt -s nullglob
for old in "$staging"/ignition-flatcar-*.rpm; do
    if [[ $(rpm -qp --queryformat '%{NAME}' "$old") == ignition-flatcar ]]; then
        mv -- "$old" "$work/previous-rpms/"
    fi
done
cp -- "$rpm_file" "$staging/"
createrepo_c --update "$staging"
echo "Staged: ${rpm_file##*/}"
echo "Next: ./acl/build_rpm_image.sh --rebuild (do not use --clean)"

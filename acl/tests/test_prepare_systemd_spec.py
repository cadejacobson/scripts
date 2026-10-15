#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ACL_DIR = Path(__file__).resolve().parents[1]
PREPARE = ACL_DIR / "SPECS/systemd/prepare.py"
PATCHES = (
    "163a0e6097b68f2699931a87c49b1c6a8903606e.patch",
    "1b7aa998ae358d4af66d490d35ca448378650f60.patch",
)
UPSTREAM_SPEC = """\
Name:           systemd
%if %{without inplace}
Version:        255
%else
Version:        %(tools/meson-vcs-tag.sh . error)
%endif
Release:        34%{?dist}
Source0:        systemd-%{version}.tar.gz
Source1:        split-files.py
Patch0492:      existing.patch
# Patches for Azure Linux
Patch0900:      azurelinux.patch

%description
System and service manager.

%package boot
Summary:        UEFI boot manager

%description boot
Boot manager.

%prep
%autosetup -n systemd-%{version} -p1

%build
echo build
"""


class PrepareSystemdSpecTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.upstream = self.root / "upstream"
        self.output = self.root / "prepared"
        self.upstream.mkdir()
        self.spec = self.upstream / "systemd.spec"
        self.spec.write_text(UPSTREAM_SPEC)
        (self.upstream / "split-files.py").write_text("# upstream helper\n")
        self.signatures = '{"Signatures": {"systemd-255.tar.gz": "unchanged"}}\n'
        (self.upstream / "systemd.signatures.json").write_text(self.signatures)

    def prepare(self, output=None):
        return subprocess.run(
            [sys.executable, str(PREPARE), str(self.upstream),
             str(output or self.output)],
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_rejected(self, expected):
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)
        self.assertFalse(self.output.exists())

    def test_copies_upstream_packaging_and_registers_ordered_backports(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        spec = (self.output / "systemd.spec").read_text()
        self.assertIn("Release:        34%{?dist}.acl1\n", spec)
        self.assertIn("Patch0492:      existing.patch\n", spec)
        self.assertIn("Patch0900:      azurelinux.patch\n", spec)
        self.assertIn("%autosetup -n systemd-%{version} -p1\n", spec)
        self.assertIn("%description boot\nBoot manager.\n", spec)
        self.assertIn("Remove", spec)
        self.assertIn("systemd 256", spec)
        self.assertIn(
            "https://github.com/systemd/systemd/commit/"
            "1b7aa998ae358d4af66d490d35ca448378650f60", spec,
        )
        for number, name in zip((493, 494), PATCHES):
            self.assertEqual(spec.count(f"Patch{number:04d}:      {name}\n"), 1)
            self.assertEqual(
                (self.output / name).read_bytes(),
                (PREPARE.parent / name).read_bytes(),
            )
        self.assertLess(spec.index(PATCHES[0]), spec.index(PATCHES[1]))
        self.assertLess(spec.index("Patch0494:"), spec.index("%description"))
        self.assertEqual(self.spec.read_text(), UPSTREAM_SPEC)
        self.assertEqual(
            (self.output / "split-files.py").read_text(), "# upstream helper\n",
        )
        self.assertEqual(
            json.loads((self.output / "systemd.signatures.json").read_text()),
            json.loads(self.signatures),
        )

    def test_repeated_preparation_uses_fresh_upstream_spec(self):
        for _ in range(2):
            result = self.prepare()
            self.assertEqual(result.returncode, 0, result.stderr)
        spec = (self.output / "systemd.spec").read_text()
        self.assertEqual(spec.count(".acl1"), 1)
        self.assertEqual(spec.count("Patch0493:"), 1)

    def test_new_azure_linux_release_keeps_its_fixes(self):
        self.spec.write_text(UPSTREAM_SPEC.replace("34%{?dist}", "35%{?dist}"))
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "Release:        35%{?dist}.acl1\n",
            (self.output / "systemd.spec").read_text(),
        )

    def test_rejects_other_systemd_versions(self):
        for version in ("254", "255.1", "256", "260"):
            with self.subTest(version=version):
                self.spec.write_text(
                    UPSTREAM_SPEC.replace("Version:        255\n",
                                          f"Version:        {version}\n"),
                )
                self.assert_rejected("systemd 256")

    def test_rejects_conflicting_patch_numbers(self):
        for number in ("0493", "493", "0494"):
            with self.subTest(number=number):
                self.spec.write_text(UPSTREAM_SPEC.replace(
                    "# Patches for Azure Linux",
                    f"Patch{number}: existing-backport.patch\n"
                    "# Patches for Azure Linux",
                ))
                self.assert_rejected("patch number")

    def test_rejects_changed_release_format(self):
        self.spec.write_text(UPSTREAM_SPEC.replace("34%{?dist}", "%autorelease"))
        self.assert_rejected("Release")

    def test_rejects_changed_patch_application(self):
        for setup in ("%setup -q", "%autosetup -p1 -N", "%autosetup -p0"):
            with self.subTest(setup=setup):
                self.spec.write_text(UPSTREAM_SPEC.replace(
                    "%autosetup -n systemd-%{version} -p1", setup,
                ))
                self.assert_rejected("%autosetup")

    def test_rejects_missing_patch_insertion_point(self):
        self.spec.write_text(
            UPSTREAM_SPEC.replace("# Patches for Azure Linux\n", ""),
        )
        self.assert_rejected("Patches for Azure Linux")

    def test_missing_upstream_spec_reports_error(self):
        self.spec.unlink()
        self.assert_rejected("systemd.spec")

    def test_refuses_to_modify_upstream_in_place(self):
        result = self.prepare(output=self.upstream)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different", result.stderr)
        self.assertEqual(self.spec.read_text(), UPSTREAM_SPEC)

    def test_package_is_selected_for_standard_rpm_builds(self):
        self.assertRegex(
            (ACL_DIR / "packages.yaml").read_text(),
            r"(?m)^  - systemd\s+#",
        )

    def run_build(self, packages, fail_build=False):
        checkout = self.root / "checkout"
        acl = checkout / "acl"
        acl.mkdir(parents=True)
        shutil.copy2(ACL_DIR / "build.sh", acl / "build.sh")
        shutil.copytree(PREPARE.parent, acl / "SPECS/systemd")
        other_spec = acl / "SPECS/coreos-init/coreos-init.spec"
        other_spec.parent.mkdir()
        other_spec.write_text("Name: coreos-init\n")
        build_dir = checkout / "__build__/rpms_build_dir"
        azurelinux = build_dir / "azurelinux"
        (azurelinux / "toolkit").mkdir(parents=True)
        shutil.copytree(self.upstream, azurelinux / "SPECS/systemd")

        tools = self.root / "bin"
        tools.mkdir()
        sudo = tools / "sudo"
        sudo.write_text("""\
#!/bin/bash
set -euo pipefail
if [[ "$1" == make && "$2" == build-packages ]]; then
    for arg in "$@"; do
        case "$arg" in
            SPECS_DIR=*) cp -a "${arg#*=}/." "${CAPTURE_DIR}/" ;;
            SRPM_PACK_LIST=*) printf '%s\\n' "${arg#*=}" > "${CAPTURE_DIR}/packages" ;;
        esac
    done
    exit "${BUILD_STATUS}"
elif [[ "$1" == make && "$2" == compress-srpms ]]; then
    exit 0
elif [[ "$1" == chown ]]; then
    exit 0
fi
printf 'Unexpected sudo invocation: %s\\n' "$*" >&2
exit 1
""")
        sudo.chmod(0o755)
        nproc = tools / "nproc"
        nproc.write_text("#!/bin/sh\nprintf '1\\n'\n")
        nproc.chmod(0o755)
        captured = self.root / "captured"
        captured.mkdir()
        env = {
            **os.environ,
            "PATH": f"{tools}:{os.environ['PATH']}",
            "CAPTURE_DIR": str(captured),
            "BUILD_STATUS": "1" if fail_build else "0",
            "REUSE_SOURCES": "true",
        }
        result = subprocess.run(
            ["bash", str(acl / "build.sh"), *packages],
            cwd=checkout, env=env, capture_output=True, text=True, check=False,
        )
        self.assertEqual(list(build_dir.glob("acl-specs.*")), [])
        self.assertEqual(
            (azurelinux / "SPECS/systemd/systemd.spec").read_text(),
            self.spec.read_text(),
        )
        self.assertFalse((acl / "SPECS/systemd/systemd.spec").exists())
        return result, captured

    def test_build_entrypoint_passes_derived_specs_to_toolkit(self):
        result, captured = self.run_build(["coreos-init", "systemd"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            ".acl1", (captured / "systemd/systemd.spec").read_text(),
        )
        self.assertEqual(
            (captured / "coreos-init/coreos-init.spec").read_text(),
            "Name: coreos-init\n",
        )
        self.assertEqual((captured / "packages").read_text(), "coreos-init systemd\n")

    def test_other_package_builds_do_not_prepare_systemd(self):
        self.spec.write_text(UPSTREAM_SPEC.replace("255", "260"))
        result, captured = self.run_build(["coreos-init"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((captured / "systemd/systemd.spec").exists())

    def test_failed_package_build_is_reported_and_cleans_generated_specs(self):
        result, captured = self.run_build(["systemd"], fail_build=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Patch0494:", (captured / "systemd/systemd.spec").read_text())


if __name__ == "__main__":
    unittest.main()

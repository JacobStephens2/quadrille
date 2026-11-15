"""Exercise web deployment with isolated SDK executables and build artifacts."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class DeployWebTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "checkout with spaces"
        (self.root / "tool").mkdir(parents=True)
        shutil.copy2(ROOT / "tool/deploy_web.sh", self.root / "tool/deploy_web.sh")
        (self.root / "web").mkdir()
        for asset in ("sqlite3.wasm", "drift_worker.js"):
            (self.root / "web" / asset).touch()
        self.generated = self.root / "lib/core/database/database.g.dart"
        self.generated.parent.mkdir(parents=True)
        self.artifact = self.root / "build/web/main.dart.js"
        bindir = self.root / "bin"
        bindir.mkdir()
        self.env = {"PATH": f"{bindir}:{os.environ['PATH']}"}
        executables = {
            "dart": """#!/bin/sh
set -eu
test "$*" = 'run build_runner build --delete-conflicting-outputs'
if [ "${FAIL_CODEGEN:-0}" = 1 ]; then
  echo 'Code generation failed' >&2
  exit 23
fi
printf '%s\\n' 'EquipmentBusyReport; SetEntry.partials' > lib/core/database/database.g.dart
""",
            "flutter": """#!/bin/sh
set -eu
test "$*" = 'build web --release'
if ! grep -Fxq 'EquipmentBusyReport; SetEntry.partials' lib/core/database/database.g.dart; then
  echo 'Missing generated database members; Failed to compile application for the Web' >&2
  exit 1
fi
mkdir -p build/web
printf '%s\\n' 'release from current schema' > build/web/main.dart.js
""",
        }
        for name, contents in executables.items():
            executable = bindir / name
            executable.write_text(contents)
            executable.chmod(0o755)

    def deploy(self):
        # Invoke from outside the checkout, as callers may do in automation.
        return subprocess.run(
            ["bash", str(self.root / "tool/deploy_web.sh")],
            cwd=self.root.parent,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_deploy_rebuilds_stale_generated_database_code(self):
        self.generated.write_text("old schema without equipment busy reports or partials\n")
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.artifact.read_text(), "release from current schema\n")

    def test_deploy_generates_database_code_on_a_clean_checkout(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.artifact.read_text(), "release from current schema\n")

    def test_failed_generation_leaves_the_previous_release_unchanged(self):
        # Even buildable cached code must not hide a failed generation step.
        self.generated.write_text("EquipmentBusyReport; SetEntry.partials\n")
        self.artifact.parent.mkdir(parents=True)
        self.artifact.write_text("previous release\n")
        self.env["FAIL_CODEGEN"] = "1"
        result = self.deploy()
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertIn("Code generation failed", result.stderr)
        self.assertEqual(self.artifact.read_text(), "previous release\n")


if __name__ == "__main__":
    unittest.main()

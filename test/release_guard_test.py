"""Guards for the Android release workflow.

A release tag is accepted only when its version is numbers separated by dots.
A manual dry-run keeps the commit SHA artifact name. The signer check fails
unless the APK certificate SHA-256 equals the fingerprint it was given, and
that fingerprint is not read from the job keystore.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
ACCEPT = ROOT / "tool" / "accept_release_version.sh"
VERIFY = ROOT / "tool" / "verify_upload_signer.sh"

SHA = "083c31c51b05c7238d9a03cd9a6264acb68d27c1"
DRY_RUN_VERSION = "dev-083c31c"
# git check-ref-format accepts this tag. The old verify step executed it.
INJECTION_TAG = "v0$(printf${IFS}marker)"
MATCHING_DIGEST = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"


def run_bash(script, env, cwd):
    merged = {"PATH": os.environ["PATH"]}
    merged.update(env)
    return subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
        cwd=cwd,
        env=merged,
        capture_output=True,
        text=True,
    )


def _block(lines, index, content_indent):
    """Read a YAML block scalar. Blank lines stay inside the block."""
    block = []
    consumed = []
    prefix = " " * content_indent
    while index < len(lines):
        line = lines[index]
        if line.startswith(prefix):
            block.append(line[content_indent:])
            consumed.append(line)
            index += 1
        elif line.strip() == "":
            block.append("")
            consumed.append(line)
            index += 1
        else:
            break
    return "\n".join(block).strip("\n"), consumed, index


def steps():
    """Return the release job's steps.

    Indentation matches release.yml: a step starts at 6 spaces, its keys at 8.
    """
    lines = WORKFLOW.read_text().splitlines()
    try:
        index = lines.index("    steps:") + 1
    except ValueError as error:
        raise AssertionError("release workflow has no steps list") from error

    parsed = []
    current = None

    def finish():
        if current is not None:
            parsed.append(current)

    while index < len(lines):
        line = lines[index]
        if line.startswith("      - "):
            finish()
            current = {
                "name": None,
                "run": "",
                "env": {},
                "if": None,
                "with": {},
                "continue-on-error": False,
                "raw": [line],
            }
            rest = line[8:]
            if rest.startswith("name:"):
                current["name"] = rest.split(":", 1)[1].strip()
            index += 1
            continue
        if current is None or (line and not line.startswith("      ")):
            break
        current["raw"].append(line)
        if not (line.startswith("        ") and not line.startswith("         ")):
            index += 1
            continue
        key, _, value = line.strip().partition(":")
        value = value.strip()
        if key == "name":
            current["name"] = value
        elif key == "if":
            current["if"] = value
        elif key == "continue-on-error":
            current["continue-on-error"] = value == "true"
        elif key == "run" and value == "|":
            current["run"], consumed, index = _block(lines, index + 1, 10)
            current["raw"].extend(consumed)
            continue
        elif key == "run":
            current["run"] = value
        elif key == "env":
            index += 1
            while index < len(lines) and lines[index].startswith("          "):
                current["raw"].append(lines[index])
                env_key, _, env_value = lines[index].strip().partition(":")
                current["env"][env_key] = env_value.strip()
                index += 1
            continue
        elif key == "with":
            index += 1
            while index < len(lines) and lines[index].startswith("          "):
                current["raw"].append(lines[index])
                with_key, _, with_value = lines[index].strip().partition(":")
                with_value = with_value.strip()
                if with_value == "|":
                    block, consumed, index = _block(lines, index + 1, 12)
                    current["raw"].extend(consumed)
                    current["with"][with_key] = block
                    continue
                current["with"][with_key] = with_value
                index += 1
            continue
        index += 1
    finish()
    return parsed


def step_named(name):
    found = [step for step in steps() if step.get("name") == name]
    if len(found) != 1:
        raise AssertionError(f"expected one step named {name!r}, found {len(found)}")
    return found[0]


def step_running(fragment):
    found = [step for step in steps() if fragment in str(step.get("run", ""))]
    if len(found) != 1:
        raise AssertionError(
            f"expected one step running {fragment!r}, found {len(found)}"
        )
    return found[0]


class AcceptReleaseVersionTest(unittest.TestCase):
    def accept(self, ref_type, ref_name, sha=SHA):
        return subprocess.run(
            ["bash", str(ACCEPT)],
            cwd=ROOT,
            env={
                "GITHUB_REF_TYPE": ref_type,
                "GITHUB_REF_NAME": ref_name,
                "GITHUB_SHA": sha,
                "PATH": os.environ["PATH"],
            },
            capture_output=True,
            text=True,
        )

    def test_dotted_tag_is_the_release_version(self):
        result = self.accept("tag", "v1.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1.2.0\n")

    def test_existing_release_tags_stay_acceptable(self):
        for tag in ("v1.1.0", "v1.1.1"):
            with self.subTest(tag=tag):
                result = self.accept("tag", tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"{tag[1:]}\n")

    def test_tag_without_a_leading_v_can_still_be_dotted_numbers(self):
        result = self.accept("tag", "1.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1.2.0\n")

    def test_two_numeric_components_are_numbers_separated_by_dots(self):
        result = self.accept("tag", "v1.2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1.2\n")

    def test_more_than_three_numeric_components_are_dotted_numbers(self):
        result = self.accept("tag", "v10.20.30.40")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "10.20.30.40\n")

    def test_tag_that_is_not_numbers_separated_by_dots_is_rejected(self):
        for tag in (
            "v1",
            "v1.2.0-rc1",
            "v1.2.0+4",
            "v1.2.",
            "v.1.2",
            "vv1.2.0",
            INJECTION_TAG,
        ):
            with self.subTest(tag=tag):
                result = self.accept("tag", tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("numbers separated by dots", result.stderr)
                self.assertNotIn(tag, result.stdout)
                self.assertNotIn("version=", result.stdout)

    def test_injection_tag_does_not_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            sentinel = Path(tmp) / "marker"
            tag = f"v0$(touch {sentinel})"
            result = self.accept("tag", tag)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("numbers separated by dots", result.stderr)
            self.assertFalse(sentinel.exists())
            self.assertNotIn("marker", result.stdout)

    def test_manual_dry_run_names_the_artifact_from_the_commit_sha(self):
        result = self.accept("branch", "master")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{DRY_RUN_VERSION}\n")

    def test_dry_run_ignores_a_branch_name_that_looks_like_a_tag(self):
        result = self.accept("branch", INJECTION_TAG)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{DRY_RUN_VERSION}\n")


class VerifyUploadSignerTest(unittest.TestCase):
    def verify(self, apk_path, fingerprint, android_home, extra_env=None, cwd=None):
        env = {
            "APK_PATH": str(apk_path),
            "ANDROID_HOME": str(android_home),
            "PATH": os.environ["PATH"],
        }
        if fingerprint is not None:
            env["UPLOAD_CERT_SHA256"] = fingerprint
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(VERIFY)],
            cwd=cwd or ROOT,
            env=env,
            capture_output=True,
            text=True,
        )

    def write_apksigner(self, android_home, version, lines, exit_code=0, log_name=None):
        tool = android_home / "build-tools" / version / "apksigner"
        tool.parent.mkdir(parents=True, exist_ok=True)
        body = "#!/bin/sh\n"
        if log_name:
            body += f"printf '%s\\n' \"$3\" >> {log_name}\n"
        for line in lines:
            body += "printf '%s\\n' '" + line.replace("'", "'\\''") + "'\n"
        body += f"exit {exit_code}\n"
        tool.write_text(body)
        tool.chmod(0o755)
        return tool

    def test_matching_fingerprint_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "quadrille-1.2.0.apk"
            apk.write_bytes(b"not a real apk\n")
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [
                    "Signer #1 certificate DN: CN=Quadrille Upload",
                    f"Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}",
                ],
            )
            result = self.verify(apk, MATCHING_DIGEST, root / "sdk")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_colon_form_fingerprint_equals_plain_hex(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "quadrille-1.2.0.apk"
            apk.write_bytes(b"not a real apk\n")
            digest = "ab" * 32
            colon = ":".join(digest[i : i + 2] for i in range(0, len(digest), 2)).upper()
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [f"Signer #1 certificate SHA-256 digest: {digest}"],
            )
            result = self.verify(apk, colon, root / "sdk")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "quadrille-1.2.0.apk"
            apk.write_bytes(b"not a real apk\n")
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [f"Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}"],
            )
            result = self.verify(apk, "bb" * 32, root / "sdk")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("bb" * 32, result.stdout)
            self.assertNotIn("bb" * 32, result.stderr)

    def test_missing_fingerprint_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "quadrille-1.2.0.apk"
            apk.write_bytes(b"not a real apk\n")
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [f"Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}"],
            )
            for fingerprint in (None, "", "   ", ":::"):
                with self.subTest(fingerprint=fingerprint):
                    result = self.verify(apk, fingerprint, root / "sdk")
                    self.assertNotEqual(result.returncode, 0)

    def test_second_signer_must_match_too(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "quadrille-1.2.0.apk"
            apk.write_bytes(b"not a real apk\n")
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [
                    f"Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}",
                    "Signer #2 certificate SHA-256 digest: " + ("cc" * 32),
                ],
            )
            result = self.verify(apk, MATCHING_DIGEST, root / "sdk")
            self.assertNotEqual(result.returncode, 0)

    def test_no_digest_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "quadrille-1.2.0.apk"
            apk.write_bytes(b"not a real apk\n")
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                ["Signer #1 certificate DN: CN=Quadrille Upload"],
            )
            result = self.verify(apk, MATCHING_DIGEST, root / "sdk")
            self.assertNotEqual(result.returncode, 0)

    def test_failed_apksigner_fails_the_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "quadrille-1.2.0.apk"
            apk.write_bytes(b"not a real apk\n")
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [f"Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}"],
                exit_code=1,
            )
            result = self.verify(apk, MATCHING_DIGEST, root / "sdk")
            self.assertNotEqual(result.returncode, 0)

    def test_newest_build_tools_apksigner_is_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "quadrille-1.2.0.apk"
            apk.write_bytes(b"not a real apk\n")
            log = root / "args"
            self.write_apksigner(
                root / "sdk",
                "30.0.0",
                ["Signer #1 certificate SHA-256 digest: " + ("dd" * 32)],
                log_name=str(log),
            )
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [f"Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}"],
                log_name=str(log),
            )
            result = self.verify(apk, MATCHING_DIGEST, root / "sdk")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(apk), log.read_text())

    def test_apk_path_is_not_parsed_as_shell(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sentinel = root / "marker"
            apk = root / "quadrille-0$(touch marker).apk"
            apk.write_bytes(b"not a real apk\n")
            log = root / "args"
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [f"Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}"],
                log_name=str(log),
            )
            result = self.verify(apk, MATCHING_DIGEST, root / "sdk", cwd=root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(sentinel.exists())
            self.assertIn(str(apk), log.read_text())

    def test_expected_fingerprint_is_not_taken_from_a_keystore(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "dist" / "quadrille-1.2.0.apk"
            apk.parent.mkdir()
            apk.write_bytes(b"not a real apk\n")
            keystore = root / "android" / "app" / "upload-keystore.jks"
            keystore.parent.mkdir(parents=True)
            keystore.write_bytes(b"dummy-keystore")
            (root / "android" / "key.properties").write_text(
                "storePassword=dummy\nkeyPassword=dummy\nkeyAlias=upload\n"
                "storeFile=upload-keystore.jks\n"
            )
            called = root / "keytool-called"
            bindir = root / "bin"
            bindir.mkdir()
            keytool = bindir / "keytool"
            keytool.write_text(
                "#!/bin/sh\n"
                f"touch {called}\n"
                f"printf '%s\\n' 'SHA256: {MATCHING_DIGEST}'\n"
            )
            keytool.chmod(0o755)
            self.write_apksigner(
                root / "sdk",
                "35.0.0",
                [f"Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}"],
            )
            result = self.verify(
                apk,
                "bb" * 32,
                root / "sdk",
                extra_env={
                    "PATH": f"{bindir}:{os.environ['PATH']}",
                    "ANDROID_KEYSTORE_BASE64": "ZHVtbXk=",
                    "ANDROID_KEYSTORE_PASSWORD": "dummy",
                    "ANDROID_KEY_ALIAS": "upload",
                },
                cwd=root,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(called.exists())
            self.assertEqual(keystore.read_bytes(), b"dummy-keystore")


class ReleaseWorkflowTest(unittest.TestCase):
    def test_rejected_tag_fails_before_the_keystore_step(self):
        job_steps = steps()
        names = [step.get("name") for step in job_steps]
        accept = step_running("accept_release_version.sh")
        accept_at = job_steps.index(accept)
        keystore_at = names.index("Decode release keystore")
        self.assertLess(accept_at, keystore_at)
        self.assertFalse(accept.get("continue-on-error", False))
        keystore = job_steps[keystore_at]
        self.assertNotEqual(keystore.get("if"), "always()")
        self.assertNotIn("always()", str(keystore.get("if", "")))
        for step in job_steps[:keystore_at]:
            blob = "\n".join(step["raw"])
            self.assertNotIn("ANDROID_KEYSTORE", blob)
            self.assertNotIn("secrets.", blob)

        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            env = {
                "GITHUB_REF_TYPE": "tag",
                "GITHUB_REF_NAME": INJECTION_TAG,
                "GITHUB_SHA": SHA,
                "GITHUB_OUTPUT": str(output),
                "PATH": os.environ["PATH"],
            }
            result = run_bash(accept["run"], env, ROOT)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((ROOT / "android" / "app" / "upload-keystore.jks").exists())

    def test_accepted_version_is_published_and_staged(self):
        accept = step_running("accept_release_version.sh")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            env = {
                "GITHUB_REF_TYPE": "tag",
                "GITHUB_REF_NAME": "v1.2.0",
                "GITHUB_SHA": SHA,
                "GITHUB_OUTPUT": str(output),
                "PATH": os.environ["PATH"],
            }
            result = run_bash(accept["run"], env, ROOT)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), "version=1.2.0\n")

        stage = step_named("Stage artifact + checksum")
        self.assertEqual(stage["env"]["VERSION"], "${{ steps.version.outputs.version }}")
        self.assertNotIn("${{", stage["run"])
        self.assertNotIn("GITHUB_REF_NAME", stage["run"])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk_src = root / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
            apk_src.parent.mkdir(parents=True)
            apk_src.write_bytes(b"apk-bytes")
            output = root / "output"
            sentinel = root / "marker"
            env = {
                "VERSION": "1.2.0",
                "GITHUB_REF_NAME": f"v0$(touch {sentinel})",
                "GITHUB_REF_TYPE": "tag",
                "GITHUB_SHA": SHA,
                "GITHUB_OUTPUT": str(output),
                "PATH": os.environ["PATH"],
            }
            result = run_bash(stage["run"], env, root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(sentinel.exists())
            self.assertEqual((root / "dist" / "quadrille-1.2.0.apk").read_bytes(), b"apk-bytes")
            text = output.read_text()
            self.assertIn("apk=dist/quadrille-1.2.0.apk\n", text)
            self.assertIn("sha=dist/quadrille-1.2.0.apk.sha256\n", text)
            self.assertIn("version=1.2.0\n", text)

        publish = step_named("Publish GitHub Release")
        self.assertEqual(publish["if"], "github.ref_type == 'tag'")
        files = publish["with"]["files"]
        body = publish["with"]["body"]
        self.assertIn("dist/quadrille-${{ steps.version.outputs.version }}.apk", files)
        self.assertIn(
            "dist/quadrille-${{ steps.version.outputs.version }}.apk.sha256",
            files,
        )
        self.assertIn("${{ steps.version.outputs.version }}", body)
        self.assertNotIn("steps.stage.outputs.version", body)
        self.assertNotIn("steps.stage.outputs.apk", files)

    def test_dry_run_stage_uses_the_commit_sha_name(self):
        accept = step_running("accept_release_version.sh")
        stage = step_named("Stage artifact + checksum")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            result = run_bash(
                accept["run"],
                {
                    "GITHUB_REF_TYPE": "branch",
                    "GITHUB_REF_NAME": "master",
                    "GITHUB_SHA": SHA,
                    "GITHUB_OUTPUT": str(output),
                    "PATH": os.environ["PATH"],
                },
                ROOT,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), f"version={DRY_RUN_VERSION}\n")

            root = Path(tmp) / "work"
            apk_src = root / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
            apk_src.parent.mkdir(parents=True)
            apk_src.write_bytes(b"apk-bytes")
            stage_output = root / "output"
            result = run_bash(
                stage["run"],
                {
                    "VERSION": DRY_RUN_VERSION,
                    "GITHUB_OUTPUT": str(stage_output),
                    "PATH": os.environ["PATH"],
                },
                root,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            staged = root / "dist" / f"quadrille-{DRY_RUN_VERSION}.apk"
            self.assertEqual(staged.read_bytes(), b"apk-bytes")

    def test_signing_check_receives_the_apk_path_and_secret_as_environment(self):
        verify = step_running("verify_upload_signer.sh")
        self.assertEqual(verify["env"]["APK_PATH"], "${{ steps.stage.outputs.apk }}")
        self.assertEqual(
            verify["env"]["UPLOAD_CERT_SHA256"],
            "${{ secrets.ANDROID_UPLOAD_CERT_SHA256 }}",
        )
        self.assertNotIn("${{", verify["run"])
        self.assertNotIn("keytool", verify["run"])
        self.assertNotIn("upload-keystore", verify["run"])
        self.assertNotIn("key.properties", verify["run"])
        workflow_text = WORKFLOW.read_text()
        self.assertNotIn("keytool", workflow_text)
        self.assertIn("\n  workflow_dispatch:\n", workflow_text)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "dist" / "quadrille-1.2.0.apk"
            apk.parent.mkdir()
            apk.write_bytes(b"apk-bytes")
            tool = root / "sdk" / "build-tools" / "35.0.0" / "apksigner"
            tool.parent.mkdir(parents=True)
            tool.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' 'Signer #1 certificate SHA-256 digest: {MATCHING_DIGEST}'\n"
            )
            tool.chmod(0o755)
            missing = run_bash(
                verify["run"],
                {
                    "APK_PATH": str(apk),
                    "ANDROID_HOME": str(root / "sdk"),
                    "PATH": os.environ["PATH"],
                },
                ROOT,
            )
            self.assertNotEqual(missing.returncode, 0)
            matched = run_bash(
                verify["run"],
                {
                    "APK_PATH": str(apk),
                    "UPLOAD_CERT_SHA256": MATCHING_DIGEST,
                    "ANDROID_HOME": str(root / "sdk"),
                    "PATH": os.environ["PATH"],
                },
                ROOT,
            )
            self.assertEqual(matched.returncode, 0, matched.stderr)


if __name__ == "__main__":
    unittest.main()

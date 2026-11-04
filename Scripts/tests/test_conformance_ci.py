import hashlib
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("conformance_ci", ROOT / "Scripts/Conformance/ci.py")
CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CI)


class ConformanceCITests(unittest.TestCase):
    def test_console_and_artifact_keep_both_streams_and_the_failed_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "step.log"
            console = io.StringIO()
            with contextlib.redirect_stdout(console):
                code = CI.execute_logged(
                    [sys.executable, "-c", "import sys; print('stdout fixture', flush=True); "
                     "print('stderr fixture', file=sys.stderr, flush=True); sys.exit(7)"],
                    cwd=root, environment={}, log=log)
            self.assertEqual(code, 7)
            self.assertEqual(console.getvalue(), log.read_text())
            self.assertIn("stdout fixture", console.getvalue())
            self.assertIn("stderr fixture", console.getvalue())

    def test_process_environment_excludes_credentials_and_ambient_configuration(self):
        parent = {
            "PATH": "/fixture/bin", "DEVELOPER_DIR": "/fixture/Xcode",
            "OPENAI_API_KEY": "synthetic-key", "AWS_PROFILE": "synthetic-profile",
            "GOOGLE_APPLICATION_CREDENTIALS": "/fixture/credential-file",
            "UNRELATED_SESSION": "synthetic-session", "npm_config_userconfig": "/fixture/npmrc",
            "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "http.proxy",
            "GIT_CONFIG_VALUE_0": "http://proxy.example.test:1234",
            "GIT_CONFIG_KEY_1": "http.version", "GIT_CONFIG_VALUE_1": "HTTP/1.1",
            "GIT_CONFIG_KEY_2": "http.extraheader", "GIT_CONFIG_VALUE_2": "synthetic-private-header",
        }
        root = Path("/fresh-workspace")
        environment = CI.isolated_environment(parent, root)
        for key in ["OPENAI_API_KEY", "AWS_PROFILE", "GOOGLE_APPLICATION_CREDENTIALS", "UNRELATED_SESSION"]:
            self.assertNotIn(key, environment)
        self.assertNotIn("synthetic-private-header", environment.values())
        self.assertEqual(environment["GIT_CONFIG_KEY_0"], "credential.helper")
        self.assertEqual(environment["GIT_CONFIG_VALUE_0"], "")
        self.assertEqual(environment["GIT_CONFIG_KEY_1"], "http.proxy")
        self.assertEqual(environment["GIT_CONFIG_KEY_2"], "http.version")
        for key in ["npm_config_userconfig", "npm_config_globalconfig", "npm_config_cache",
                    "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "PI_AI_SWIFT_UPSTREAM_CACHE"]:
            self.assertTrue(Path(environment[key]).is_relative_to(root))

    def test_failed_gate_retains_failure_and_verifiable_artifact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "logs/failing-step.log"
            log.parent.mkdir()
            log.write_text("synthetic assertion failure\n")
            evidence = {"exitCode": 1, "steps": [{"exitCode": 1, "log": "logs/failing-step.log"}]}
            CI.write_evidence(root, evidence)
            self.assertEqual(json.loads((root / "evidence.json").read_text()), evidence)
            names = set()
            for line in (root / "SHA256SUMS").read_text().splitlines():
                digest, relative = line.split("  ", 1)
                names.add(relative)
                self.assertEqual(hashlib.sha256((root / relative).read_bytes()).hexdigest(), digest)
            self.assertEqual(names, {"evidence.json", "logs/failing-step.log"})
            log.write_text("modified result\n")
            self.assertNotIn(hashlib.sha256(log.read_bytes()).hexdigest(), (root / "SHA256SUMS").read_text())


if __name__ == "__main__":
    unittest.main()

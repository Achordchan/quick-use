"""Run real scripts in temporary directories; never write the user's Codex files."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENGINES = {
    "powershell": shutil.which("powershell") or shutil.which("pwsh"),
    "bash": shutil.which("bash"),
}
REQUESTED = os.environ.get("QUICK_USE_TEST_ENGINE")
if REQUESTED:
    if REQUESTED not in ENGINES or not ENGINES[REQUESTED]:
        raise RuntimeError(f"Requested engine unavailable: {REQUESTED}")
    ENGINES = {REQUESTED: ENGINES[REQUESTED]}
ENGINES = {name: exe for name, exe in ENGINES.items() if exe}
if not ENGINES:
    raise RuntimeError("No supported shell available")


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def run_script(engine, target, *actions, fail_copy=False):
    if engine == "powershell":
        script = ps_quote(ROOT / "scripts/codex-quick-use.ps1")
        command = (
            f". {script} -Action exit; "
            "function Get-TargetPaths { @{ "
            f"TargetDir={ps_quote(target)}; "
            f"ConfigPath={ps_quote(target / 'config.toml')}; "
            f"AuthPath={ps_quote(target / 'auth.json')} "
            "} }; $script:ApiKey='sk-regression-test'; "
        )
        if fail_copy:
            command += "function Copy-Item { throw 'Simulated copy failure' }; "
        command += "; ".join(
            "Invoke-Deploy" if action == "deploy" else "Invoke-RestoreDefault"
            for action in actions
        )
        args = [ENGINES[engine], "-NoProfile", "-Command", command]
    else:
        script = shlex.quote((ROOT / "scripts/codex-quick-use.sh").as_posix())
        command = (
            f"CODEX_ACTION=exit source {script}; "
            f"target_dir={shlex.quote(target.as_posix())}; "
            'config_path="$target_dir/config.toml"; '
            'auth_path="$target_dir/auth.json"; api_key=sk-regression-test; '
        )
        if fail_copy:
            command += "cp() { return 1; }; "
        command += "; ".join(
            "deploy" if action == "deploy" else "restore_default" for action in actions
        )
        args = [ENGINES[engine], "-c", command]
    result = subprocess.run(args, capture_output=True, timeout=30)
    if result.returncode:
        raise AssertionError(result.stdout.decode(errors="replace") + result.stderr.decode(errors="replace"))


class ScriptTests(unittest.TestCase):
    def targets(self):
        for engine in ENGINES:
            with self.subTest(engine=engine), tempfile.TemporaryDirectory(prefix="quick-use-test-") as folder:
                yield engine, Path(folder)

    def test_restore_without_deploy_preserves_files(self):
        for engine, target in self.targets():
            original = {"config.toml": b'model = "original"\n', "auth.json": b'{"tokens":{"access_token":"test-only"}}'}
            for name, content in original.items():
                (target / name).write_bytes(content)
            run_script(engine, target, "restore", "restore")
            self.assertEqual({p.name: p.read_bytes() for p in target.iterdir()}, original)

    def test_repeated_deploy_and_restore_preserves_original_bytes(self):
        for engine, target in self.targets():
            original = {"config.toml": b'model = "original"\r\n[features]\r\nshell_tool = true\r\n', "auth.json": b'{"tokens":{"access_token":"test-only"}}\n'}
            for name, content in original.items():
                (target / name).write_bytes(content)
            run_script(engine, target, "deploy", "deploy", "restore", "restore")
            self.assertEqual({p.name: p.read_bytes() for p in target.iterdir()}, original)

    def test_empty_directory_repeated_deploy_restores_absence(self):
        for engine, target in self.targets():
            run_script(engine, target, "deploy", "deploy")
            self.assertFalse((target / "config.toml.bak").exists())
            self.assertFalse((target / "auth.json.bak").exists())
            run_script(engine, target, "restore", "restore")
            self.assertEqual(list(target.iterdir()), [])

    def test_each_file_tracks_its_own_original_state(self):
        for engine, target in self.targets():
            for name, content in [("config.toml", b'model = "original"\n'), ("auth.json", b'{}\n')]:
                with self.subTest(original_file=name):
                    (target / name).write_bytes(content)
                    run_script(engine, target, "deploy", "deploy", "restore", "restore")
                    self.assertEqual({p.name: p.read_bytes() for p in target.iterdir()}, {name: content})
                    (target / name).unlink()

    def test_legacy_backups_remain_supported(self):
        for engine, target in self.targets():
            original = {"config.toml": b'model = "original"\n', "auth.json": b'{}\n'}
            for name, content in original.items():
                (target / (name + ".bak")).write_bytes(content)
            run_script(engine, target, "deploy", "restore", "restore")
            self.assertEqual({p.name: p.read_bytes() for p in target.iterdir()}, original)

    def test_failed_restore_preserves_backup_for_retry(self):
        for engine, target in self.targets():
            original = b'model = "original"\n'
            (target / "config.toml").write_bytes(original)
            run_script(engine, target, "deploy")
            with self.assertRaises(AssertionError):
                run_script(engine, target, "restore", fail_copy=True)
            self.assertEqual((target / "config.toml.bak").read_bytes(), original)
            run_script(engine, target, "restore", "restore")
            self.assertEqual({p.name: p.read_bytes() for p in target.iterdir()}, {"config.toml": original})

    def test_later_unmanaged_settings_survive_absent_restore(self):
        for engine, target in self.targets():
            run_script(engine, target, "deploy")
            with (target / "config.toml").open("a", encoding="utf-8") as config:
                config.write('\n[projects."example"]\ntrust_level = "trusted"\n')
            run_script(engine, target, "restore", "restore")
            parsed = tomllib.loads((target / "config.toml").read_text(encoding="utf-8"))
            self.assertEqual(parsed, {"projects": {"example": {"trust_level": "trusted"}}})
            self.assertFalse((target / "auth.json").exists())

    def test_merge_commented_headers_and_quoted_keys(self):
        for engine, target in self.targets():
            original = '''"model" = "old"
'model_provider' = "old"
custom_setting = "keep"
[ "model_providers" . 'OpenAI' ] # old provider ]
name = "old"
base_url = "https://example.invalid"
[ 'features' ] # preferences ]
"goals" = false
shell_tool = true
[projects."name#with]brackets"] # project
trust_level = "trusted"
'''
            (target / "config.toml").write_bytes(original.replace("\n", "\r\n").encode())
            run_script(engine, target, "deploy", "deploy")
            parsed = tomllib.loads((target / "config.toml").read_text(encoding="utf-8"))
            self.assertEqual(parsed["model"], "gpt-5.5")
            self.assertEqual(parsed["model_provider"], "OpenAI")
            self.assertEqual(parsed["custom_setting"], "keep")
            self.assertEqual(parsed["features"], {"goals": True, "shell_tool": True})
            self.assertEqual(parsed["projects"]["name#with]brackets"]["trust_level"], "trusted")
            auth = json.loads((target / "auth.json").read_text(encoding="utf-8"))
            self.assertEqual(auth, {"OPENAI_API_KEY": "sk-regression-test"})
            run_script(engine, target, "restore")
            self.assertEqual((target / "config.toml").read_bytes(), original.replace("\n", "\r\n").encode())


if __name__ == "__main__":
    unittest.main()

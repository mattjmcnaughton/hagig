"""Script contracts with disposable tool stand-ins; NOT macOS execution evidence."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parent


class BundleContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hagig bundle contracts ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.mac = self.root / "clients/macos"
        self.mac.mkdir(parents=True)
        (self.root / "backend").mkdir()
        for name in ("bundle.sh", "Info.plist", "smoke-bundle.sh"):
            shutil.copy2(SOURCE / name, self.mac / name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.log = self.root / "calls"
        self.env = dict(os.environ, PATH=f"{self.tools}:/usr/bin:/bin", CALLS=str(self.log))
        self.env.pop("DEVELOPER_DIR", None)
        self.stub("uname", 'if [ "$1" = -m ]; then echo arm64; else echo Darwin; fi')
        self.stub("xcodebuild", 'echo "Xcode 16.4"')
        self.stub("swift", '''
case "$*" in
  *--show-bin-path*) printf '%s\n' "$PWD/.build/release" ;;
  *) mkdir -p .build/release; printf shell > .build/release/HagigShell ;;
esac''')
        self.stub("cargo", '''
mkdir -p target/aarch64-apple-darwin/release
printf cli > target/aarch64-apple-darwin/release/hagig
printf fake > target/aarch64-apple-darwin/release/hagig-fake-worker''')
        self.stub("plutil", ':')
        self.stub("codesign", ':')
        self.stub("open", ':')

    def stub(self, name, body):
        path = self.tools / name
        path.write_text(f'#!/bin/bash\nprintf "%s\\n" "{name} $*" >> "$CALLS"\n{body}\n')
        path.chmod(0o755)

    def run_bundle(self, *args):
        return subprocess.run(["/bin/bash", str(self.mac / "bundle.sh"), *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_usage_rejects_extra_or_unknown_arguments_without_tools(self):
        for args in (("wat",), ("build", "extra"), ()):
            with self.subTest(args=args):
                self.assertNotEqual(self.run_bundle(*args).returncode, 0)
        self.assertEqual(self.run_bundle("--help").returncode, 0)
        self.assertEqual(self.calls(), "")

    def test_existing_bundle_or_symlink_is_never_replaced(self):
        build = self.mac / ".build"
        build.mkdir()
        bundle = build / "Hagig.app"
        bundle.mkdir()
        sentinel = bundle / "keep"
        sentinel.write_text("live paired bytes")
        self.assertNotEqual(self.run_bundle("build").returncode, 0)
        self.assertEqual(sentinel.read_text(), "live paired bytes")
        shutil.rmtree(bundle)
        bundle.symlink_to(self.root / "missing")
        self.assertNotEqual(self.run_bundle("run").returncode, 0)
        self.assertTrue(bundle.is_symlink())
        self.assertNotIn("cargo", self.calls())
        self.assertNotIn("open ", self.calls())

    def test_symlink_build_directory_refused(self):
        (self.mac / ".build").symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(self.run_bundle("build").returncode, 0)
        self.assertFalse((self.root / "Hagig.app").exists())

    def test_build_in_path_with_spaces_packages_only_existing_binaries(self):
        result = self.run_bundle("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        contents = self.mac / ".build/Hagig.app/Contents"
        self.assertEqual((contents / "MacOS/HagigShell").read_text(), "shell")
        self.assertEqual((contents / "Helpers/hagig").read_text(), "cli")
        self.assertEqual((contents / "Helpers/hagig-fake-worker").read_text(), "fake")
        self.assertEqual(sorted(str(p.relative_to(contents)) for p in contents.rglob("*") if p.is_file()),
                         ["Helpers/hagig", "Helpers/hagig-fake-worker", "Info.plist", "MacOS/HagigShell"])
        self.assertNotIn("open ", self.calls())
        self.assertIn("--locked", self.calls())
        self.assertIn("--target aarch64-apple-darwin", self.calls())
        self.assertIn("--verify", self.calls())
        self.assertFalse((self.mac / ".build/bundle.lock").exists())

    def test_run_launches_bundle_only_after_success(self):
        result = self.run_bundle("run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"open {self.mac}/.build/Hagig.app\n", self.calls())

    def test_failure_cleans_staging_and_does_not_publish_or_launch(self):
        for tool in ("cargo", "swift", "codesign"):
            with self.subTest(tool=tool):
                original = (self.tools / tool).read_text()
                self.stub(tool, 'exit 19')
                self.assertNotEqual(self.run_bundle("run").returncode, 0)
                self.assertFalse((self.mac / ".build/Hagig.app").exists())
                self.assertFalse((self.mac / ".build/bundle.lock").exists())
                self.assertEqual(list((self.mac / ".build").glob("bundle.*")), [])
                self.assertNotIn("open ", self.calls())
                (self.tools / tool).write_text(original)

    def test_concurrent_build_lock_is_preserved(self):
        lock = self.mac / ".build/bundle.lock"
        lock.mkdir(parents=True)
        self.assertNotEqual(self.run_bundle("build").returncode, 0)
        self.assertTrue(lock.is_dir())
        self.assertNotIn("cargo", self.calls())

    def test_non_macos_refuses_before_building(self):
        self.stub("uname", 'echo Linux')
        self.assertNotEqual(self.run_bundle("build").returncode, 0)
        self.assertNotIn("cargo", self.calls())

    def test_smoke_loader_checks_system_swift_and_rejects_checkout_paths(self):
        self.assertEqual(self.run_bundle("build").returncode, 0)
        contents = self.mac / ".build/Hagig.app/Contents"
        (contents / "MacOS/HagigShell").write_text('#!/bin/bash\nexec sleep 30\n')
        scratch = self.root / "smoke scratch"
        service = self.root / "simulated service"
        runtime_record = self.root / "observed runtime"
        caller_runtime = self.root / "caller runtime"
        caller_runtime.mkdir()
        sentinel = caller_runtime / "live"
        sentinel.write_text("unrelated service")
        self.env.update(SMOKE_SCRATCH=str(scratch), SERVICE_STATE=str(service),
                        RUNTIME_RECORD=str(runtime_record), TEST_PYTHON=sys.executable,
                        XDG_RUNTIME_DIR=str(caller_runtime))
        self.stub("mktemp", 'mkdir "$SMOKE_SCRATCH"; printf "%s\\n" "$SMOKE_SCRATCH"')
        (contents / "Helpers/hagig").write_text('''#!/bin/bash
[ "$XDG_RUNTIME_DIR" = "$SMOKE_SCRATCH/runtime" ] || exit 61
"$TEST_PYTHON" -c 'import os, stat; assert stat.S_IMODE(os.stat(os.environ["XDG_RUNTIME_DIR"]).st_mode) == 0o700' || exit 62
printf '%s' "$XDG_RUNTIME_DIR" > "$RUNTIME_RECORD"
case "$1" in
status) if [ -e "$SERVICE_STATE" ]; then echo running; else echo stopped; fi ;;
fake-request) touch "$SERVICE_STATE"; printf '\\n' ;;
stop) [ "$FAIL_STOP" = 0 ] || exit 63; rm -f "$SERVICE_STATE"; echo stopped ;;
esac
''')
        self.stub("file", 'echo "Mach-O 64-bit executable arm64"')
        self.stub("otool", '''
if [ "$1" = -L ]; then
    printf 'binary:\\n\\t%s (compatibility version 1.0.0)\\n' "$DEPENDENCY"
else
    printf '          cmd LC_RPATH\\n      cmdsize 32\\n         path %s (offset 12)\\n' "$RPATH"
fi''')
        cases = (("/usr/lib/libSystem.B.dylib", "/usr/lib/swift", True, False),
                 ("@rpath/libswift_Concurrency.dylib", "/usr/lib/swift", True, False),
                 ("/tmp/checkout/libbad.dylib", "/usr/lib/swift", False, False),
                 ("@rpath/libswift_Concurrency.dylib", "/tmp/checkout/lib", False, False),
                 ("/usr/lib/libSystem.B.dylib", "/usr/lib/swift", False, True))
        for dependency, rpath, succeeds, fail_stop in cases:
            with self.subTest(dependency=dependency, rpath=rpath, fail_stop=fail_stop):
                self.env.update(DEPENDENCY=dependency, RPATH=rpath, FAIL_STOP=str(int(fail_stop)))
                result = subprocess.run(["/bin/bash", str(self.mac / "smoke-bundle.sh")],
                                        env=self.env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                self.assertEqual(sentinel.read_text(), "unrelated service")
                self.assertEqual(list(caller_runtime.iterdir()), [sentinel])
                self.assertEqual(service.exists(), fail_stop)
                self.assertEqual(scratch.exists(), fail_stop)
                if succeeds or fail_stop:
                    self.assertEqual(runtime_record.read_text(), str(scratch / "runtime"))
                if fail_stop:
                    self.assertIn("retained private smoke directory", result.stderr)
                    self.assertTrue((scratch / "relocated app/Hagig.app").is_dir())
                    self.assertEqual((scratch / "result").read_bytes(), b"\n")


if __name__ == "__main__":
    unittest.main()

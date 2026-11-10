"""bundle.sh and helper contracts with disposable tool stand-ins.

NOT macOS execution evidence: uv, Swift, codesign and the interpreter are
stand-ins here. smoke-bundle.sh and bundle-proof.sh on macOS are the evidence.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
SYNC = "sync --frozen --no-dev --no-editable"


class BundleContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hagig bundle contracts ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.mac = self.root / "clients/macos"
        self.mac.mkdir(parents=True)
        (self.root / "backend").mkdir()
        (self.root / "LICENSE").write_text("MIT License (stand-in)\n")
        for name in ("bundle.sh", "Info.plist", "smoke-bundle.sh"):
            shutil.copy2(SOURCE / name, self.mac / name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.log = self.root / "calls"
        self.managed = self.root / "uv python"
        self.base = self.managed / "cpython-3.12.14-macos-aarch64-none"
        self.make_managed_python()
        self.env = {
            "PATH": f"{self.tools}:/usr/bin:/bin",
            "HOME": str(self.root),
            "CALLS": str(self.log),
            "MANAGED": str(self.managed),
            # A caller's preference never reaches the bundled sync.
            "UV_PYTHON_PREFERENCE": "system",
        }
        self.stub("uname", 'if [ "$1" = -m ]; then echo arm64; else echo Darwin; fi')
        self.stub("xcodebuild", 'echo "Xcode 16.4"')
        self.stub("swift", """
case "$*" in
  *--show-bin-path*) printf '%s\\n' "$PWD/.build/release" ;;
  *) mkdir -p .build/release; printf 'MACHO shell' > .build/release/HagigShell ;;
esac""")
        # A uv environment: packages in a venv whose python links to the managed one.
        self.stub("uv", """
case "$1" in
  python) [ "$2" = dir ] && printf '%s\\n' "${UV_DIR:-$MANAGED}" ;;
  sync)
    printf 'preference=%s\\n' "$UV_PYTHON_PREFERENCE" >> "$CALLS"
    env=$UV_PROJECT_ENVIRONMENT
    site=$env/lib/python3.12/site-packages
    mkdir -p "$env/bin" "$site/hagig" "$site/hagig-0.1.0.dist-info" "$site/__pycache__"
    ln -s "$MANAGED/cpython-3.12.14-macos-aarch64-none/bin/python3.12" "$env/bin/python"
    printf 'pkg' > "$site/hagig/__init__.py"
    [ -n "$NO_PROFILE" ] || printf '(version 1)' > "$site/hagig/seatbelt-v1.sb"
    printf 'MACHO ext' > "$site/hagig/_native.cpython-312-darwin.so"
    printf '{"url":"file://checkout"}' > "$site/hagig-0.1.0.dist-info/direct_url.json"
    printf 'meta' > "$site/hagig-0.1.0.dist-info/METADATA"
    printf 'import _virtualenv' > "$site/_virtualenv.pth"
    printf 'import _distutils_hack' > "$site/distutils-precedence.pth"
    printf 'shim' > "$site/_virtualenv.py"
    printf 'pyc' > "$site/__pycache__/_virtualenv.cpython-312.pyc"
    [ -z "$EXTRA_PTH" ] || printf '/somewhere\\n' > "$site/extra.pth"
    [ -z "$SITECUSTOMIZE" ] || printf 'import os' > "$site/sitecustomize.py" ;;
esac""")
        self.stub("file", 'if grep -q MACHO "${!#}"; then echo "Mach-O 64-bit arm64"; else echo "ASCII text"; fi')
        self.stub("codesign", ":")
        for name in ("plutil", "install_name_tool", "open"):
            self.stub(name, ":")

    def make_managed_python(self):
        base = self.base
        for directory in ("bin", "include/python3.12", "share/man", "lib/pkgconfig",
                          "lib/python3.12/site-packages/pip", "lib/python3.12/ensurepip",
                          "lib/python3.12/idlelib", "lib/python3.12/tkinter",
                          "lib/python3.12/config-3.12-darwin", "lib/python3.12/lib-dynload",
                          "lib/tcl9.0", "lib/tk9.0"):
            (base / directory).mkdir(parents=True)
        python = base / "bin/python3.12"
        python.write_text("""#!/bin/bash
# MACHO stand-in interpreter
here=$(dirname "$(dirname "$(readlink -f "$0")")")
printf '%s\\n' "python $0 $*" >> "$CALLS"
case "$*" in
  *version_info*) echo 3.12 ;;
  *base_prefix*) printf '%s\\n' "$here" ;;
  *compileall*) : ;;
  *SEATBELT_PROFILE*) [ -f "$here/lib/python3.12/site-packages/hagig/seatbelt-v1.sb" ] ;;
esac
""")
        python.chmod(0o755)
        (base / "bin/python3").symlink_to("python3.12")
        (base / "bin/pip").write_text("#!/build/host/python\n")
        (base / "bin/pip").chmod(0o755)
        for name, text in (("lib/libpython3.12.dylib", "MACHO lib"),
                           ("lib/libtcl9.0.dylib", "MACHO tcl"),
                           ("lib/python3.12/lib-dynload/_ssl.cpython-312-darwin.so", "MACHO ssl"),
                           ("lib/python3.12/lib-dynload/_tkinter.cpython-312-darwin.so", "MACHO tk"),
                           ("lib/python3.12/os.py", "stdlib"),
                           ("include/python3.12/Python.h", "header")):
            (base / name).write_text(text)

    def stub(self, name, body):
        path = self.tools / name
        path.write_text(f'#!/bin/bash\nprintf "%s\\n" "{name} $*" >> "$CALLS"\n{body}\n')
        path.chmod(0o755)

    def run_bundle(self, *args):
        args = args or ("build",)
        return subprocess.run(["/bin/bash", str(self.mac / "bundle.sh"), *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def output(self):
        return self.mac / ".build/Hagig.app"

    def assert_no_output(self):
        self.assertFalse(self.output().exists())
        self.assertFalse((self.mac / ".build/bundle.lock").exists())
        self.assertEqual(list((self.mac / ".build").glob("bundle.*")), [])
        self.assertNotIn("open ", self.calls())

    def test_usage_rejects_extra_or_unknown_arguments_without_tools(self):
        for args in (("wat",), ("build", "/prepared/Contents"), ("run", "extra")):
            with self.subTest(args=args):
                self.assertEqual(self.run_bundle(*args).returncode, 2)
        self.assertEqual(self.run_bundle("--help").returncode, 0)
        self.assertEqual(self.calls(), "")

    def test_layout_is_the_managed_interpreter_with_the_locked_packages(self):
        result = self.run_bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        contents = self.output() / "Contents"
        files = sorted(str(p.relative_to(contents)) for p in contents.rglob("*")
                       if p.is_file() or p.is_symlink())
        site = "Resources/python/lib/python3.12/site-packages"
        self.assertEqual(files, sorted([
            "Info.plist", "MacOS/HagigShell", "Helpers/hagig", "Resources/LICENSE",
            "Resources/python/bin/python3.12",
            "Resources/python/lib/libpython3.12.dylib",
            "Resources/python/lib/python3.12/os.py",
            "Resources/python/lib/python3.12/lib-dynload/_ssl.cpython-312-darwin.so",
            f"{site}/hagig/__init__.py", f"{site}/hagig/_native.cpython-312-darwin.so",
            f"{site}/hagig-0.1.0.dist-info/METADATA", f"{site}/hagig/seatbelt-v1.sb",
        ]))
        self.assertEqual((contents / "Resources/LICENSE").read_text(), "MIT License (stand-in)\n")
        self.assertIn(f"uv {SYNC}\npreference=only-managed\n", self.calls())
        # The build never edits the developer's managed interpreter.
        self.assertTrue((self.base / "bin/pip").exists())
        self.assertTrue((self.base / "lib/python3.12/site-packages/pip").is_dir())

    def test_everything_is_signed_inside_out_after_compiling(self):
        self.assertEqual(self.run_bundle().returncode, 0)
        calls = self.calls().splitlines()
        signs = [i for i, line in enumerate(calls) if line.startswith("codesign --force")]
        compile_at = next(i for i, line in enumerate(calls) if "compileall" in line)
        self.assertEqual(len(signs), 3)
        self.assertLess(compile_at, signs[0])
        python = calls[signs[0]]
        for member in ("bin/python3.12", "lib/libpython3.12.dylib", "_ssl.cpython-312-darwin.so",
                       "_native.cpython-312-darwin.so"):
            self.assertIn(member, python)
        self.assertNotIn("libtcl", python)
        self.assertIn("Helpers/hagig", calls[signs[1]])
        self.assertIn("MacOS/HagigShell", calls[signs[1]])
        self.assertTrue(calls[signs[2]].endswith("/Hagig.app"))
        self.assertTrue(calls[signs[2] + 1].startswith("codesign --verify --deep --strict"))
        self.assertTrue(all(str(self.managed) not in calls[i] for i in signs))

    def test_startup_code_missing_profile_or_unmanaged_python_never_publish(self):
        # UV_DIR stands in for an interpreter outside uv's managed directory.
        for name, value in (("EXTRA_PTH", "1"), ("SITECUSTOMIZE", "1"), ("NO_PROFILE", "1"),
                            ("UV_DIR", "/usr")):
            with self.subTest(variable=name):
                self.env[name] = value
                self.assertNotEqual(self.run_bundle("run").returncode, 0)
                self.assert_no_output()
                del self.env[name]

    def test_failure_cleans_staging_and_does_not_publish_or_launch(self):
        for tool in ("swift", "uv", "install_name_tool", "codesign"):
            with self.subTest(tool=tool):
                original = (self.tools / tool).read_text()
                self.stub(tool, "exit 19")
                self.assertNotEqual(self.run_bundle("run").returncode, 0)
                self.assert_no_output()
                (self.tools / tool).write_text(original)

    def test_existing_bundle_symlink_lock_or_non_macos_is_refused(self):
        build = self.mac / ".build"
        build.mkdir()
        bundle = build / "Hagig.app"
        bundle.mkdir()
        (bundle / "keep").write_text("live paired bytes")
        self.assertNotEqual(self.run_bundle().returncode, 0)
        self.assertEqual((bundle / "keep").read_text(), "live paired bytes")
        shutil.rmtree(bundle)
        bundle.symlink_to(self.root / "missing")
        self.assertNotEqual(self.run_bundle("run").returncode, 0)
        self.assertTrue(bundle.is_symlink())
        bundle.unlink()
        (build / "bundle.lock").mkdir()
        self.assertNotEqual(self.run_bundle().returncode, 0)
        self.assertTrue((build / "bundle.lock").is_dir())
        (build / "bundle.lock").rmdir()
        self.stub("uname", "echo Linux")
        self.assertNotEqual(self.run_bundle().returncode, 0)
        self.assertNotIn("uv sync", self.calls())
        self.assertNotIn("open ", self.calls())

    def test_symlink_build_directory_refused(self):
        (self.mac / ".build").symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(self.run_bundle().returncode, 0)
        self.assertFalse((self.root / "Hagig.app").exists())

    def test_run_opens_the_bundle_only_after_success(self):
        result = self.run_bundle("run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"open {self.output()}\n", self.calls())

    def test_helper_execs_the_bundled_interpreter_relative_to_itself(self):
        self.assertEqual(self.run_bundle().returncode, 0)
        app = self.root / "moved elsewhere/Hagig.app"
        app.parent.mkdir()
        shutil.move(str(self.output()), app)
        record = self.root / "record.json"
        interpreter = app / "Contents/Resources/python/bin/python3.12"
        interpreter.write_text(f"""#!{sys.executable} -I
import json, os, sys
json.dump({{"argv": sys.argv, "env": dict(os.environ)}}, open({str(record)!r}, "w"))
sys.exit(int(open({str(self.root / "exit")!r}).read()))
""")
        (self.root / "exit").write_text("2")
        link = self.root / "via link"
        link.symlink_to(app.parent, target_is_directory=True)
        helpers = app / "Contents/Helpers"
        for program, cwd in ((str(helpers / "hagig"), "/"), ("./hagig", helpers),
                             ("../../Contents/Helpers/hagig", helpers),
                             (str(link / "Hagig.app/Contents/Helpers/hagig"), "/")):
            with self.subTest(program=program):
                record.unlink(missing_ok=True)
                # No PATH, uv, PYTHONPATH or developer variables at all.
                done = subprocess.run([program, "start", "--x y"], cwd=cwd, env={},
                                      capture_output=True)
                self.assertEqual(done.returncode, 2, done.stderr)
                seen = json.loads(record.read_text())
                self.assertEqual(seen["argv"][0], str(interpreter))
                self.assertEqual(seen["argv"][1:4], ["-I", "-B", "-c"])
                self.assertIn("from hagig.cli import app", seen["argv"][4])
                self.assertEqual(seen["argv"][5:], ["start", "--x y"])
                self.assertEqual(seen["env"]["UV_OFFLINE"], "1")
                self.assertEqual(seen["env"]["UV_PYTHON_DOWNLOADS"], "never")
                self.assertNotIn("PYTHONPATH", seen["env"])
                self.assertFalse(any(str(self.root / "clients") in value
                                     for value in seen["env"].values()))

    def test_smoke_refuses_a_bundle_inside_the_checkout_or_a_relative_path(self):
        self.assertEqual(self.run_bundle().returncode, 0)
        self.log.unlink()
        for target in (str(self.output()), "clients/macos/.build/Hagig.app"):
            with self.subTest(target=target):
                done = subprocess.run(["/bin/bash", str(self.mac / "smoke-bundle.sh"), target],
                                      cwd=self.root, env=self.env, capture_output=True, text=True)
                self.assertNotEqual(done.returncode, 0)
        self.assertNotIn("codesign", self.calls())


if __name__ == "__main__":
    unittest.main()

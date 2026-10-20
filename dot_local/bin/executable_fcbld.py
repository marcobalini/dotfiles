#!/usr/bin/env python3

import os
import platform
import shutil
import subprocess
import sys
import tempfile
import tarfile
import zipfile
from pathlib import Path

# Candidate base directories searched in order; the first one that exists is used.
# On non-Windows the Windows-specific paths are silently ignored.
if sys.platform == "win32":
    BASE_DIR_CANDIDATES = [
        Path("D:/_"),
        Path("C:/fctech/marco/_"),
        Path("~/_").expanduser(),
    ]
else:
    BASE_DIR_CANDIDATES = [
        Path("~/_").expanduser(),
    ]


def find_default_base() -> Path:
    """Return the first candidate base directory that already exists, or the first candidate as a fallback."""
    for candidate in BASE_DIR_CANDIDATES:
        if candidate.exists():
            return candidate
    return BASE_DIR_CANDIDATES[0]


# Repository definitions: (name, git_url, conan_subpath, build_during_configure)
# - conan_subpath: subpath containing Conan package (or None if repo is sync-only)
# - build_during_configure: if True, run `conan build` instead of `conan build -c user.fc:configure_only=y`
REPOS = [
    ("conan-utils", "https://github.com/FairCom-Official/fairCom-conan-utils.git", None, False),
    ("conan-profiles", "https://github.com/FairCom-Official/fairCom-conan-profiles.git", None, False),
    ("build", "https://github.com/FairCom-Official/build.git", None, False),
    ("thirdparty", "https://github.com/FairCom-Official/thirdparty.git", None, False),
    ("kernel", "https://github.com/FairCom-Official/faircom-kernel.git", "make", True),
    ("util", "https://github.com/FairCom-Official/faircom-utility.git", "make", True),
    ("plugin", "https://github.com/FairCom-Official/faircom-plugin.git", "make", False),
    ("java", "https://github.com/FairCom-Official/faircom-java.git", "make", False),
    ("dotnet", "https://github.com/FairCom-Official/faircom-dotnet.git", "make", False),
    ("webtools", "https://github.com/FairCom-Official/faircom-webtools.git", "make", False),
    ("packager", "https://github.com/FairCom-Official/faircom-packager.git", "make", False),
]


def check_conan():
    """Verify that the conan executable is available; exit with a helpful hint if not."""
    try:
        result = subprocess.run(
            ["conan", "--version"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        print("ERROR: 'conan' not found. Install it with: pip install conan", file=sys.stderr)
        sys.exit(1)

    if result.returncode != 0:
        print("ERROR: 'conan' not found. Install it with: pip install conan", file=sys.stderr)
        sys.exit(1)


def check_cmake():
    """Verify that CMake is available; exit with a helpful hint if not."""
    try:
        result = subprocess.run(
            ["cmake", "--version"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        print(
            "ERROR: 'cmake' not found. Install it with: winget install --id Kitware.CMake -e\n"
            "       or download from https://cmake.org/download/",
            file=sys.stderr,
        )
        sys.exit(1)

    if result.returncode != 0:
        print(
            "ERROR: 'cmake' not found. Install it with: winget install --id Kitware.CMake -e\n"
            "       or download from https://cmake.org/download/",
            file=sys.stderr,
        )
        sys.exit(1)


def get_windows_vs_profile(path_value=None):
    """Return the Conan profile directory for the Visual Studio version on PATH."""
    path_value = os.environ.get("PATH", "") if path_value is None else path_value
    for path_entry in path_value.split(os.pathsep):
        parts = path_entry.replace("\\", "/").lower().split("/")
        if "2026" in parts or "vs2026" in parts:
            return "vs2026"
        if "2022" in parts or "vs2022" in parts:
            return "vs2022"
    return "vs2022"


def ensure_conan_default_profile(default_base):
    """Create the default Conan profile if it doesn't exist yet."""
    result = subprocess.run(
        ["conan", "profile", "path", "default"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        profile_path = Path.home() / ".conan2" / "profiles" / "default"
        profile_path.parent.mkdir(parents=True, exist_ok=True)
        if sys.platform == "win32":
            os_name, arch_name = "windows", "64bit"
            compiler_name = get_windows_vs_profile()
        elif sys.platform == "darwin":
            os_name, arch_name = "macos", "osx14_00_arm64"
            compiler_name = None
        else:
            os_name, arch_name = "linux", "64bit"
            compiler_name = None
        include_path = default_base / "conan-profiles" / "profiles" / "os" / os_name / arch_name
        if compiler_name:
            include_path /= compiler_name
        include_path /= "Debug"
        profile_path.write_text(f"include({include_path})\n")
        print(f"INFO: created default Conan profile: {profile_path}", flush=True)


def setup_environment(base):
    dotnet_dir = base / "dotnet-sdk"
    if not dotnet_dir.is_dir():
        install_dotnet_sdk(dotnet_dir)
    if dotnet_dir.is_dir():
        os.environ["PATH"] = f"{dotnet_dir}{os.pathsep}{os.environ.get('PATH', '')}"
        print(f"Added {dotnet_dir} to PATH", flush=True)

    java_dir = base / "java-sdk"
    if not java_dir.is_dir():
        install_java_sdk(java_dir)
    if java_dir.is_dir():
        os.environ["JAVA_HOME"] = str(java_dir)
        os.environ["PATH"] = f"{java_dir / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}"
        print(f"Set JAVA_HOME={java_dir}", flush=True)


def install_dotnet_sdk(dotnet_dir):
    """Download and run the official .NET install script for the host platform."""
    print(f"INFO: dotnet SDK not found, installing into {dotnet_dir}", flush=True)
    is_windows = sys.platform == "win32"
    script_suffix = ".ps1" if is_windows else ".sh"
    script_url = (
        "https://builds.dotnet.microsoft.com/dotnet/scripts/v1/"
        f"dotnet-install{script_suffix}"
    )
    with tempfile.NamedTemporaryFile(suffix=script_suffix, delete=False) as tmp:
        script_path = tmp.name
    try:
        run(["curl", "-sSL", "-o", script_path,
             script_url], cwd=Path.cwd())
        if is_windows:
            powershell = shutil.which("pwsh") or shutil.which("powershell")
            if powershell is None:
                raise RuntimeError("PowerShell is required to install the .NET SDK on Windows")
            run([
                powershell, "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", script_path, "-Channel", "8.0", "-Version", "latest",
                "-InstallDir", str(dotnet_dir),
            ], cwd=Path.cwd())
        else:
            os.chmod(script_path, 0o755)
            run(["bash", script_path, "-c", "8.0", "-v", "latest", "-i", str(dotnet_dir)], cwd=Path.cwd())
    finally:
        os.remove(script_path)


def install_java_sdk(java_dir):
    """Download and extract the latest GA Adoptium Temurin 11 JDK."""
    system = platform.system().lower()
    os_name = {"linux": "linux", "darwin": "mac", "windows": "windows"}.get(system)
    machine = platform.machine().lower()
    arch = {
        "x86_64": "x64",
        "amd64": "x64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
        "ppc64le": "ppc64le",
        "s390x": "s390x",
    }.get(machine)
    if os_name is None or arch is None:
        raise RuntimeError(f"Unsupported platform for Adoptium JDK installation: {system}/{machine}")

    extension = ".zip" if os_name == "windows" else ".tar.gz"
    url = (
        "https://api.adoptium.net/v3/binary/latest/11/ga/"
        f"{os_name}/{arch}/jdk/hotspot/normal/eclipse"
    )
    print(f"INFO: Java SDK not found, installing Adoptium 11 into {java_dir}", flush=True)
    java_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp_dir:
        archive_path = Path(temp_dir) / f"adoptium-11{extension}"
        run(["curl", "-fsSL", "-o", str(archive_path), url], cwd=Path.cwd())
        extract_dir = Path(temp_dir) / "extracted"
        extract_dir.mkdir()
        if extension == ".zip":
            with zipfile.ZipFile(archive_path) as archive:
                archive.extractall(extract_dir)
        else:
            with tarfile.open(archive_path, "r:gz") as archive:
                archive.extractall(extract_dir)

        roots = [path for path in extract_dir.iterdir() if path.is_dir()]
        if len(roots) != 1:
            raise RuntimeError(f"Unexpected Adoptium archive layout: {archive_path}")
        if java_dir.exists():
            shutil.rmtree(java_dir)
        shutil.move(str(roots[0]), str(java_dir))


def run(cmd, cwd):
    print(f"[{cwd}] $ {' '.join(cmd)}", flush=True)
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        print(f"ERROR: command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)


def git_pull_safe(repo_path, name):
    """Pull a git repo, with automatic stash/restore on dirty-file conflicts.

    Attempts a plain pull first. Only if git refuses with a
    "would be overwritten by merge" error does it stash local changes,
    retry the pull, then restore the stash. A uniquely-labelled stash
    entry is used so pre-existing stash entries are never disturbed.
    """
    OVERWRITTEN_ERR = "would be overwritten by merge"

    print(f"[{repo_path}] $ git pull", flush=True)
    result = subprocess.run(["git", "pull"], cwd=repo_path, capture_output=True, text=True)

    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)

    if result.returncode == 0:
        return  # clean pull — nothing else to do

    if OVERWRITTEN_ERR not in result.stderr:
        # Unrelated failure — propagate as normal.
        print(f"ERROR: command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)

    # Dirty-file conflict: stash, retry, restore.
    print("  (local changes conflict with pull — stashing and retrying)", flush=True)
    stash_label = f"fcbld-autostash-{name}"
    subprocess.run(
        ["git", "stash", "push", "--include-untracked", "-m", stash_label],
        cwd=repo_path,
        check=True,
    )

    run(["git", "pull"], cwd=repo_path)  # fatal on failure as usual

    # Locate our specific entry so we don't pop a pre-existing stash.
    list_result = subprocess.run(
        ["git", "stash", "list"], cwd=repo_path, capture_output=True, text=True
    )
    stash_ref = next(
        (line.split(":")[0] for line in list_result.stdout.splitlines() if stash_label in line),
        None,
    )
    if stash_ref is None:
        print(
            f"WARNING: could not find stash entry '{stash_label}' in {name}. "
            "Check 'git stash list' manually.",
            file=sys.stderr,
        )
        return

    pop_result = subprocess.run(
        ["git", "stash", "pop", stash_ref], cwd=repo_path, capture_output=True, text=True
    )
    if pop_result.stdout:
        print(pop_result.stdout, end="", flush=True)
    if pop_result.returncode == 0:
        print("  (restored stashed changes)", flush=True)
    else:
        if pop_result.stderr:
            print(pop_result.stderr, end="", file=sys.stderr, flush=True)
        print(
            f"WARNING: 'git stash pop {stash_ref}' had conflicts in {name}. "
            f"Changes remain in the stash as '{stash_label}' — "
            "run 'git stash list' to locate and resolve manually.",
            file=sys.stderr,
        )


def sync_repos(base):
    base.mkdir(parents=True, exist_ok=True)
    for name, url, _, _ in REPOS:
        repo_path = base / name
        if repo_path.is_dir():
            print(f"==> Pulling {name}", flush=True)
            git_pull_safe(repo_path, name)
        else:
            print(f"==> Cloning {name}", flush=True)
            run(["git", "clone", url, str(repo_path)], cwd=base)

        if name == "conan-utils":
            run(["conan", "editable", "add", str(repo_path)], cwd=base)

    if (base / "kernel" / "make").is_dir():
        run(["conan", "editable", "add", str(base / "kernel" / "make")], cwd=base)
    if (base / "util" / "make").is_dir():
        run(["conan", "editable", "add", str(base / "util" / "make")], cwd=base)


def run_capture(cmd, cwd):
    """Run a command, print its output in real time, and return the full stdout as a string."""
    print(f"[{cwd}] $ {' '.join(cmd)}", flush=True)
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    if result.returncode != 0:
        print(f"ERROR: command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)
    return result.stdout


def get_conan_opts(name, profile, args, base):
    # Resolve build/install dirs for non-profile invocations, or when the user
    # explicitly supplies them via CLI even alongside a profile.
    build_dir = str(args.build_dir.resolve()) if args.build_dir else None
    install_dir = str(args.install_dir.resolve()) if args.install_dir else None

    if profile:
        opts = [f"-pr:a={profile}"]
        if build_dir:
            opts += ["-c", f"user.fc:build_dir={build_dir}"]
        if install_dir:
            opts += ["-c", f"user.fc:install_dir={install_dir}"]
        return opts

    unicode_val = str(args.unicode)
    icu_val = str(args.icu)

    # Non-profile path: always pass build/install dirs, falling back to defaults.
    effective_build_dir = build_dir or str((Path.cwd() / "build").resolve())
    effective_install_dir = install_dir or str((Path.cwd() / "install").resolve())

    opts = [
        "-s", f"build_type={args.build_type}",
        "-c", f"user.fc:build_dir={effective_build_dir}",
        "-c", f"user.fc:install_dir={effective_install_dir}",
    ]

    if name == "kernel":
        opts.extend([
            "-o", f"&:oem={args.oem}",
            "-o", f"&:product_type={args.product}",
            "-o", f"&:unicode={unicode_val}",
            "-o", f"&:icu_version={icu_val}",
        ])
    else:
        opts.extend([
            "-o", f"faircom_kernel/*:oem={args.oem}",
            "-o", f"faircom_kernel/*:product_type={args.product}",
            "-o", f"faircom_kernel/*:unicode={unicode_val}",
            "-o", f"faircom_kernel/*:icu_version={icu_val}",
        ])

    return opts


def install(cwd, opts):
    run(["conan", "install", ".", "--update", "--build=missing"] + opts, cwd)


def configure(cwd, opts):
    run(["conan", "build", ".", "-c", "user.fc:configure_only=y"] + opts, cwd)


def build(cwd, opts):
    run(["conan", "build", "."] + opts, cwd)


def get_build_dir(profile, args, base):
    if profile:
        result = subprocess.run(
            ["conan", "profile", "show", f"-pr:a={profile}"],
            capture_output=True, text=True,
        )
        for line in result.stdout.splitlines():
            if "user.fc:build_dir" in line:
                return line.split("=", 1)[1].strip()
        return None
    else:
        build_dir = args.build_dir or (Path.cwd() / "builds")
        return str(build_dir.resolve())


def main():
    check_conan()
    check_cmake()
    import argparse
    usage_text = (
        "%(prog)s [-b BASE_DIR] [--no-sync] [--no-build] [--msbuild] [--profile] PROFILE\n"
        "       %(prog)s [-b BASE_DIR] [--no-sync] [--no-build] [--msbuild] -p PRODUCT [--oem OEM]\n"
        "              [--unicode {0,1,2}] [--icu {42,78}] [--build-type BUILD_TYPE]\n"
        "              [--build-dir BUILD_DIR] [--install-dir INSTALL_DIR]"
    )
    parser = argparse.ArgumentParser(
        usage=usage_text,
        description="Install, configure, and optionally build all FairCom components."
    )
    
    general_group = parser.add_argument_group("General options")
    default_base = find_default_base()
    candidates_str = ", ".join(str(c) for c in BASE_DIR_CANDIDATES)
    general_group.add_argument("--base-dir", "-b", type=Path, default=default_base, help=f"Base directory for repositories (checked in order: {candidates_str}).")
    general_group.add_argument("--no-sync", "--skip-sync", action="store_true", help="Skip syncing (git clone/pull) repositories.")
    general_group.add_argument("--no-build", "--skip-build", action="store_true", help="Skip running conan build (full compilation) after configure.")
    general_group.add_argument("--msbuild", action="store_true", help="Run msbuild on the generated solution after configure (Windows only).")

    profile_group = parser.add_argument_group("Profile mode")
    profile_group.add_argument("profile_name", nargs="?", default=None, metavar="PROFILE",
                               help="Conan profile to use (positional shorthand for --profile/-pr).")
    profile_group.add_argument("--profile", "-pr", default=None, help="Conan profile to use.")

    direct_group = parser.add_argument_group("Direct build mode (mutually exclusive with profile)")
    direct_group.add_argument("--oem", default=None, help="OEM option (default: edge, or rtg when product is rtg).")
    direct_group.add_argument("--product", "--product-type", "-p", default=None, help="Product type (e.g. edge, rtg).")
    direct_group.add_argument("--unicode", type=int, choices=[0, 1, 2], default=None, metavar="{0,1,2}", help="Unicode build mode: 0=disabled, 1=enabled, 2=auto (default: 2).")
    direct_group.add_argument("--icu", type=int, choices=[42, 78], default=None, metavar="{42,78}", help="ICU version to use (default: 78 when --unicode=2, 42 when --unicode<=1).")
    direct_group.add_argument("--build-type", default=None, help="Build type (default: Debug).")
    direct_group.add_argument("--build-dir", type=Path, default=None, help="Build output directory (default: ./builds).")
    direct_group.add_argument("--install-dir", type=Path, default=None, help="Install output directory (default: ./packages).")
    args = parser.parse_args()

    # Merge positional profile name into --profile
    if args.profile_name is not None:
        if args.profile is not None:
            parser.error("PROFILE positional and --profile/-pr cannot both be specified")
        args.profile = args.profile_name

    direct_opts_specified = [
        opt for opt in ["oem", "unicode", "icu", "build_type", "build_dir", "install_dir"]
        if getattr(args, opt) is not None
    ]

    if args.product is not None:
        # Direct-build mode: triggered by -p / --product
        if args.profile is not None:
            parser.error("--profile/-pr cannot be used together with -p/--product")
        # Apply defaults for direct-build mode
        if args.oem is None:
            args.oem = "rtg" if args.product.lower() == "rtg" else "edge"
        if args.unicode is None:
            args.unicode = 0
        if args.icu is None:
            args.icu = 78 if args.unicode == 2 else 42
        if args.build_type is None:
            args.build_type = "Debug"
    else:
        # Profile mode
        if args.profile is None:
            parser.error("a profile name (PROFILE / --profile / -pr) or -p/--product is required")
        if direct_opts_specified:
            opt_names = ", ".join("--" + opt.replace("_", "-") for opt in direct_opts_specified)
            parser.error(f"--profile/-pr cannot be used together with direct build options: {opt_names}")

    profile = args.profile

    base = args.base_dir.expanduser().resolve()
    ensure_conan_default_profile(base)
    setup_environment(base)

    if not args.no_sync:
        sync_repos(base)

    conan_dirs = []
    for name, _, subpath, build_during_configure in REPOS:
        if subpath is None:
            continue
        cwd = base / name / subpath
        if not cwd.is_dir():
            print(f"WARNING: directory not found, skipping: {cwd}", file=sys.stderr)
            continue
        opts = get_conan_opts(name, profile, args, base)
        install(cwd, opts)
        if build_during_configure:
            build(cwd, opts)
        else:
            configure(cwd, opts)
        conan_dirs.append((name, cwd))

    build_dir = get_build_dir(profile, args, base)
    if build_dir is None:
        print("WARNING: could not determine user.fc:build_dir, skipping create_faircom_all_slnx.py", file=sys.stderr)
    else:
        script = base / "kernel" / "create_faircom_all_slnx.py"
        slnx_path = Path(build_dir) / "kernel" / "faircom_kernel.slnx"
        if script.is_file() and slnx_path.is_file():
            output = run_capture([sys.executable, str(script), build_dir], base)
            if args.msbuild:
                if sys.platform != "win32":
                    print("WARNING: --msbuild is only supported on Windows, skipping msbuild execution", file=sys.stderr)
                else:
                    sln_path = None
                    for line in output.splitlines():
                        if line.startswith("Written:"):
                            sln_path = line.split(":", 1)[1].strip()
                            break
                    if sln_path is None:
                        print("ERROR: could not find solution path in create_faircom_all_slnx.py output", file=sys.stderr)
                        sys.exit(1)
                    run(["msbuild", sln_path, "-m"], base)
        else:
            if not script.is_file():
                print(f"WARNING: script not found, skipping: {script}", file=sys.stderr)
            elif not slnx_path.is_file():
                print(f"WARNING: solution file not found, skipping create_faircom_all_slnx.py: {slnx_path}", file=sys.stderr)

    if not args.no_build:
        for name, cwd in conan_dirs:
            opts = get_conan_opts(name, profile, args, base)
            build(cwd, opts)


if __name__ == "__main__":
    main()

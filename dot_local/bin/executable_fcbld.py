#!/usr/bin/env python3

import os
import subprocess
import sys
from pathlib import Path

# Repository definitions: (name, git_url, conan_subpath, build_during_configure)
# - conan_subpath: subpath containing Conan package (or None if repo is sync-only)
# - build_during_configure: if True, run `conan build` instead of `conan build -c user.fc:configure_only=y`
REPOS = [
    ("build", "https://github.com/FairCom-Official/build.git", None, False),
    ("thirdparty", "https://github.com/FairCom-Official/thirdparty.git", None, False),
    ("conan-utils", "https://github.com/FairCom-Official/fairCom-conan-utils.git", None, False),
    ("kernel", "https://github.com/FairCom-Official/faircom-kernel.git", "make", True),
    ("util", "https://github.com/FairCom-Official/faircom-utility.git", "make", True),
    ("plugin", "https://github.com/FairCom-Official/faircom-plugin.git", "make", False),
    ("java", "https://github.com/FairCom-Official/faircom-java.git", "make", False),
    ("dotnet", "https://github.com/FairCom-Official/faircom-dotnet.git", "make", False),
    ("webtools", "https://github.com/FairCom-Official/faircom-webtools.git", "make", False),
    ("packager", "https://github.com/FairCom-Official/faircom-packager.git", "FairComEdge", False),
]


def setup_environment(base):
    deps_dir = base / "deps"
    if deps_dir.is_dir():
        jdk_dirs = [d for d in deps_dir.glob("jdk-*") if d.is_dir() and not d.name.endswith(".tar.gz")]
        if jdk_dirs:
            jdk_home = str(sorted(jdk_dirs)[0])
            os.environ["JAVA_HOME"] = jdk_home
            print(f"Set JAVA_HOME={jdk_home}", flush=True)

        dotnet_dir = deps_dir / "dotnet"
        if dotnet_dir.is_dir():
            os.environ["PATH"] = f"{dotnet_dir}:{os.environ.get('PATH', '')}"
            print(f"Added {dotnet_dir} to PATH", flush=True)


def run(cmd, cwd):
    print(f"[{cwd}] $ {' '.join(cmd)}", flush=True)
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        print(f"ERROR: command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)


def sync_repos(base):
    for name, url, _, _ in REPOS:
        repo_path = base / name
        if repo_path.is_dir():
            print(f"==> Pulling {name}", flush=True)
            run(["git", "pull"], cwd=repo_path)
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
    if profile:
        return [f"-pr:a={profile}"]

    build_dir = str((args.build_dir or (Path.cwd() / "builds")).resolve())
    install_dir = str((args.install_dir or (Path.cwd() / "packages")).resolve())
    unicode_val = "1" if args.unicode else "0"

    opts = [
        "-s", f"build_type={args.build_type}",
        "-c", f"user.fc:build_dir={build_dir}",
        "-c", f"user.fc:install_dir={install_dir}",
    ]

    if sys.platform != "win32":
        opts.extend([
            "-s", "compiler=gcc",
            "-s", "compiler.version=4.8",
            "-s", "compiler.cppstd=11",
            "-s", "compiler.libcxx=libstdc++",
            "-s", "arch=x86_64",
            "-s", "os=Linux",
        ])

    if name == "kernel":
        opts.extend([
            "-o", f"&:oem={args.oem}",
            "-o", f"&:product_type={args.product}",
            "-o", f"&:unicode={unicode_val}",
        ])
    else:
        opts.extend([
            "-o", f"faircom_kernel/*:oem={args.oem}",
            "-o", f"faircom_kernel/*:product_type={args.product}",
            "-o", f"faircom_kernel/*:unicode={unicode_val}",
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
    import argparse
    usage_text = (
        "%(prog)s [-b BASE_DIR] [--no-sync] [--no-build] [--msbuild] --profile PROFILE\n"
        "       %(prog)s [-b BASE_DIR] [--no-sync] [--no-build] [--msbuild] [--oem OEM]\n"
        "              [--product PRODUCT] [--unicode] [--build-type BUILD_TYPE]\n"
        "              [--build-dir BUILD_DIR] [--install-dir INSTALL_DIR]"
    )
    parser = argparse.ArgumentParser(
        usage=usage_text,
        description="Install, configure, and optionally build all FairCom components."
    )
    
    general_group = parser.add_argument_group("General options")
    default_base = Path("D:/_") if sys.platform == "win32" else Path("~/_").expanduser()
    general_group.add_argument("--base-dir", "-b", type=Path, default=default_base, help="Base directory for repositories (default: D:\\_ on Windows, ~/_ on Linux/macOS).")
    general_group.add_argument("--no-sync", "--skip-sync", action="store_true", help="Skip syncing (git clone/pull) repositories.")
    general_group.add_argument("--no-build", "--skip-build", action="store_true", help="Skip running conan build (full compilation) after configure.")
    general_group.add_argument("--msbuild", action="store_true", help="Run msbuild on the generated solution after configure (Windows only).")

    profile_group = parser.add_argument_group("Profile mode")
    profile_group.add_argument("--profile", "-p", "-pr", default=None, help="Conan profile to use (e.g. prod/edge-debug).")

    direct_group = parser.add_argument_group("Direct build mode (mutually exclusive with --profile)")
    direct_group.add_argument("--oem", default=None, help="OEM option (default: edge).")
    direct_group.add_argument("--product", "--product-type", default=None, help="Product type option (default: edge).")
    direct_group.add_argument("--unicode", action="store_true", default=None, help="Enable unicode build (default: False/0).")
    direct_group.add_argument("--build-type", default=None, help="Build type (default: Debug).")
    direct_group.add_argument("--build-dir", type=Path, default=None, help="Build output directory (default: ./builds).")
    direct_group.add_argument("--install-dir", type=Path, default=None, help="Install output directory (default: ./packages).")
    args = parser.parse_args()

    direct_opts_specified = [
        opt for opt in ["oem", "product", "unicode", "build_type", "build_dir", "install_dir"]
        if getattr(args, opt) is not None
    ]
    if args.profile and direct_opts_specified:
        opt_names = ", ".join("--" + opt.replace("_", "-") for opt in direct_opts_specified)
        parser.error(f"--profile (-p/-pr) cannot be used together with direct build options: {opt_names}")

    # Set default values when direct build options are used
    if args.oem is None:
        args.oem = "edge"
    if args.product is None:
        args.product = "edge"
    if args.unicode is None:
        args.unicode = False
    if args.build_type is None:
        args.build_type = "Debug"

    profile = args.profile
    if profile and "/" not in profile and "\\" not in profile:
        profile = f"prod/{profile}"

    base = args.base_dir.expanduser().resolve()
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

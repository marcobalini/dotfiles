#!/usr/bin/env bash

# --- Argument Validation & Initialization ---
UPLOAD=false
PKG_TYPE=rpm
while [[ "$1" == -* ]]; do
    case "$1" in
        -u|--upload) UPLOAD=true; shift ;;
        --rpm) PKG_TYPE=rpm; shift ;;
        --deb) PKG_TYPE=deb; shift ;;
        --deb32) PKG_TYPE=deb32; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -z "$1" ] && echo "usage: $0 [-u|--upload] [--rpm|--deb|--deb32] tarball [scripts_repo]" && exit 1
TARBALL="$1"
SCRIPTS_REPO="${2:-$HOME/_/utility}"

WORKDIR=$(realpath "${WORKDIR:-.}")

cd "$WORKDIR" || exit 1

# --- Helper Functions ---

prep_scripts() {
    cp -u "$SCRIPTS_REPO"/packaging/package/faircom.service "$WORKDIR/"
    cp -u "$SCRIPTS_REPO"/packaging/package/build-faircom-pkg.sh "$WORKDIR/"
    cp -u "$SCRIPTS_REPO"/packaging/package/upload-faircom-pkg.sh "$WORKDIR/"
    if [ "$PKG_TYPE" = "rpm" ]; then
        cp -u "$SCRIPTS_REPO"/packaging/package/faircom.spec "$WORKDIR/"
        sed -i 's/# addFilter("W: unstripped-binary-or-object")/addFilter("W: unstripped-binary-or-object")/' "$WORKDIR/build-faircom-pkg.sh"
        sed -i 's/# addFilter("E: call-to-mktemp")/addFilter("E: call-to-mktemp")/' "$WORKDIR/build-faircom-pkg.sh"
    fi
}

build_pkg() {
    docker run -u "$(id -u):$(id -g)" --rm -it -v "$WORKDIR:/tmp/faircompkg:Z" "faircom${PKG_TYPE}" bash -c "LC_ALL=C /tmp/faircompkg/build-faircom-pkg.sh /tmp/faircompkg/$TARBALL"
}

# --- Main Execution Flow ---

prep_scripts

touch "$WORKDIR/.pkg_build_start"

PKG_EXT="${PKG_TYPE//32/}"  # deb32 → deb
PKG_OUTDIR="$WORKDIR/$(dirname "$TARBALL")"

if build_pkg; then
    if [ "$UPLOAD" = true ]; then
        for pkg_file in "$PKG_OUTDIR"/*."$PKG_EXT"; do
            [ -e "$pkg_file" ] || continue
            [ "$pkg_file" -nt "$WORKDIR/.pkg_build_start" ] || continue
            echo "Uploading: $(basename "$pkg_file")"
            "$WORKDIR/upload-faircom-pkg.sh" "$pkg_file"
        done
    else
        echo "Build succeeded. Skipping upload (use -u or --upload to upload)."
    fi
fi

rm -f "$WORKDIR/.pkg_build_start"

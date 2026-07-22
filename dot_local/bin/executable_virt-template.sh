#!/usr/bin/env bash

# Exit immediately if any command fails
set -e

# --- USAGE ---
usage() {
    echo "Usage: $0 <name>"
    echo ""
    echo "  <name>   Template identifier in the form: <distro>-<version>-<arch>"
    echo "           Example: debian-12-i386"
    echo ""
    echo "Supported distros and versions:"
    echo "  debian-12-i386   (bookworm)"
    echo "  debian-13-i386   (trixie)"
    exit 1
}

[ -z "$1" ] && usage
[[ "$1" == "-h" || "$1" == "--help" ]] && usage

NAME="$1"

# --- PARSE NAME ---
# Expected format: <distro>-<version>-<arch>  (e.g. debian-12-i386)
DISTRO=$(echo "$NAME" | cut -d- -f1)
VERSION=$(echo "$NAME" | cut -d- -f2)
DEB_ARCH=$(echo "$NAME" | cut -d- -f3)

if [ -z "$DISTRO" ] || [ -z "$VERSION" ] || [ -z "$DEB_ARCH" ]; then
    echo "ERROR: Could not parse name '$NAME'. Expected format: distro-version-arch"
    usage
fi

# --- DISTRO VALIDATION ---
if [ "$DISTRO" != "debian" ]; then
    echo "ERROR: Only 'debian' is supported at this time."
    exit 1
fi

# --- VERSION → CODENAME MAPPING ---
declare -A CODENAMES=(
    [12]="bookworm"
    [13]="trixie"
)

CODENAME="${CODENAMES[$VERSION]}"
if [ -z "$CODENAME" ]; then
    echo "ERROR: Unsupported Debian version '$VERSION'. Supported: ${!CODENAMES[*]}"
    exit 1
fi

# --- ARCH MAPPING (distro naming → QEMU arch) ---
declare -A ARCH_MAP=(
    [i386]="i686"
)

QEMU_ARCH="${ARCH_MAP[$DEB_ARCH]}"
if [ -z "$QEMU_ARCH" ]; then
    echo "ERROR: Unsupported architecture '$DEB_ARCH'. Supported: ${!ARCH_MAP[*]}"
    exit 1
fi

# --- DERIVED VALUES ---
DISK_FILE="$NAME.qcow2"
TEMPLATE_DIR="/opt/virt-templates"
INDEX_FILE="$TEMPLATE_DIR/index"
INSTALLER_URL="http://deb.debian.org/debian/dists/${CODENAME}/main/installer-${DEB_ARCH}/"
FRIENDLY_NAME="Debian ${VERSION} ${CODENAME^} (${DEB_ARCH})"

echo "--- Template: $NAME ---"
echo "    Distro:    $DISTRO"
echo "    Version:   $VERSION ($CODENAME)"
echo "    Arch:      $DEB_ARCH (QEMU: $QEMU_ARCH)"
echo "    Installer: $INSTALLER_URL"
echo ""

# --- GENERATE PRESEED ---
PRESEED_FILE=$(mktemp /tmp/preseed.XXXXXX.cfg)
trap 'rm -f "$PRESEED_FILE"' EXIT

cat > "$PRESEED_FILE" <<'PRESEED'
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us

d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string unassigned-hostname
d-i netcfg/get_domain string unassigned-domain

d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i passwd/root-password password YourSecurePassword
d-i passwd/root-password-again password YourSecurePassword
d-i passwd/make-user boolean false

d-i clock-setup/utc boolean true
d-i time/zone string UTC

d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string curl
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string default

d-i finish-install/reboot_in_progress note
PRESEED

# --- CLEAN UP PREVIOUS ATTEMPT ---
[ -f "$DISK_FILE" ] && rm -f "$DISK_FILE"
virsh undefine "$NAME" --remove-all-storage 2>/dev/null || true

# --- OS INSTALLATION ---
echo "--- Starting non-interactive OS installation ---"
virt-install \
  --name "$NAME" \
  --ram 1024 \
  --vcpus 1 \
  --arch "$QEMU_ARCH" \
  --disk path="$DISK_FILE",size=10,format=qcow2 \
  --location "$INSTALLER_URL" \
  --initrd-inject="$PRESEED_FILE" \
  --extra-args="auto=true priority=critical file=/$(basename "$PRESEED_FILE") console=ttyS0" \
  --nographics \
  --noreboot

# --- SYSPREP ---
echo "--- Cleaning and prepping image with virt-sysprep ---"
LIBGUESTFS_BACKEND=direct virt-sysprep -a "$DISK_FILE"

# Clean up the temporary libvirt XML definition
virsh undefine "$NAME"

# --- MOVE TO TEMPLATE REPOSITORY ---
echo "--- Moving template to local repository ---"
sudo mkdir -p "$TEMPLATE_DIR"
sudo mv "$DISK_FILE" "$TEMPLATE_DIR/"

# --- CALCULATE HASHES AND SIZES ---
echo "--- Calculating hashes and sizes ---"
HASH=$(sha256sum "$TEMPLATE_DIR/$DISK_FILE" | awk '{print $1}')
RAW_SIZE=$(qemu-img info "$TEMPLATE_DIR/$DISK_FILE" | grep "virtual size" | grep -oP '\(\K\d+')
# Subtract 50MB safety buffer to outsmart virt-builder's rounding gate
SIZE=$((RAW_SIZE - 52428800))

# --- UPDATE INDEX (append or replace) ---
echo "--- Updating template index ---"

# Build the new entry
NEW_ENTRY="[$NAME]
name=$FRIENDLY_NAME
arch=$QEMU_ARCH
file=$DISK_FILE
checksum[sha256]=$HASH
format=qcow2
size=$SIZE
notes=Local custom ${DEB_ARCH} Debian template for automation script."

if [ -f "$INDEX_FILE" ]; then
    # Remove existing entry for this name (block from [name] to next [ or EOF)
    CLEANED=$(awk -v name="[$NAME]" '
        BEGIN { skip=0 }
        /^\[/ { skip = ($0 == name) ? 1 : 0 }
        !skip { print }
    ' "$INDEX_FILE")
    # Write cleaned content + new entry (strip trailing blank lines, add one separator)
    echo "$CLEANED" | sed -e '/^$/{ :a; N; /^\n*$/ba; }' | sudo tee "$INDEX_FILE" > /dev/null
    # Ensure a blank line separator if file is not empty
    if [ -s "$INDEX_FILE" ]; then
        echo "" | sudo tee -a "$INDEX_FILE" > /dev/null
    fi
    echo "$NEW_ENTRY" | sudo tee -a "$INDEX_FILE" > /dev/null
else
    echo "$NEW_ENTRY" | sudo tee "$INDEX_FILE" > /dev/null
fi

echo ""
echo "--- Done! Template '$NAME' is ready for virt-builder ---"
echo "    Index: $INDEX_FILE"
echo "    Disk:  $TEMPLATE_DIR/$DISK_FILE"

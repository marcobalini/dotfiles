#!/bin/bash

# --- OS DETECTION ---
OS=$(uname -s)
if [ "$OS" = "Linux" ]; then
    BACKEND="libvirt"
elif [ "$OS" = "Darwin" ]; then
    BACKEND="tart"
else
    echo "ERROR: Unsupported OS: $OS"
    exit 1
fi

# --- CONFIGURATION ---
USER_NAME="fctech"
DISTRO="fedora-42"  # Default distro for Linux, will map appropriately for macOS
[ "$BACKEND" = "tart" ] && DISTRO="fedora" # Tart fallback
PKGS_DIR="."
# Auto-detect SSH private key (tries common key types in order)
SSH_KEY_PRIV=""
for _k in id_ed25519 id_ecdsa id_rsa; do
    if [ -f "$HOME/.ssh/$_k" ]; then SSH_KEY_PRIV="$HOME/.ssh/$_k"; break; fi
done
SSH_KEY="${SSH_KEY_PRIV}.pub"   # Public key used for VM injection

if [ "$BACKEND" = "libvirt" ]; then
    SNAPSHOT_NAME="clean-base"
elif [ "$BACKEND" = "tart" ]; then
    BASE_SUFFIX="-base"          # Suffix for the clean-base clone (replaces virsh snapshots)
    TART_REGISTRY="ghcr.io/cirruslabs"
fi

DEFAULT_PASS="faircom"

# --- NETWORK/BOOT TIMING CONFIG (override via env) ---
IP_WAIT_RETRIES="${IP_WAIT_RETRIES:-20}"      # 20 * 2s = 40s
IP_WAIT_SLEEP_SECS="${IP_WAIT_SLEEP_SECS:-2}"

# --- REPO CONFIG (override via environment variables) ---
REPO_BASE_URL="${REPO_BASE_URL:-http://vmftest.eu.faircom.com:8081/repository}"
RPM_REPO_PATH="${RPM_REPO_PATH:-faircom-rpm}"
RPM_REPO_ID="${RPM_REPO_ID:-faircom-rpm}"
RPM_REPO_NAME="${RPM_REPO_NAME:-FairCom Internal RPM Repository}"

DEB_REPO_CURRENT_PATH="${DEB_REPO_CURRENT_PATH:-faircom-deb-current}"
DEB_REPO_LEGACY_PATH="${DEB_REPO_LEGACY_PATH:-faircom-deb-legacy}"
DEB_SUITE_CURRENT="${DEB_SUITE_CURRENT:-current}"
DEB_SUITE_LEGACY="${DEB_SUITE_LEGACY:-legacy}"

KEYS_REPO_PATH="${KEYS_REPO_PATH:-faircom-keys}"
KEYS_FILE_NAME="${KEYS_FILE_NAME:-faircom-packages.gpg.pub}"

# --- USAGE MENU ---
usage() {
    echo "Usage: $0 [OPTIONS] [distro]"
    echo "  (no flags)   Start VM, SSH into it, and STOP on exit"
    echo "  -r           Restore to clean base, SSH, and STOP on exit"
    echo "  -b           Build/Configure the VM from scratch (Prompts for password)"
    echo "  -s           Sync pkgs to existing VM (Requires restart)"
    echo "  -a <pkg>     Auto-install <pkg> (Restores, Syncs, Installs, and Exits)"
    echo "  -d <dir>     Directory containing packages (default: current directory)"
    echo "  -e           Enable internal faircom repo setup during VM build (Linux only)"
    echo "  -32          Build/test 32-bit VM (Linux only, sets architecture to i686)"
    echo "  -m <arch>    CPU architecture (default: x86_64, e.g., i686, Linux only)"
    echo "  -l           List all ${USER_NAME} VMs and their state (Linux only)"
    echo "  -x           Remove VM completely (destroy/undefine/delete disk on Linux, delete base on Tart)"
    echo "  -h           Show this help menu"
    echo ""
    echo "  [distro]     Optional distro name (default: $DISTRO)"
    if [ "$BACKEND" = "tart" ]; then
        echo "               Supported: ubuntu, ubuntu:22.04, ubuntu:24.04, fedora, debian"
    fi
    exit 1
}

# SSH setup definitions
_SSH_ID_ARGS=(); [ -n "$SSH_KEY_PRIV" ] && _SSH_ID_ARGS=(-i "$SSH_KEY_PRIV")
vm_ssh() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "${_SSH_ID_ARGS[@]}" -q "$@"
}
vm_scp() {
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "${_SSH_ID_ARGS[@]}" -q "$@"
}

# --- DEPENDENCY CHECK ---
if [ "$BACKEND" = "libvirt" ]; then
    if ! command -v virt-builder &>/dev/null; then
        echo "ERROR: 'virt-builder' not found."
        exit 1
    fi
elif [ "$BACKEND" = "tart" ]; then
    if ! command -v tart &>/dev/null; then
        echo "ERROR: 'tart' not found. Install it with:"
        echo "  brew install cirruslabs/cli/tart"
        exit 1
    fi
    if ! command -v scp &>/dev/null; then
        echo "ERROR: 'scp' not found. Install OpenSSH."
        exit 1
    fi
fi

# --- FLAG HANDLING ---
BUILD_VM=false
SYNC_ONLY=false
RESTORE_VM=false
REMOVE_VM=false
LIST_VMS=false
ENABLE_REPO_SETUP=false
AUTO_INSTALL_PKG=""
ARCH="x86_64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b) BUILD_VM=true; shift ;;
    -r) RESTORE_VM=true; shift ;;
    -s) SYNC_ONLY=true; shift ;;
    -a) AUTO_INSTALL_PKG="$2"; RESTORE_VM=true; SYNC_ONLY=true; shift 2 ;;
    -d) PKGS_DIR="$2"; shift 2 ;;
    -e) ENABLE_REPO_SETUP=true; shift ;;
    -32) ARCH="i686"; shift ;;
    -m|--arch) ARCH="$2"; shift 2 ;;
    -l) LIST_VMS=true; shift ;;
    -x) REMOVE_VM=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) DISTRO="$1"; shift ;;
  esac
done

# --- POST-FLAG CONFIGURATION ---
if [ "$BACKEND" = "libvirt" ]; then
    PKGS_DIR=$(realpath "$PKGS_DIR")
elif [ "$BACKEND" = "tart" ]; then
    PKGS_DIR=$(cd "$PKGS_DIR" && pwd)
    # SYNC_ONLY automatically implies RESTORE_VM in tart according to old script
    if [ "$SYNC_ONLY" = true ]; then RESTORE_VM=true; fi
fi
LOGS_DIR="$PKGS_DIR/logs"

# Dynamic naming
if [ "$BACKEND" = "libvirt" ]; then
    if [ "$ARCH" = "x86_64" ]; then
        VM_NAME="${DISTRO}-${USER_NAME}"
    else
        VM_NAME="${DISTRO}-${ARCH}-${USER_NAME}"
    fi
    DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
elif [ "$BACKEND" = "tart" ]; then
    DISTRO_TAG="${DISTRO/:/-}"
    DISTRO_TAG="${DISTRO_TAG//\//-}"
    VM_NAME="${DISTRO_TAG}-${USER_NAME}"
    BASE_VM="${VM_NAME}${BASE_SUFFIX}"

    if tart get "$DISTRO" &>/dev/null; then
        echo "--- Found local Tart VM '$DISTRO', using as base ---"
        OCI_IMAGE="$DISTRO"
    elif [[ "$DISTRO" != *"/"* ]]; then
        # Map version suffix (e.g. debian-12 -> debian:12 or debian:bookworm) to colon
        # for ghcr.io/cirruslabs images, which use tags, not distinct repos
        if [[ "$DISTRO" == *"-"* && "$DISTRO" != *":"* ]]; then
            # Replace the FIRST dash with a colon to construct the OCI image name
            OCI_IMAGE="${TART_REGISTRY}/${DISTRO/-/:}"
            
            # Special case mappings for debian versions
            if [[ "$OCI_IMAGE" == *"/debian:12" ]]; then
                OCI_IMAGE="${TART_REGISTRY}/debian:bookworm"
            elif [[ "$OCI_IMAGE" == *"/debian:13" ]]; then
                OCI_IMAGE="${TART_REGISTRY}/debian:trixie"
            elif [[ "$OCI_IMAGE" == *"/debian:11" ]]; then
                OCI_IMAGE="${TART_REGISTRY}/debian:bullseye"
            fi
        else
            OCI_IMAGE="${TART_REGISTRY}/${DISTRO}"
        fi
    else
        OCI_IMAGE="$DISTRO"
    fi
fi

# --- LIST VMs (early exit, no distro needed) ---
if [ "$LIST_VMS" = true ]; then
    if [ "$BACKEND" = "libvirt" ]; then
        echo "--- ${USER_NAME} VMs (libvirt) ---"
        sudo virsh list --all --name | grep -- "-${USER_NAME}" | while read -r name; do
            state=$(sudo virsh domstate "$name" 2>/dev/null)
            printf "  %-40s %s\n" "$name" "$state"
        done || true
    elif [ "$BACKEND" = "tart" ]; then
        echo "--- ${USER_NAME} VMs (tart) ---"
        tart list | grep -E "NAME.*SIZE|-fctech" || true
    fi
    exit 0
fi

# --- PASSWORD PROMPT (Only for Build) ---
if [ "$BUILD_VM" = true ]; then
    if [ "$BACKEND" = "libvirt" ]; then
        echo -n "Enter password for root and $USER_NAME [Default: $DEFAULT_PASS]: "
    else
        echo -n "Enter password for $USER_NAME [Default: $DEFAULT_PASS]: "
    fi
    read -s DUAL_PASS
    echo "" # New line after silent input
    if [ -z "$DUAL_PASS" ]; then
        DUAL_PASS="$DEFAULT_PASS"
        echo "--- Using default password ---"
    fi
fi

# --- OS INFO VARIANT DETECTION (Libvirt only) ---
if [ "$BACKEND" = "libvirt" ]; then
    if [[ "$DISTRO" == "ubuntu-"* ]]; then
        OS_VARIANT="${DISTRO//-/}"
    elif [[ "$DISTRO" == "debian-"* ]]; then
        # Extract only "debian{N}" — strip any arch suffix like -i386, -amd64
        OS_VARIANT="$(echo "$DISTRO" | grep -oP 'debian-\d+' | tr -d '-')"
    elif [[ "$DISTRO" == "fedora-"* ]]; then
        OS_VARIANT="fedora-unknown"
    elif [[ "$DISTRO" == "centos-"* ]]; then
        OS_VARIANT="${DISTRO//-/}"
        OS_VARIANT="${OS_VARIANT%%.*}"
    elif [[ "$DISTRO" == "centosstream-"* ]]; then
        OS_VARIANT="centos-stream${DISTRO#centosstream-}"
    elif [[ "$DISTRO" == "almalinux-"* ]]; then
        OS_VARIANT="${DISTRO//-/}"
        OS_VARIANT="${OS_VARIANT%%.*}"
    else
        OS_VARIANT="detect=on,require=off"
    fi
fi

# --- PACKAGE TYPE DETECTION ---
if [[ "$DISTRO" == *"fedora"* ]] || [[ "$DISTRO" == *"centos"* ]] || [[ "$DISTRO" == *"rhel"* ]] || [[ "$DISTRO" == *"alma"* ]]; then
    PKG_EXT="rpm"
    PKG_MANAGER="dnf"
    PKGLS_CMD="rpm -qpl"
elif [[ "$DISTRO" == *"ubuntu"* ]] || [[ "$DISTRO" == *"debian"* ]]; then
    PKG_EXT="deb"
    PKG_MANAGER="DEBIAN_FRONTEND=noninteractive apt-get"
    PKGLS_CMD="dpkg -c"
else
    PKG_EXT="unknown"
    PKG_MANAGER="echo"
    PKGLS_CMD="echo"
fi

# --- Helper scripts definition ---
DIRS="/etc/faircom /usr/share/faircom /var/lib/faircom /var/log/faircom /usr/libexec/faircom /usr/lib/faircom /usr/lib64/faircom /usr/bin"
IPKG_SCRIPT="/usr/local/bin/ipkg"
IDIFF_SCRIPT="/usr/local/bin/idiff"

IPKG_CONTENT=$(cat <<IPKGE
#!/bin/bash
if [ "$PKG_EXT" = "deb" ]; then
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo "Waiting for apt lock..." && sleep 5
    done
fi
p=\$(basename "\${1:-all}"); base=\${p%%.*}
log_name=\$(echo "\$base" | sed -E 's/[_-][0-9].*//')

# Function to capture tree state safely (only existing dirs)
capture_state() {
    local target="\$1"
    sudo rm -f "\$target"
    local valid=""
    for d in $DIRS; do [ -d "\$d" ] && valid+="\$d "; done
    if [ -n "\$valid" ]; then
        sudo tree -a -p -u -g -f -i --noreport \$valid > "\$target"
    else
        touch "\$target"
    fi
}

capture_state "/tmp/\$log_name.before"

# Resolve local file paths for apt/dnf
PKGS=()
if [ \$# -gt 0 ]; then
    for arg in "\$@"; do
        if [[ -f "/home/$USER_NAME/\$arg" ]] && [[ ! "\$arg" =~ / ]]; then
            PKGS+=("/home/$USER_NAME/\$arg")
        else
            PKGS+=("\$arg")
        fi
    done
else
    PKGS=(/home/$USER_NAME/*.$PKG_EXT)
fi

sudo $PKG_MANAGER install -y "\${PKGS[@]}"

# --- SMART SERVICE WAIT ---
echo "Waiting for service \$log_name to start..."
for i in {1..20}; do
    if systemctl is-active --quiet "\$log_name" 2>/dev/null; then
        echo "Service \$log_name is active."
        sleep 20 # Extra buffer for log writes and flushing
        break
    fi
    sleep 1
done

capture_state "/tmp/\$log_name.after"
diff -u "/tmp/\$log_name.before" "/tmp/\$log_name.after" > "/tmp/\$log_name.delta" || true
echo "Install complete. Delta saved to /tmp/\$log_name.delta"
IPKGE
)

IDIFF_CONTENT=$(cat <<IDIFFE
#!/bin/bash
p=\$(basename "\${1:-all}"); base=\${p%%.*}
log_name=\$(echo "\$base" | sed -E 's/[_-][0-9].*//')
sudo vimdiff -c "windo set nofoldenable" "/tmp/\$log_name.before" "/tmp/\$log_name.after"
IDIFFE
)

FC_ALIASES=$(cat <<ALIASES_EOF
alias fclog='sudo tail -f /var/log/faircom/CTSTATUS.FCS'
alias add32='sudo dpkg --add-architecture i386 && sudo apt-get update'
fcsta() { sudo systemctl start \$(systemctl list-unit-files --type=service --no-legend | grep '^faircom-' | awk '{print \$1}'); }
fcsto() { sudo systemctl stop \$(systemctl list-unit-files --type=service --no-legend | grep '^faircom-' | awk '{print \$1}'); }
ALIASES_EOF
)

# --- BACKEND SPECIFIC HELPERS ---

if [ "$BACKEND" = "tart" ]; then
    wait_for_ip() {
        echo -n "--- Waiting for IP "
        MAX_RETRIES="$IP_WAIT_RETRIES"; COUNT=0; VM_IP=""
        while [ -z "$VM_IP" ] && [ $COUNT -lt $MAX_RETRIES ]; do
            sleep "$IP_WAIT_SLEEP_SECS"
            VM_IP=$(tart ip "$VM_NAME" 2>/dev/null)
            if [ -z "$VM_IP" ]; then
                ((COUNT++))
                echo -n "."
            fi
        done
        echo ""
        if [ -z "$VM_IP" ]; then
            echo "ERROR: IP detection timed out."
            exit 1
        fi
        echo "--- VM IP: $VM_IP"
    }

    wait_for_ssh() {
        echo -n "--- Probing SSH Port "
        MAX_SSH_RETRIES=40
        SSH_COUNT=0
        while ! nc -z -w 1 "$VM_IP" 22 >/dev/null 2>&1 && [ $SSH_COUNT -lt $MAX_SSH_RETRIES ]; do
            echo -n "."
            sleep 2
            ((SSH_COUNT++))
        done
        if [ $SSH_COUNT -eq $MAX_SSH_RETRIES ]; then
            echo " FAILED!"
            echo "ERROR: SSH probing timed out."
            exit 1
        fi
        echo " Ready!"
    }

    start_vm_background() {
        local state
        state=$(tart list 2>/dev/null | awk -v vm="$VM_NAME" 'NR>1 && $1==vm {print $NF}')
        if [[ "$state" == "running" ]]; then
            echo "--- VM $VM_NAME is already running ---"
            return
        fi
        echo "--- Starting VM $VM_NAME (headless) ---"
        tart run "$VM_NAME" --no-graphics &>/tmp/tart-${VM_NAME}.log &
        disown $!
        sleep 3
    }
    
    stop_vm() {
        echo "--- Stopping VM $VM_NAME ---"
        tart stop "$VM_NAME" 2>/dev/null || true
    }

elif [ "$BACKEND" = "libvirt" ]; then
    # --- PERMISSION CHECK ---
    if ! groups | grep -q "libvirt"; then
        echo "WARNING: You are not in the 'libvirt' group. You may be prompted for your password."
        echo "To fix: sudo usermod -aG libvirt $USER"
        echo "       Then log out & back in, or run 'newgrp libvirt' in this terminal."
    fi

    # --- HOST FORWARDING SETUP (DOCKER CONFLICT WORKAROUND) ---
    BRIDGE_NAME=$(sudo virsh net-info default 2>/dev/null | grep -i "Bridge:" | awk '{print $2}')
    BRIDGE_NAME=${BRIDGE_NAME:-virbr0}
    if ! sudo iptables -C FORWARD -i "$BRIDGE_NAME" -j ACCEPT >/dev/null 2>&1; then
        echo "--- Host: Enabling VM bridge forwarding in iptables (Docker workaround) ---"
        sudo iptables -I FORWARD -i "$BRIDGE_NAME" -j ACCEPT
        sudo iptables -I FORWARD -o "$BRIDGE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    fi
    
    stop_vm() {
        echo "--- Stopping VM $VM_NAME ---"
        sudo virsh destroy "$VM_NAME" 2>/dev/null || true
    }
fi

# Function to inject files
inject_packages() {
    if [ "$PKG_EXT" = "unknown" ]; then return; fi
    if ls "$PKGS_DIR"/*."$PKG_EXT" >/dev/null 2>&1; then
        echo "--- Injecting *.$PKG_EXT ---"
        if [ "$BACKEND" = "libvirt" ]; then
            sudo virt-copy-in -a "$DISK_PATH" "$PKGS_DIR"/*."$PKG_EXT" /home/"$USER_NAME"/
        elif [ "$BACKEND" = "tart" ]; then
            vm_scp "$PKGS_DIR"/*."$PKG_EXT" "$USER_NAME@$VM_IP:/home/$USER_NAME/"
        fi
    fi
}


# --- LOGIC SELECTION ---

if [ "$REMOVE_VM" = true ]; then
    if [ "$BACKEND" = "libvirt" ]; then
        echo "--- [REMOVE] This will permanently delete $VM_NAME and its disk. ---"
        read -r -p "Are you sure? [y/N] " _confirm
        if [[ "$_confirm" =~ ^[Yy]$ ]]; then
            sudo virsh destroy "$VM_NAME" 2>/dev/null || true
            sudo virsh undefine "$VM_NAME" --remove-all-storage --snapshots-metadata 2>/dev/null \
                || { echo "Error: VM '$VM_NAME' not found."; exit 1; }
            echo "--- VM $VM_NAME removed. ---"
        else
            echo "Aborted."
        fi
        exit 0
    elif [ "$BACKEND" = "tart" ]; then
        echo "--- [REMOVE] This will permanently delete $VM_NAME and its base clone ($BASE_VM). ---"
        read -r -p "Are you sure? [y/N] " _confirm
        if [[ "$_confirm" =~ ^[Yy]$ ]]; then
            tart stop "$VM_NAME" 2>/dev/null || true
            tart delete "$VM_NAME" 2>/dev/null || { echo "Error: VM '$VM_NAME' not found."; exit 1; }
            tart delete "$BASE_VM" 2>/dev/null || true
            echo "--- VM $VM_NAME and $BASE_VM removed. ---"
        else
            echo "Aborted."
        fi
        exit 0
    fi
elif [ "$BUILD_VM" = true ]; then
    if [ "$BACKEND" = "libvirt" ]; then
        echo "--- [BUILD] Rebuilding $VM_NAME ---"
        sudo virsh destroy "$VM_NAME" 2>/dev/null
        sudo virsh undefine "$VM_NAME" --remove-all-storage --snapshots-metadata 2>/dev/null

        # --- BUILDER ARGUMENTS ---
        BUILDER_ARGS=(
            "--format" "qcow2" 
            "--output" "$DISK_PATH"
            "--hostname" "$VM_NAME" 
            "--network"
        )

        if ! virt-builder -l | grep -qw "^${DISTRO}"; then
            echo "--- ${DISTRO} not natively found, trying local templates... ---"
            LOCAL_ARCH=$(virt-builder -l --source "file:///opt/virt-templates/index" --no-check-signature 2>/dev/null | awk -v dist="$DISTRO" '$1 == dist {print $2}')
            BUILDER_ARGS+=("--source" "file:///opt/virt-templates/index" "--no-check-signature")
            if [ -n "$LOCAL_ARCH" ]; then
                ARCH="$LOCAL_ARCH"
                BUILDER_ARGS+=("--arch" "${LOCAL_ARCH}")
            elif [[ "${ARCH}" != "x86_64" ]]; then
                BUILDER_ARGS+=("--arch" "${ARCH}")
            fi
        fi

        if [[ "$DISTRO" == "centos-7"* ]] || [[ "$DISTRO" == "centos-8" ]] || [[ "$DISTRO" == "centosstream-8" ]]; then
            BUILDER_ARGS+=( "--run-command" "sed -i 's/^mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo" )
            BUILDER_ARGS+=( "--run-command" "sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo" )
        fi

        if [[ "$DISTRO" == "ubuntu-"* ]]; then
            BUILDER_ARGS+=( "--install" "cloud-guest-utils" )
            BUILDER_ARGS+=( "--firstboot-command" "growpart /dev/vda 2 || growpart /dev/sda 2 || true" )
            BUILDER_ARGS+=( "--firstboot-command" "growpart /dev/vda 5 || growpart /dev/sda 5 || true" )
            BUILDER_ARGS+=( "--firstboot-command" "resize2fs /dev/vda5 || resize2fs /dev/sda5 || true" )
            BUILDER_ARGS+=( "--run-command" "mkdir -p /etc/netplan && printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    virt_eth:\n      match:\n        name: e*\n      dhcp4: true\n' > /etc/netplan/99-dhcp.yaml" )
        else
            BUILDER_ARGS+=( "--size" "10G" )
        fi

        if [[ "$DISTRO" == "debian-"* ]]; then
            BUILDER_ARGS+=( "--firstboot-command" "IFACE=\$(ls /sys/class/net | grep -v lo | head -n1); if [ -n \"\$IFACE\" ]; then (echo auto \$IFACE; echo iface \$IFACE inet dhcp) > /etc/network/interfaces.d/auto && (ifup \$IFACE || systemctl restart networking); fi" )
        fi

        if [ "$PKG_EXT" = "rpm" ]; then
            if [[ "$DISTRO" == *"fedora"* ]]; then
                FVER="${DISTRO#fedora-}"
                if [ "$FVER" -ge 34 ] 2>/dev/null; then REPO_RELEASE="8"; elif [ "$FVER" -ge 28 ] 2>/dev/null; then REPO_RELEASE="8"; else REPO_RELEASE="7"; fi
            else
                DISTRO_VER=$(echo "$DISTRO" | grep -oP '\d+' | head -n1)
                if [ "${DISTRO_VER:-9}" -ge 9 ] 2>/dev/null; then REPO_RELEASE="8"; elif [ "${DISTRO_VER:-9}" -ge 8 ] 2>/dev/null; then REPO_RELEASE="8"; else REPO_RELEASE="7"; fi
            fi
            BUILDER_ARGS+=( "--run-command" "mkdir -p /etc/yum.repos.d/ && printf '[${RPM_REPO_ID}]\nname=${RPM_REPO_NAME}\nbaseurl=${REPO_BASE_URL}/${RPM_REPO_PATH}/el${REPO_RELEASE}/\$basearch/\nenabled=1\ngpgcheck=0\nskip_if_unavailable=1\n' > /etc/yum.repos.d/faircom.repo" )
        elif [ "$PKG_EXT" = "deb" ]; then
            if [[ "$DISTRO" == "ubuntu-"* ]]; then
                UBUNTU_MAJOR="${DISTRO#ubuntu-}"; UBUNTU_MAJOR="${UBUNTU_MAJOR%%.*}"
                if [ "$UBUNTU_MAJOR" -ge 20 ] 2>/dev/null && [ "$ARCH" != "i686" ]; then DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"; else DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"; fi
            elif [[ "$DISTRO" == "debian-"* ]]; then
                DEBIAN_VER="${DISTRO#debian-}"; DEBIAN_VER="${DEBIAN_VER%%-*}"
                if [ "$DEBIAN_VER" -ge 10 ] 2>/dev/null && [ "$ARCH" != "i686" ]; then DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"; else DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"; fi
            else
                if [ "$ARCH" = "i686" ]; then DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"; else DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"; fi
            fi
            # ARM override per repo policy: arm32 -> current, arm64 -> legacy.
            case "$ARCH" in
                aarch64|arm64)
                    DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"
                    ;;
                armhf|armv7l|arm)
                    DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"
                    ;;
            esac
            if [ "$ENABLE_REPO_SETUP" = "true" ]; then
                echo "--- Checking connection to $REPO_BASE_URL... ---"
                if ! curl -m 3 --silent --head "$REPO_BASE_URL" > /dev/null; then
                    echo "ERROR: -e flag used but repository $REPO_BASE_URL is unreachable."
                    exit 1
                else
                    case "$DEBIAN_VER" in 9) _DEB_ARCHIVE_CODENAME="stretch" ;; 10) _DEB_ARCHIVE_CODENAME="buster" ;; *) _DEB_ARCHIVE_CODENAME="" ;; esac
                    if [ -n "$_DEB_ARCHIVE_CODENAME" ]; then
                        BUILDER_ARGS+=( "--run-command" "set -e; printf '%s\n' 'Acquire::Check-Valid-Until \"false\";' 'Acquire::AllowInsecureRepositories \"true\";' 'Acquire::AllowDowngradeToInsecureRepositories \"true\";' > /etc/apt/apt.conf.d/99archive-no-valid-until; printf '%s\n' 'deb [trusted=yes] http://archive.debian.org/debian ${_DEB_ARCHIVE_CODENAME} main contrib non-free' 'deb [trusted=yes] http://archive.debian.org/debian-security ${_DEB_ARCHIVE_CODENAME}/updates main contrib non-free' > /etc/apt/sources.list; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated curl gnupg ca-certificates; mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d; curl -s '${REPO_BASE_URL}/${KEYS_REPO_PATH}/${KEYS_FILE_NAME}' | gpg --dearmor -o /etc/apt/trusted.gpg.d/faircom-packages.gpg; chmod 0644 /etc/apt/trusted.gpg.d/faircom-packages.gpg; _A=\"${ARCH}\"; [ \"\$_A\" = \"x86_64\" ] && _A=\"amd64\"; [ \"\$_A\" = \"i686\" ] && _A=\"i386\"; printf '%s\n' \"deb [arch=\$_A signed-by=/etc/apt/trusted.gpg.d/faircom-packages.gpg] ${REPO_BASE_URL}/${DEB_REPO_PATH} ${DEB_REPO_SUITE}\" > /etc/apt/sources.list.d/faircom.list; apt-get update" )
                    else
                        BUILDER_ARGS+=( "--run-command" "set -e; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg ca-certificates; mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d; curl -s '${REPO_BASE_URL}/${KEYS_REPO_PATH}/${KEYS_FILE_NAME}' | gpg --dearmor -o /etc/apt/trusted.gpg.d/faircom-packages.gpg; chmod 0644 /etc/apt/trusted.gpg.d/faircom-packages.gpg; _A=\"${ARCH}\"; [ \"\$_A\" = \"x86_64\" ] && _A=\"amd64\"; [ \"\$_A\" = \"i686\" ] && _A=\"i386\"; printf '%s\n' \"deb [arch=\$_A signed-by=/etc/apt/trusted.gpg.d/faircom-packages.gpg] ${REPO_BASE_URL}/${DEB_REPO_PATH} ${DEB_REPO_SUITE}\" > /etc/apt/sources.list.d/faircom.list; apt-get update" )
                    fi
                fi
            fi
        fi

        sudo virt-builder "$DISTRO" \
            "${BUILDER_ARGS[@]}" \
            --install qemu-guest-agent,openssh-server,tree,vim,sudo \
            --run-command "systemctl enable qemu-guest-agent" \
            --run-command "systemctl enable ssh || systemctl enable sshd" \
            --run-command "ssh-keygen -A" \
            --root-password password:"$DUAL_PASS" \
            --run-command "useradd -m -s /bin/bash -G wheel $USER_NAME || useradd -m -s /bin/bash $USER_NAME" \
            --run-command "echo '$USER_NAME:$DUAL_PASS' | chpasswd" \
            --run-command "mkdir -p /etc/sudoers.d/ && echo '$USER_NAME ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USER_NAME" \
            --write "$IPKG_SCRIPT:$IPKG_CONTENT" \
            --write "$IDIFF_SCRIPT:$IDIFF_CONTENT" \
            --run-command "chmod +x $IPKG_SCRIPT $IDIFF_SCRIPT" \
            --run-command "echo \"alias pkgls='$PKGLS_CMD'\" >> /home/$USER_NAME/.bashrc" \
            --write "/tmp/fc_aliases:$FC_ALIASES" \
            --run-command "cat /tmp/fc_aliases >> /home/$USER_NAME/.bashrc && rm /tmp/fc_aliases" \
            --ssh-inject "$USER_NAME:file:$SSH_KEY" \
            --selinux-relabel || { echo "ERROR: virt-builder failed."; exit 1; }
            
        if [[ "$DISTRO" == "ubuntu-"* ]]; then
            sudo qemu-img resize "$DISK_PATH" 10G
        fi

        inject_packages
        sudo virt-install \
            --name "$VM_NAME" \
            --arch "$ARCH" \
            --ram 2048 --vcpus 2 \
            --os-variant "$OS_VARIANT" \
            --import --disk path="$DISK_PATH",format=qcow2 \
            --network default \
            --graphics none \
            --noautoconsole || { echo "ERROR: virt-install failed."; exit 1; }
        
    elif [ "$BACKEND" = "tart" ]; then
        echo "--- [BUILD] Building $VM_NAME from $OCI_IMAGE ---"

        tart stop "$VM_NAME" 2>/dev/null || true
        tart delete "$VM_NAME" 2>/dev/null || true
        tart delete "$BASE_VM" 2>/dev/null || true

        echo "--- Pulling image $OCI_IMAGE ---"
        tart clone "$OCI_IMAGE" "$VM_NAME" || { echo "ERROR: tart clone failed."; exit 1; }

        CURRENT_DISK=$(tart get "$VM_NAME" 2>/dev/null | grep -i disk | awk '{print $2}' | sed 's/[^0-9]//g' || echo "0")
        if [ "${CURRENT_DISK:-0}" -lt 10 ] 2>/dev/null; then
            echo "--- Resizing disk to 10GB ---"
            tart set "$VM_NAME" --disk-size 10 2>/dev/null || true
        fi
        tart set "$VM_NAME" --memory 2048 --cpu 2 2>/dev/null || true

        start_vm_background
        wait_for_ip
        wait_for_ssh

        INIT_USER="admin"
        INIT_PASS="admin"

        echo "--- Configuring VM as $INIT_USER ---"

        if [ -f "$SSH_KEY" ]; then
            SSH_PUB_KEY=$(cat "$SSH_KEY")
        else
            echo "WARNING: SSH key not found at $SSH_KEY. Password auth only."
            SSH_PUB_KEY=""
        fi

        if ! command -v sshpass &>/dev/null; then
            echo "WARNING: 'sshpass' not found. Install with: brew install sshpass"
            SSH_INIT="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -q ${INIT_USER}@${VM_IP}"
        else
            SSH_INIT="sshpass -p ${INIT_PASS} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -q ${INIT_USER}@${VM_IP}"
        fi

        if [ "$ENABLE_REPO_SETUP" = "true" ]; then
            echo "--- Checking connection to $REPO_BASE_URL for -e repo setup... ---"
            if ! curl -m 5 --silent --head "$REPO_BASE_URL" >/dev/null; then
                echo "WARNING: Repository $REPO_BASE_URL is unreachable from host."
                echo "WARNING: VM build will continue, but FairCom repo setup may fail."
            fi
        fi

        echo "--- Creating user $USER_NAME ---"
        $SSH_INIT bash -s <<REMOTE_SETUP
set -e
if id "$USER_NAME" &>/dev/null; then
    echo "User $USER_NAME already exists."
else
    sudo useradd -m -s /bin/bash "$USER_NAME" 2>/dev/null || sudo adduser --disabled-password --gecos '' "$USER_NAME"
    echo "$USER_NAME:$DUAL_PASS" | sudo chpasswd
fi
if getent group wheel &>/dev/null; then
    sudo usermod -aG wheel "$USER_NAME"
elif getent group sudo &>/dev/null; then
    sudo usermod -aG sudo "$USER_NAME"
fi
sudo mkdir -p /etc/sudoers.d/
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER_NAME
sudo mkdir -p /home/$USER_NAME/.ssh
echo "$SSH_PUB_KEY" | sudo tee /home/$USER_NAME/.ssh/authorized_keys
sudo chmod 700 /home/$USER_NAME/.ssh
sudo chmod 600 /home/$USER_NAME/.ssh/authorized_keys
sudo chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.ssh

if command -v apt-get &>/dev/null; then
    sudo apt-get update 2>/dev/null || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tree vim sudo curl gnupg ca-certificates 2>/dev/null || true
elif command -v dnf &>/dev/null; then
$(if [[ "$DISTRO" == *"centos-8"* ]] || [[ "$DISTRO" == *"centosstream-8"* ]]; then
    echo "    sudo sed -i 's/^mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true"
    echo "    sudo sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true"
fi)
    sudo dnf install -y tree vim sudo curl gnupg ca-certificates 2>/dev/null || true
fi
sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd 2>/dev/null || true
sudo ssh-keygen -A 2>/dev/null || true
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

$(if [ "$PKG_EXT" = "rpm" ]; then
    if [[ "$DISTRO" == *"fedora"* ]]; then
        FVER="${DISTRO##*-}"; FVER="${DISTRO##*:}"
        if [ "$FVER" -ge 40 ] 2>/dev/null; then REPO_RELEASE="10"; elif [ "$FVER" -ge 34 ] 2>/dev/null; then REPO_RELEASE="9"; elif [ "$FVER" -ge 28 ] 2>/dev/null; then REPO_RELEASE="8"; else REPO_RELEASE="7"; fi
    else
        REPO_RELEASE="\\\$releasever"
    fi
    echo "sudo mkdir -p /etc/yum.repos.d/"
    echo "sudo bash -c \"printf '[faircom-rpm]\nname=FairCom Internal RPM Repository\nbaseurl=http://vmftest.eu.faircom.com:8081/repository/faircom-rpm/el${REPO_RELEASE}/\\\$basearch/\nenabled=1\ngpgcheck=0\nskip_if_unavailable=1\n' > /etc/yum.repos.d/faircom.repo\""
elif [ "$PKG_EXT" = "deb" ]; then
    if [[ "$DISTRO" == "ubuntu-"* ]]; then
        UBUNTU_MAJOR="${DISTRO#ubuntu-}"; UBUNTU_MAJOR="${UBUNTU_MAJOR%%.*}"
        if [ "$UBUNTU_MAJOR" -ge 20 ] 2>/dev/null && [ "$ARCH" != "i686" ]; then DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"; else DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"; fi
    elif [[ "$DISTRO" == "debian-"* ]]; then
        DEBIAN_VER="${DISTRO#debian-}"; DEBIAN_VER="${DEBIAN_VER%%-*}"
        if [ "$DEBIAN_VER" -ge 10 ] 2>/dev/null && [ "$ARCH" != "i686" ]; then DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"; else DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"; fi
    else
        if [ "$ARCH" = "i686" ]; then DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"; else DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"; fi
    fi
    if [ "$ENABLE_REPO_SETUP" = "true" ]; then
        echo "echo 'INFO: FairCom apt repo setup is handled post-bootstrap by host-side vm_ssh commands.'"
    fi
fi)
REMOTE_SETUP

        if [ "$ENABLE_REPO_SETUP" = "true" ] && [ "$PKG_EXT" = "deb" ]; then
            # Choose current vs legacy FairCom deb repo path.
            if [[ "$DISTRO" == "ubuntu-"* ]]; then
                UBUNTU_MAJOR="${DISTRO#ubuntu-}"; UBUNTU_MAJOR="${UBUNTU_MAJOR%%.*}"
                if [ "$UBUNTU_MAJOR" -ge 20 ] 2>/dev/null && [ "$ARCH" != "i686" ]; then
                    DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"
                else
                    DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"
                fi
            elif [[ "$DISTRO" == "debian-"* ]]; then
                DEBIAN_VER="${DISTRO#debian-}"; DEBIAN_VER="${DEBIAN_VER%%-*}"
                if [ "$DEBIAN_VER" -ge 10 ] 2>/dev/null && [ "$ARCH" != "i686" ]; then
                    DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"
                else
                    DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"
                fi
            else
                if [ "$ARCH" = "i686" ]; then
                    DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"
                else
                    DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"
                fi
            fi

            # ARM override per repo policy (based on actual VM arch): arm32 -> current, arm64 -> legacy.
            VM_ARCH=$(vm_ssh "$USER_NAME@$VM_IP" "uname -m" 2>/dev/null | tr -d '\r')
            case "$VM_ARCH" in
                aarch64|arm64)
                    DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"
                    ;;
                armv7l|armv6l|armhf|arm)
                    DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"
                    ;;
            esac

            echo "--- Applying FairCom apt repo inside VM (-e) ---"
            cat <<EOF | vm_ssh "$USER_NAME@$VM_IP" "bash -s"
set -e
if [ "$DEBIAN_VER" = "9" ] || [ "$DEBIAN_VER" = "10" ]; then
    _DEB_ARCHIVE_CODENAME=""
    [ "$DEBIAN_VER" = "9" ] && _DEB_ARCHIVE_CODENAME="stretch"
    [ "$DEBIAN_VER" = "10" ] && _DEB_ARCHIVE_CODENAME="buster"
    printf '%s\n' 'Acquire::Check-Valid-Until "false";' 'Acquire::AllowInsecureRepositories "true";' 'Acquire::AllowDowngradeToInsecureRepositories "true";' | sudo tee /etc/apt/apt.conf.d/99archive-no-valid-until >/dev/null
    printf '%s\n' "deb [trusted=yes] http://archive.debian.org/debian \\$_DEB_ARCHIVE_CODENAME main contrib non-free" "deb [trusted=yes] http://archive.debian.org/debian-security \\$_DEB_ARCHIVE_CODENAME/updates main contrib non-free" | sudo tee /etc/apt/sources.list >/dev/null
fi
sudo mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d
if ! curl -fsSL "${REPO_BASE_URL}/${KEYS_REPO_PATH}/${KEYS_FILE_NAME}" | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/faircom-packages.gpg; then
    echo "WARNING: Failed to fetch/dearmor FairCom repo key from ${REPO_BASE_URL}. Repo setup skipped." >&2
    exit 0
fi
sudo chmod 0644 /etc/apt/trusted.gpg.d/faircom-packages.gpg
_A="$(dpkg --print-architecture 2>/dev/null || uname -m)"
[ "\$_A" = "x86_64" ] && _A="amd64"
[ "\$_A" = "aarch64" ] && _A="arm64"
[ "\$_A" = "i686" ] && _A="i386"
[ -z "\$_A" ] && _A="amd64"

echo "deb [arch=\$_A signed-by=/etc/apt/trusted.gpg.d/faircom-packages.gpg] ${REPO_BASE_URL}/${DEB_REPO_PATH} ${DEB_REPO_SUITE}" | sudo tee /etc/apt/sources.list.d/faircom.list >/dev/null
if [ ! -s /etc/apt/sources.list.d/faircom.list ]; then
    echo "WARNING: faircom.list is empty after write." >&2
fi
if ! sudo apt-get update; then
    echo "WARNING: apt-get update failed after adding FairCom repo. Check ${REPO_BASE_URL}." >&2
fi
EOF
        fi

        if [ "$ENABLE_REPO_SETUP" = "true" ] && [ "$PKG_EXT" = "deb" ]; then
            if ! vm_ssh "$USER_NAME@$VM_IP" "test -s /etc/apt/sources.list.d/faircom.list"; then
                echo "WARNING: -e requested, but /etc/apt/sources.list.d/faircom.list is missing or empty in VM."
                echo "WARNING: Verify connectivity to $REPO_BASE_URL and key URL ${REPO_BASE_URL}/${KEYS_REPO_PATH}/${KEYS_FILE_NAME}."
            fi
        fi

        echo "--- Writing helper scripts ---"
        echo "$IPKG_CONTENT"  | vm_ssh "$USER_NAME@$VM_IP" "sudo tee $IPKG_SCRIPT > /dev/null && sudo chmod +x $IPKG_SCRIPT"
        echo "$IDIFF_CONTENT" | vm_ssh "$USER_NAME@$VM_IP" "sudo tee $IDIFF_SCRIPT > /dev/null && sudo chmod +x $IDIFF_SCRIPT"
        echo "--- Writing .bashrc aliases ---"
        vm_ssh "$USER_NAME@$VM_IP" "echo \"alias pkgls='$PKGLS_CMD'\" >> ~/.bashrc"
        echo "$FC_ALIASES" | vm_ssh "$USER_NAME@$VM_IP" "cat >> ~/.bashrc"

        inject_packages

        # Tart stop is abrupt; flush filesystem buffers to persist recent writes.
        vm_ssh "$USER_NAME@$VM_IP" "sudo sync" || true

        stop_vm

        echo "--- Saving clean-base clone as $BASE_VM ---"
        tart clone "$VM_NAME" "$BASE_VM" || { echo "ERROR: Failed to create base clone."; exit 1; }

        echo "--- [BUILD COMPLETE] VM: $VM_NAME  |  Base clone: $BASE_VM ---"
        echo "    Run without flags to SSH in."
        exit 0
    fi
elif [ "$SYNC_ONLY" = true ]; then
    if [ "$BACKEND" = "libvirt" ]; then
        echo "--- [SYNC] Restoring base and updating packages ---"
        sudo virsh destroy "$VM_NAME" 2>/dev/null
        sudo virsh snapshot-revert "$VM_NAME" "$SNAPSHOT_NAME" 2>/dev/null || { echo "Error: Snapshot not found."; exit 1; }
        sudo virsh start "$VM_NAME" 2>/dev/null || true
        sudo virsh resume "$VM_NAME" 2>/dev/null || true
    elif [ "$BACKEND" = "tart" ]; then
        echo "--- [SYNC] Reverting $VM_NAME to $BASE_VM and updating packages ---"
        if ! tart get "$BASE_VM" &>/dev/null; then echo "ERROR: Base clone '$BASE_VM' not found. Run -b first."; exit 1; fi
        tart stop "$VM_NAME" 2>/dev/null || true
        tart delete "$VM_NAME" 2>/dev/null || true
        tart clone "$BASE_VM" "$VM_NAME" || { echo "ERROR: Failed to restore from base clone."; exit 1; }
        echo "--- Restore complete ---"
    fi
elif [ "$RESTORE_VM" = true ]; then
    if [ "$BACKEND" = "libvirt" ]; then
        echo "--- [RESTORE] Reverting to $SNAPSHOT_NAME ---"
        sudo virsh destroy "$VM_NAME" 2>/dev/null
        sudo virsh snapshot-revert "$VM_NAME" "$SNAPSHOT_NAME" 2>/dev/null || { echo "Error: Snapshot not found."; exit 1; }
        sudo virsh start "$VM_NAME" 2>/dev/null || true
        sudo virsh resume "$VM_NAME" 2>/dev/null || true
    elif [ "$BACKEND" = "tart" ]; then
        echo "--- [RESTORE] Reverting $VM_NAME to $BASE_VM ---"
        if ! tart get "$BASE_VM" &>/dev/null; then echo "ERROR: Base clone '$BASE_VM' not found. Run -b first."; exit 1; fi
        tart stop "$VM_NAME" 2>/dev/null || true
        tart delete "$VM_NAME" 2>/dev/null || true
        tart clone "$BASE_VM" "$VM_NAME" || { echo "ERROR: Failed to restore from base clone."; exit 1; }
        echo "--- Restore complete ---"
    fi
else
    echo "--- [START] Starting existing VM $VM_NAME ---"
    if [ "$BACKEND" = "libvirt" ]; then
        VM_STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null)
        if [ "$VM_STATE" != "running" ]; then
            sudo virsh start "$VM_NAME" 2>/dev/null || { echo "Error: VM not found. Run -b first."; exit 1; }
        fi
    elif [ "$BACKEND" = "tart" ]; then
        if ! tart get "$VM_NAME" &>/dev/null; then echo "ERROR: VM '$VM_NAME' not found. Run -b first."; exit 1; fi
    fi
fi

# --- START AND CONNECT WAIT---
if [ "$BACKEND" = "libvirt" ]; then
    echo -n "--- Waiting for IP "
    MAX_RETRIES="$IP_WAIT_RETRIES"; COUNT=0; VM_IP=""
    VM_MAC=$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | grep -iE '[0-9a-f]{2}(:[0-9a-f]{2}){5}' -o | head -n1)

    while [ -z "$VM_IP" ] && [ $COUNT -lt $MAX_RETRIES ]; do
        sleep "$IP_WAIT_SLEEP_SECS"
        if [ -z "$VM_MAC" ]; then
            VM_MAC=$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | grep -iE '[0-9a-f]{2}(:[0-9a-f]{2}){5}' -o | head -n1)
        fi

        VM_IP=$(sudo virsh domifaddr "$VM_NAME" --source agent 2>/dev/null | grep ipv4 | grep -v "127.0.0.1" | awk '{print $4}' | cut -d/ -f1 | head -n1)
        if [ -z "$VM_IP" ]; then VM_IP=$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null | grep ipv4 | grep -v "127.0.0.1" | awk '{print $4}' | cut -d/ -f1 | head -n1); fi
        if [ -z "$VM_IP" ] && [ -n "$VM_MAC" ]; then VM_IP=$(sudo virsh net-dhcp-leases default 2>/dev/null | grep -i "$VM_MAC" | awk '{print $5}' | grep -v "127.0.0.1" | cut -d/ -f1 | head -n1); fi

        if [ -z "$VM_IP" ] && [ $COUNT -eq $((MAX_RETRIES / 2)) ]; then
            sudo virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-exec","arguments":{"path":"/bin/sh","arg":["-lc","systemctl start qemu-guest-agent || service qemu-guest-agent start || true"],"capture-output":true}}' >/dev/null 2>&1 || true
        fi
        if [ -z "$VM_IP" ]; then ((COUNT++)); echo -n "."; fi
    done
    echo ""

    if [ -n "$VM_IP" ]; then
        echo -n "--- Probing SSH Port "
        MAX_SSH_RETRIES=30; SSH_COUNT=0
        while ! nc -z -w 1 "$VM_IP" 22 >/dev/null 2>&1 && [ $SSH_COUNT -lt $MAX_SSH_RETRIES ]; do echo -n "."; sleep 2; ((SSH_COUNT++)); done
        echo " Ready!"

        if [ "$BUILD_VM" = true ]; then
            echo "--- Saving Initial Clean Snapshot ---"
            sudo virsh snapshot-delete "$VM_NAME" "$SNAPSHOT_NAME" 2>/dev/null || true
            sudo virsh snapshot-create-as "$VM_NAME" "$SNAPSHOT_NAME" >/dev/null \
                || { echo "WARNING: Failed to create snapshot '$SNAPSHOT_NAME'. -r and -s may fail."; }
        fi
    fi

elif [ "$BACKEND" = "tart" ]; then
    start_vm_background
    wait_for_ip
    wait_for_ssh
fi

# --- SYNC PACKAGES ---
if [ "$SYNC_ONLY" = true ] && [ "$PKG_EXT" != "unknown" ]; then
    if ls "$PKGS_DIR"/*."$PKG_EXT" >/dev/null 2>&1; then
        echo "--- Removing old packages in VM ---"
        if [ "$BACKEND" = "libvirt" ]; then
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_PRIV" -q "$USER_NAME@$VM_IP" "sudo rm -f /home/$USER_NAME/*.$PKG_EXT"
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_PRIV" -q "$PKGS_DIR"/*."$PKG_EXT" "$USER_NAME@$VM_IP:/home/$USER_NAME/"
        elif [ "$BACKEND" = "tart" ]; then
            vm_ssh "$USER_NAME@$VM_IP" "sudo rm -f /home/$USER_NAME/*.$PKG_EXT"
            vm_scp "$PKGS_DIR"/*."$PKG_EXT" "$USER_NAME@$VM_IP:/home/$USER_NAME/"
        fi
    else
        echo "WARNING: No *.$PKG_EXT files found in $PKGS_DIR"
    fi
fi

# --- AUTO-INSTALL OR INTERACTIVE SSH ---
if [ -n "$AUTO_INSTALL_PKG" ]; then
    echo "--- Auto-installing $AUTO_INSTALL_PKG ---"
    vm_ssh -t "$USER_NAME@$VM_IP" "/usr/local/bin/ipkg $AUTO_INSTALL_PKG"
else
    if [ -n "$VM_IP" ]; then
        echo "--- Connecting to $VM_IP (VM will stop on exit) ---"
        vm_ssh -t "$USER_NAME@$VM_IP"
    fi
fi

# --- PULL LOGS ---
if [ -n "$VM_IP" ]; then
    echo "--- Pulling comparison logs to $LOGS_DIR/$VM_NAME/ ---"
    mkdir -p "$LOGS_DIR/$VM_NAME"
    vm_scp "$USER_NAME@$VM_IP:/tmp/*.delta" "$LOGS_DIR/$VM_NAME/" 2>/dev/null || true
    vm_scp "$USER_NAME@$VM_IP:/tmp/*.before" "$LOGS_DIR/$VM_NAME/" 2>/dev/null || true
    vm_scp "$USER_NAME@$VM_IP:/tmp/*.after" "$LOGS_DIR/$VM_NAME/" 2>/dev/null || true
    if [ "$BACKEND" = "tart" ]; then
        vm_ssh "$USER_NAME@$VM_IP" "sudo sync" || true
    fi
    echo "--- Exited SSH. Stopping VM $VM_NAME ---"
    stop_vm
fi


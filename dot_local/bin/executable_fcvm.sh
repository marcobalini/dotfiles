#!/bin/bash

# --- CONFIGURATION ---
USER_NAME="fctech"
DISTRO="fedora-42"  # Default distro
PKGS_DIR="."
# Auto-detect SSH private key (tries common key types in order)
SSH_KEY_PRIV=""
for _k in id_ed25519 id_ecdsa id_rsa; do
    if [ -f "$HOME/.ssh/$_k" ]; then SSH_KEY_PRIV="$HOME/.ssh/$_k"; break; fi
done
SSH_KEY="${SSH_KEY_PRIV}.pub"   # Public key used for VM injection
SNAPSHOT_NAME="clean-base"
DEFAULT_PASS="faircom"

# --- NETWORK/BOOT TIMING CONFIG (override via env) ---
IP_WAIT_RETRIES="${IP_WAIT_RETRIES:-60}"      # 60 * 3s = 180s
IP_WAIT_SLEEP_SECS="${IP_WAIT_SLEEP_SECS:-3}"

# --- REPO CONFIG (override via environment variables) ---
REPO_BASE_URL="${REPO_BASE_URL:-http://vmftest.eu.faircom.com:8081/repository}"
RPM_REPO_PATH="${RPM_REPO_PATH:-faircom-rpm}"
RPM_REPO_ID="${RPM_REPO_ID:-faircom-rpm}"
RPM_REPO_NAME="${RPM_REPO_NAME:-FairCom Internal RPM Repository}"

DEB_REPO_CURRENT_PATH="${DEB_REPO_CURRENT_PATH:-faircom-deb-current}"
DEB_REPO_LEGACY_PATH="${DEB_REPO_LEGACY_PATH:-faircom-deb-legacy}"
DEB_SUITE_CURRENT="${DEB_SUITE_CURRENT:-current}"
DEB_SUITE_LEGACY="${DEB_SUITE_LEGACY:-legacy}"
DEB_COMPONENT="${DEB_COMPONENT:-main}"

KEYS_REPO_PATH="${KEYS_REPO_PATH:-faircom-keys}"
KEYS_FILE_NAME="${KEYS_FILE_NAME:-faircom-packages.gpg.pub}"

# --- USAGE MENU ---
usage() {
    echo "Usage: $0 [OPTIONS] [distro]"
    echo "  (no flags)   Start VM, SSH into it, and STOP on exit"
    echo "  -r           Restore to '$SNAPSHOT_NAME', SSH, and STOP on exit"
    echo "  -b           Build/Rebuild the VM from scratch (Prompts for password)"
    echo "  -s           Sync pkgs to existing VM (Requires restart)"
    echo "  -a <pkg>     Auto-install <pkg> (Restores, Syncs, Installs, and Exits)"
    echo "  -d <dir>     Directory containing packages (default: current directory)"
    echo "  -e           Enable internal faircom repo setup during VM build"
    echo "  -32          Build/test 32-bit VM (sets architecture to i686)"
    echo "  -m <arch>    CPU architecture (default: x86_64, e.g., i686)"
    echo "  -l           List all ${USER_NAME} VMs and their state"
    echo "  -x           Remove VM completely (destroy, undefine, delete disk)"
    echo "  -h           Show this help menu"
    echo ""
    echo "  [distro]     Optional distro name (default: $DISTRO)"
    echo "               Example: $0 -b ubuntu-20.04"
    exit 1
}

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
PKGS_DIR=$(realpath "$PKGS_DIR")
LOGS_DIR="$PKGS_DIR/logs"

# Dynamic naming
if [ "$ARCH" = "x86_64" ]; then
    VM_NAME="${DISTRO}-${USER_NAME}"
else
    VM_NAME="${DISTRO}-${ARCH}-${USER_NAME}"
fi
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"

# --- LIST VMs (early exit, no distro needed) ---
if [ "$LIST_VMS" = true ]; then
    echo "--- ${USER_NAME} VMs ---"
    sudo virsh list --all --name | grep -- "-${USER_NAME}" | while read -r name; do
        state=$(sudo virsh domstate "$name" 2>/dev/null)
        printf "  %-40s %s\n" "$name" "$state"
    done || true
    exit 0
fi

# --- PASSWORD PROMPT (Only for Build) ---
if [ "$BUILD_VM" = true ]; then
    echo -n "Enter password for root and $USER_NAME [Default: $DEFAULT_PASS]: "
    read -s DUAL_PASS
    echo "" # New line after silent input
    if [ -z "$DUAL_PASS" ]; then
        DUAL_PASS="$DEFAULT_PASS"
        echo "--- Using default password ---"
    fi
fi

# --- OS INFO VARIANT DETECTION ---
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

# --- PACKAGE TYPE DETECTION ---
if [[ "$DISTRO" == *"fedora"* ]] || [[ "$DISTRO" == *"centos"* ]] || [[ "$DISTRO" == *"rhel"* ]] || [[ "$DISTRO" == *"alma"* ]]; then
    PKG_EXT="rpm"
elif [[ "$DISTRO" == *"ubuntu"* ]] || [[ "$DISTRO" == *"debian"* ]]; then
    PKG_EXT="deb"
else
    PKG_EXT="unknown"
fi

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

# Function to inject files
inject_packages() {
    if [ "$PKG_EXT" = "unknown" ]; then return; fi
    if ls "$PKGS_DIR"/*."$PKG_EXT" >/dev/null 2>&1; then
        echo "--- Injecting *.$PKG_EXT ---"
        sudo virt-copy-in -a "$DISK_PATH" "$PKGS_DIR"/*."$PKG_EXT" /home/"$USER_NAME"/
    fi
}

# --- LOGIC SELECTION ---

if [ "$REMOVE_VM" = true ]; then
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

elif [ "$BUILD_VM" = true ]; then
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
        # Fix for EOL CentOS repositories (moved from mirror.centos.org to vault.centos.org)
        BUILDER_ARGS+=( "--run-command" "sed -i 's/^mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo" )
        BUILDER_ARGS+=( "--run-command" "sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo" )
    fi

    if [[ "$DISTRO" == "ubuntu-"* ]]; then
        # Workaround for ubuntu virt-resize bug involving logical partitions
        BUILDER_ARGS+=( "--install" "cloud-guest-utils" )
        BUILDER_ARGS+=( "--firstboot-command" "growpart /dev/vda 2 || growpart /dev/sda 2 || true" )
        BUILDER_ARGS+=( "--firstboot-command" "growpart /dev/vda 5 || growpart /dev/sda 5 || true" )
        BUILDER_ARGS+=( "--firstboot-command" "resize2fs /dev/vda5 || resize2fs /dev/sda5 || true" )
        
        # Ubuntu 18.04+ uses netplan. Without a cloud-init datasource, it may boot without
        # a configured network interface (hence the IP timeout). We inject a catch-all netplan config.
        BUILDER_ARGS+=( "--run-command" "mkdir -p /etc/netplan && printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    virt_eth:\n      match:\n        name: e*\n      dhcp4: true\n' > /etc/netplan/99-dhcp.yaml" )
    else
        BUILDER_ARGS+=( "--size" "10G" )
    fi

    if [[ "$DISTRO" == "debian-"* ]]; then
        # Debian network auto-configuration firstboot script
        BUILDER_ARGS+=( "--firstboot-command" "IFACE=\$(ls /sys/class/net | grep -v lo | head -n1); if [ -n \"\$IFACE\" ]; then (echo auto \$IFACE; echo iface \$IFACE inet dhcp) > /etc/network/interfaces.d/auto && (ifup \$IFACE || systemctl restart networking); fi" )
    fi

    # Determine the appropriate alias command based on the package type
    # Determine the appropriate installation command based on the package type
    DIRS="/etc/faircom /usr/share/faircom /var/lib/faircom /var/log/faircom /usr/libexec/faircom /usr/lib/faircom /usr/lib64/faircom /usr/bin"
    if [ "$PKG_EXT" = "rpm" ]; then
        # Repo has el7, el8, el9 but not el10+; cap all distros accordingly
        if [[ "$DISTRO" == *"fedora"* ]]; then
            FVER="${DISTRO#fedora-}"
            if [ "$FVER" -ge 34 ] 2>/dev/null; then
                REPO_RELEASE="9"
            elif [ "$FVER" -ge 28 ] 2>/dev/null; then
                REPO_RELEASE="8"
            else
                REPO_RELEASE="7"
            fi
        else
            DISTRO_VER=$(echo "$DISTRO" | grep -oP '\d+' | head -n1)
            if [ "${DISTRO_VER:-9}" -ge 9 ] 2>/dev/null; then
                REPO_RELEASE="9"
            elif [ "${DISTRO_VER:-9}" -ge 8 ] 2>/dev/null; then
                REPO_RELEASE="8"
            else
                REPO_RELEASE="7"
            fi
        fi
        PKG_MANAGER="dnf"
        PKGLS_CMD="rpm -qpl"
        BUILDER_ARGS+=( "--run-command" "mkdir -p /etc/yum.repos.d/ && printf '[${RPM_REPO_ID}]\nname=${RPM_REPO_NAME}\nbaseurl=${REPO_BASE_URL}/${RPM_REPO_PATH}/el${REPO_RELEASE}/\$basearch/\nenabled=1\ngpgcheck=0\nskip_if_unavailable=1\n' > /etc/yum.repos.d/faircom.repo" )
    elif [ "$PKG_EXT" = "deb" ]; then
        PKG_MANAGER="DEBIAN_FRONTEND=noninteractive apt-get"
        PKGLS_CMD="dpkg -c"
        # glibc >= 2.28 uses 'current' repo, older uses 'legacy'
        # Ubuntu >= 20.04 and Debian >= 10 ship glibc >= 2.28
        if [[ "$DISTRO" == "ubuntu-"* ]]; then
            UBUNTU_MAJOR="${DISTRO#ubuntu-}"; UBUNTU_MAJOR="${UBUNTU_MAJOR%%.*}"
            if [ "$UBUNTU_MAJOR" -ge 20 ] 2>/dev/null && [ "$ARCH" != "i686" ]; then
                DEB_REPO_PATH="$DEB_REPO_CURRENT_PATH"; DEB_REPO_SUITE="$DEB_SUITE_CURRENT"
            else
                DEB_REPO_PATH="$DEB_REPO_LEGACY_PATH"; DEB_REPO_SUITE="$DEB_SUITE_LEGACY"
            fi
        elif [[ "$DISTRO" == "debian-"* ]]; then
            DEBIAN_VER="${DISTRO#debian-}"
            DEBIAN_VER="${DEBIAN_VER%%-*}"
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
        if [ "$ENABLE_REPO_SETUP" = "true" ]; then
            # Check if repo is reachable before injecting curl commands that will break virt-builder if it's down
            echo "--- Checking connection to $REPO_BASE_URL... ---"
            if ! curl -m 3 --silent --head "$REPO_BASE_URL" > /dev/null; then
                echo "ERROR: -e flag used but repository $REPO_BASE_URL is unreachable."
                echo "Please ensure the Nexus repository is running, or run without -e."
                exit 1
            else
                # Debian 9 (stretch) and 10 (buster) are EOL — packages live on archive.debian.org
                # and their signing keys have expired, so disable validity checks and trust the repos.
                case "$DEBIAN_VER" in
                    9)  _DEB_ARCHIVE_CODENAME="stretch" ;;
                    10) _DEB_ARCHIVE_CODENAME="buster"  ;;
                    *)  _DEB_ARCHIVE_CODENAME=""         ;;
                esac
                if [ -n "$_DEB_ARCHIVE_CODENAME" ]; then
                    BUILDER_ARGS+=( "--run-command" "set -e; printf '%s\n' 'Acquire::Check-Valid-Until \"false\";' 'Acquire::AllowInsecureRepositories \"true\";' 'Acquire::AllowDowngradeToInsecureRepositories \"true\";' > /etc/apt/apt.conf.d/99archive-no-valid-until; printf '%s\n' 'deb [trusted=yes] http://archive.debian.org/debian ${_DEB_ARCHIVE_CODENAME} main contrib non-free' 'deb [trusted=yes] http://archive.debian.org/debian-security ${_DEB_ARCHIVE_CODENAME}/updates main contrib non-free' > /etc/apt/sources.list; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated curl gnupg ca-certificates; mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d; curl -s '${REPO_BASE_URL}/${KEYS_REPO_PATH}/${KEYS_FILE_NAME}' | gpg --dearmor -o /etc/apt/trusted.gpg.d/faircom-packages.gpg; chmod 0644 /etc/apt/trusted.gpg.d/faircom-packages.gpg; _A=\"${ARCH}\"; [ \"\$_A\" = \"x86_64\" ] && _A=\"amd64\"; [ \"\$_A\" = \"i686\" ] && _A=\"i386\"; printf '%s\n' \"deb [arch=\$_A signed-by=/etc/apt/trusted.gpg.d/faircom-packages.gpg] ${REPO_BASE_URL}/${DEB_REPO_PATH} ${DEB_REPO_SUITE} ${DEB_COMPONENT}\" > /etc/apt/sources.list.d/faircom.list; apt-get update" )
                else
                    BUILDER_ARGS+=( "--run-command" "set -e; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg ca-certificates; mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d; curl -s '${REPO_BASE_URL}/${KEYS_REPO_PATH}/${KEYS_FILE_NAME}' | gpg --dearmor -o /etc/apt/trusted.gpg.d/faircom-packages.gpg; chmod 0644 /etc/apt/trusted.gpg.d/faircom-packages.gpg; _A=\"${ARCH}\"; [ \"\$_A\" = \"x86_64\" ] && _A=\"amd64\"; [ \"\$_A\" = \"i686\" ] && _A=\"i386\"; printf '%s\n' \"deb [arch=\$_A signed-by=/etc/apt/trusted.gpg.d/faircom-packages.gpg] ${REPO_BASE_URL}/${DEB_REPO_PATH} ${DEB_REPO_SUITE} ${DEB_COMPONENT}\" > /etc/apt/sources.list.d/faircom.list; apt-get update" )
                fi
            fi
        fi
    else
        PKG_MANAGER="echo"
        PKGLS_CMD="echo"
    fi

    IPKG_SCRIPT="/usr/local/bin/ipkg"
    IDIFF_SCRIPT="/usr/local/bin/idiff"
    
    IPKG_CONTENT=$(cat <<EOF
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
EOF
    )

    IDIFF_CONTENT=$(cat <<EOF
#!/bin/bash
p=\$(basename "\${1:-all}"); base=\${p%%.*}
log_name=\$(echo "\$base" | sed -E 's/[_-][0-9].*//')
sudo vimdiff -c "windo set nofoldenable" "/tmp/\$log_name.before" "/tmp/\$log_name.after"
EOF
    )

    FC_ALIASES=$(cat <<'ALIASES_EOF'
alias fclog='sudo tail -f /var/log/faircom/CTSTATUS.FCS'
alias add32='sudo dpkg --add-architecture i386 && sudo apt-get update'
fcsta() { sudo systemctl start $(systemctl list-unit-files --type=service --no-legend | grep '^faircom-' | awk '{print $1}'); }
fcsto() { sudo systemctl stop $(systemctl list-unit-files --type=service --no-legend | grep '^faircom-' | awk '{print $1}'); }
ALIASES_EOF
    )

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
    # --os-variant updated to $OS_VARIANT
    sudo virt-install \
        --name "$VM_NAME" \
        --arch "$ARCH" \
        --ram 2048 --vcpus 2 \
        --os-variant "$OS_VARIANT" \
        --import --disk path="$DISK_PATH",format=qcow2 \
        --network default \
        --graphics none \
        --noautoconsole || { echo "ERROR: virt-install failed."; exit 1; }

elif [ "$SYNC_ONLY" = true ]; then
    echo "--- [SYNC] Restoring base and updating packages ---"
    sudo virsh destroy "$VM_NAME" 2>/dev/null
    sudo virsh snapshot-revert "$VM_NAME" "$SNAPSHOT_NAME" 2>/dev/null || { echo "Error: Snapshot not found."; exit 1; }
    
    # Snapshot is live, VM resumes immediately. 
    # Offline virt-copy-in fails due to QEMU locking the running disk. 
    # Packages will be injected via SCP after network comes up.
    sudo virsh start "$VM_NAME" 2>/dev/null || true
    sudo virsh resume "$VM_NAME" 2>/dev/null || true

elif [ "$RESTORE_VM" = true ]; then
    echo "--- [RESTORE] Reverting to $SNAPSHOT_NAME ---"
    sudo virsh destroy "$VM_NAME" 2>/dev/null
    sudo virsh snapshot-revert "$VM_NAME" "$SNAPSHOT_NAME" 2>/dev/null || { echo "Error: Snapshot not found."; exit 1; }
    sudo virsh start "$VM_NAME" 2>/dev/null || true
    sudo virsh resume "$VM_NAME" 2>/dev/null || true

else
    echo "--- [START] Starting existing VM $VM_NAME ---"
    VM_STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null)
    if [ "$VM_STATE" != "running" ]; then
        sudo virsh start "$VM_NAME" 2>/dev/null || { echo "Error: VM not found. Run -b first."; exit 1; }
    fi
fi

# --- NETWORK DETECTION ---
echo -n "--- Waiting for IP "
MAX_RETRIES="$IP_WAIT_RETRIES"; COUNT=0; VM_IP=""
VM_MAC=$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | grep -iE '[0-9a-f]{2}(:[0-9a-f]{2}){5}' -o | head -n1)

while [ -z "$VM_IP" ] && [ $COUNT -lt $MAX_RETRIES ]; do
    sleep "$IP_WAIT_SLEEP_SECS"
    # Update VM_MAC dynamically in case it wasn't available immediately
    if [ -z "$VM_MAC" ]; then
        VM_MAC=$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | grep -iE '[0-9a-f]{2}(:[0-9a-f]{2}){5}' -o | head -n1)
    fi

    # Plan A: Query Guest Agent directly
    VM_IP=$(sudo virsh domifaddr "$VM_NAME" --source agent 2>/dev/null | grep ipv4 | grep -v "127.0.0.1" | awk '{print $4}' | cut -d/ -f1 | head -n1)
    
    # Plan B: Query normal domifaddr (which may use 'lease' or default fallback)
    if [ -z "$VM_IP" ]; then
        VM_IP=$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null | grep ipv4 | grep -v "127.0.0.1" | awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi
    
    # Plan C: Query DHCP Leases using the exact MAC address
    if [ -z "$VM_IP" ] && [ -n "$VM_MAC" ]; then
        VM_IP=$(sudo virsh net-dhcp-leases default 2>/dev/null | grep -i "$VM_MAC" | awk '{print $5}' | grep -v "127.0.0.1" | cut -d/ -f1 | head -n1)
    fi

    # If still no IP halfway through, try to start guest agent from inside guest.
    if [ -z "$VM_IP" ] && [ $COUNT -eq $((MAX_RETRIES / 2)) ]; then
        sudo virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-exec","arguments":{"path":"/bin/sh","arg":["-lc","systemctl start qemu-guest-agent || service qemu-guest-agent start || true"],"capture-output":true}}' >/dev/null 2>&1 || true
    fi

    if [ -z "$VM_IP" ]; then
        ((COUNT++))
        echo -n "."
    fi
done
echo ""

# --- SSH CONNECTION & AUTO-STOP ---
if [ -n "$VM_IP" ]; then
    echo -n "--- Probing SSH Port "
    MAX_SSH_RETRIES=30; SSH_COUNT=0
    while ! nc -z -w 1 "$VM_IP" 22 >/dev/null 2>&1 && [ $SSH_COUNT -lt $MAX_SSH_RETRIES ]; do
        echo -n "."
        sleep 2
        ((SSH_COUNT++))
    done
    
    if [ $SSH_COUNT -eq $MAX_SSH_RETRIES ]; then
        echo " FAILED!"
        echo "ERROR: SSH probing timed out. The VM might be booting slowly or have a network/firewall issue."
        exit 1
    fi
    echo " Ready!"

    # --- POST-BUILD SNAPSHOT ---
    if [ "$BUILD_VM" = true ]; then
        echo "--- Saving Initial Clean Snapshot ---"
        sudo virsh snapshot-create-as "$VM_NAME" "$SNAPSHOT_NAME"
    fi

    # --- INJECT PACKAGES IF SYNC_ONLY ---
    if [ "$SYNC_ONLY" = true ] && [ "$PKG_EXT" != "unknown" ]; then
        if ls "$PKGS_DIR"/*."$PKG_EXT" >/dev/null 2>&1; then
            echo "--- Removing old packages in VM ---"
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -q "$USER_NAME@$VM_IP" "sudo rm -f /home/$USER_NAME/*.$PKG_EXT"
            echo "--- Injecting *.$PKG_EXT via SCP ---"
            scp -p -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
                "$PKGS_DIR"/*."$PKG_EXT" "$USER_NAME@$VM_IP:/home/$USER_NAME/"
        fi
    fi

    # -o ConnectTimeout=5 added to handle any lingering network hiccups
    if [ -n "$AUTO_INSTALL_PKG" ]; then
        echo "--- Auto-installing $AUTO_INSTALL_PKG ---"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 "$USER_NAME@$VM_IP" "/usr/local/bin/ipkg $AUTO_INSTALL_PKG"
    else
        echo "--- Connecting to $VM_IP (VM will stop on exit) ---"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -t "$USER_NAME@$VM_IP"
    fi
    
    # --- PULL LOGS FOR COMPARISON ---
    echo "--- Pulling comparison logs to $LOGS_DIR/$VM_NAME/ ---"
    mkdir -p "$LOGS_DIR/$VM_NAME"
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$USER_NAME@$VM_IP:/tmp/*.delta" \
        "$USER_NAME@$VM_IP:/tmp/*.before" \
        "$USER_NAME@$VM_IP:/tmp/*.after" \
        "$LOGS_DIR/$VM_NAME/" 2>/dev/null
    
    echo "--- Exited SSH. Stopping VM $VM_NAME... ---"
    sudo virsh destroy "$VM_NAME"
else
    echo "ERROR: IP detection timed out."
    exit 1
fi

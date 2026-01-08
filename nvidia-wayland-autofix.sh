#!/bin/bash
set -e

# ==========================================================
# NVIDIA Wayland AutoFix
# Version: v1.0
#
# Purpose:
#   Recover a working GNOME + Wayland + NVIDIA setup
#   after Ubuntu or kernel upgrades.
#
# Features:
#   • automatic NVIDIA driver detection (prefer OPEN)
#   • kernel header + DKMS handling
#   • dry-run mode (--dry-run)
#   • detection-only mode (--detect-only)
#   • detailed logging (XDG_STATE_HOME)
#   • per-section timing and success markers
#
# Usage:
#   ./nvidia-wayland-autofix.sh [--dry-run] [--detect-only] [--help]
#
# Maintained as a human-readable maintenance tool, not a one-off script.
# ==========================================================

DRYRUN=false
DETECT_ONLY=false

LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}"
LOGFILE="$LOGDIR/nvidia-wayland-autofix-$(date +%F-%H%M).log"

show_help() {
cat <<EOF
Usage: nvidia-wayland-autofix.sh [OPTIONS]

Options:
  --dry-run        Show what would be done without changing the system
  --detect-only    Perform detection only (no installs, no config changes)
  --help           Show this help message and exit

Notes:
  * --detect-only implies --dry-run
  * Logs are written to: $LOGDIR
EOF
}

# -------------------------------------------------
# Argument parsing
# -------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRYRUN=true
            ;;
        --detect-only)
            DETECT_ONLY=true
            DRYRUN=true
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            show_help
            exit 1
            ;;
    esac
done

if $DRYRUN; then
    echo ">>> DRY-RUN MODE ENABLED <<<"
fi

if $DETECT_ONLY; then
    echo ">>> DETECT-ONLY MODE ENABLED <<<"
fi

mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGFILE") 2>&1

run() {
    echo "+ $*"
    if ! $DRYRUN; then
        eval "$@"
    fi
}

section() {
    SECTION_NAME="$1"
    SECTION_START=$(date +%s)
    echo
    echo "-------------------------------------------------"
    echo "$SECTION_NAME"
    echo "-------------------------------------------------"
}

section_done() {
    local rc=$?
    local elapsed=$(( $(date +%s) - SECTION_START ))
    if [ $rc -eq 0 ]; then
        echo "✔ SUCCESS ($elapsed s)"
    else
        echo "✖ FAILED ($elapsed s)"
        exit $rc
    fi
}

# =================================================
# DETECTION PHASE
# =================================================

section "0. Basic sanity checks"

if ! lspci | grep -qi nvidia; then
    echo "No NVIDIA GPU detected. Exiting."
    exit 0
fi

KERNEL="$(uname -r)"
echo "Kernel: $KERNEL"

section_done

section "1. Detect recommended NVIDIA driver (prefer OPEN)"

DRIVER_LIST="$(ubuntu-drivers devices)"

OPEN_RECOMMENDED=$(echo "$DRIVER_LIST" | awk '
/nvidia-driver/ && /open/ && /recommended/ {print $3; exit}
')

if [ -n "$OPEN_RECOMMENDED" ]; then
    DRIVER="$OPEN_RECOMMENDED"
    DRIVER_TYPE="open"
else
    DRIVER=$(echo "$DRIVER_LIST" | awk '
/nvidia-driver/ && /recommended/ {print $3; exit}
')
    DRIVER_TYPE="proprietary"
fi

if [ -z "$DRIVER" ]; then
    echo "❌ No recommended NVIDIA driver found:"
    echo "$DRIVER_LIST"
    exit 1
fi

VERSION=$(echo "$DRIVER" | grep -o '[0-9]\+')

echo "Selected driver : $DRIVER"
echo "Driver type     : $DRIVER_TYPE"
echo "Driver version  : $VERSION"

section_done

# Stop here if detection-only
if $DETECT_ONLY; then
    section "2. Detect-only summary"
    echo "No actions performed."
    echo "Log file: $LOGFILE"
    section_done
    exit 0
fi

# =================================================
# ACTION PHASE
# =================================================

section "2. Update package lists"
run "sudo apt update"
section_done

section "3. Install kernel headers (CRITICAL)"
run "sudo apt install -y linux-headers-$KERNEL"
section_done

section "4. Install DKMS and build tools"
run "sudo apt install -y dkms build-essential"
section_done

section "5. Install NVIDIA driver"
run "sudo apt install -y $DRIVER"
section_done

section "6. Install matching NVIDIA utilities"
run "sudo apt install -y nvidia-utils-$VERSION"
section_done

section "7. Ensure DRM modeset (Wayland)"
run "echo 'options nvidia-drm modeset=1' | sudo tee /etc/modprobe.d/nvidia-drm.conf >/dev/null"
section_done

section "8. Reset GNOME monitor cache (safe)"
MON="$HOME/.config/monitors.xml"
if [ -f "$MON" ]; then
    run "mv $MON $MON.bak.$(date +%F-%H%M)"
else
    echo "No monitors.xml found."
fi
section_done

section "9. Summary"
echo "Log file: $LOGFILE"
echo "Dry-run : $DRYRUN"
echo "Driver  : $DRIVER"
section_done

if ! $DRYRUN; then
    read -p "Reboot now? [y/N]: " r
    [[ "$r" =~ ^[Yy]$ ]] && sudo reboot
else
    echo "Dry-run mode: no reboot."
fi


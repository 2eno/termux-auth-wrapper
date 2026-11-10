#!/usr/bin/env bash
# =============================================================================
# termux-auth-wrapper – uninstaller
#
#   uninstall.sh [--purge] [--prefix DIR] [-y]
#
# Removes wrappers, library, apt hook and PATH entries and restores original
# binaries diverted with dpkg-divert (e.g. ssh).
# --purge also deletes the configuration, audit log and caches.
# =============================================================================
set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TAW_COMPONENT="uninstall"
if [[ -f $_self_dir/install-lib.sh ]]; then
    # shellcheck source=lib/install-lib.sh
    source "$_self_dir/install-lib.sh"      # installed copy
else
    # shellcheck source=lib/install-lib.sh
    source "$_self_dir/lib/install-lib.sh"  # from the repository
fi

PURGE=false
ASSUME_YES=false
OPT_PREFIX="${PREFIX:-}"
while (($#)); do
    case $1 in
        --purge)   PURGE=true ;;
        --prefix)  [[ $# -ge 2 ]] || taw_die "--prefix requires a value"; OPT_PREFIX=$2; shift ;;
        -y|--yes)  ASSUME_YES=true ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)         taw_die "Unknown option: $1" ;;
    esac
    shift
done

[[ -n $OPT_PREFIX && -d $OPT_PREFIX ]] || taw_die "\$PREFIX not set or invalid (--prefix DIR)."
lib_dir="$(cd "$OPT_PREFIX" && pwd)/lib/termux-auth-wrapper"

if ! inst_read_state "$lib_dir"; then
    taw_die "No installation found ($lib_dir/install.state)."
fi

if [[ $ASSUME_YES != true && -t 0 ]]; then
    read -r -p "Remove termux-auth-wrapper from $INST_BIN_DIR$([[ $PURGE == true ]] && printf ' (incl. configuration)')? [y/N] " answer
    case ${answer,,} in
        j|ja|y|yes) ;;
        *) taw_info "Cancelled."; exit 0 ;;
    esac
fi

for w in $INST_WRAPPERS; do
    inst_remove_wrapper "$w"
done
for link in termux-auth check_biometric; do
    [[ -L $INST_BIN_DIR/$link ]] && rm -f "$INST_BIN_DIR/$link"
done
inst_remove_apt_hook
for rc in $INST_PROFILE_FILES; do
    inst_profile_remove "$rc"
done

rm -rf "$INST_LIB_DIR"
if [[ -d $INST_REAL_DIR ]] && ! rmdir "$INST_REAL_DIR" 2>/dev/null; then
    taw_warn "$INST_REAL_DIR is not empty and is kept."
fi
rm -rf "$TAW_RUNTIME_DIR"

if [[ $PURGE == true ]]; then
    rm -rf "$TAW_CONFIG_DIR" "$TAW_STATE_DIR"
    taw_ok "Configuration and logs removed."
else
    taw_info "Keeping the configuration: $TAW_CONFIG_DIR (remove with --purge)"
fi
taw_ok "termux-auth-wrapper has been uninstalled."
hash -r 2>/dev/null || true

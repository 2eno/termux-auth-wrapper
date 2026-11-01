#!/usr/bin/env bash
# =============================================================================
# termux-auth-wrapper – Deinstallation
#
#   uninstall.sh [--purge] [--prefix DIR] [-y]
#
# Entfernt Wrapper, Bibliothek, apt-Hook und PATH-Einträge und stellt per
# dpkg-divert umgeleitete Original-Binaries (z. B. ssh) wieder her.
# --purge löscht zusätzlich Konfiguration, Audit-Log und Caches.
# =============================================================================
set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TAW_COMPONENT="uninstall"
if [[ -f $_self_dir/install-lib.sh ]]; then
    # shellcheck source=lib/install-lib.sh
    source "$_self_dir/install-lib.sh"      # installierte Kopie
else
    # shellcheck source=lib/install-lib.sh
    source "$_self_dir/lib/install-lib.sh"  # aus dem Repository
fi

PURGE=false
ASSUME_YES=false
OPT_PREFIX="${PREFIX:-}"
while (($#)); do
    case $1 in
        --purge)   PURGE=true ;;
        --prefix)  [[ $# -ge 2 ]] || taw_die "--prefix benötigt einen Wert"; OPT_PREFIX=$2; shift ;;
        -y|--yes)  ASSUME_YES=true ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)         taw_die "Unbekannte Option: $1" ;;
    esac
    shift
done

[[ -n $OPT_PREFIX && -d $OPT_PREFIX ]] || taw_die "\$PREFIX nicht gesetzt oder ungültig (--prefix DIR)."
lib_dir="$(cd "$OPT_PREFIX" && pwd)/lib/termux-auth-wrapper"

if ! inst_read_state "$lib_dir"; then
    taw_die "Keine Installation gefunden ($lib_dir/install.state)."
fi

if [[ $ASSUME_YES != true && -t 0 ]]; then
    read -r -p "termux-auth-wrapper aus $INST_BIN_DIR entfernen$([[ $PURGE == true ]] && printf ' (inkl. Konfiguration)')? [j/N] " answer
    case ${answer,,} in
        j|ja|y|yes) ;;
        *) taw_info "Abgebrochen."; exit 0 ;;
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
    taw_warn "$INST_REAL_DIR ist nicht leer und bleibt erhalten."
fi
rm -rf "$TAW_RUNTIME_DIR"

if [[ $PURGE == true ]]; then
    rm -rf "$TAW_CONFIG_DIR" "$TAW_STATE_DIR"
    taw_ok "Konfiguration und Logs entfernt."
else
    taw_info "Konfiguration bleibt erhalten: $TAW_CONFIG_DIR (entfernen mit --purge)"
fi
taw_ok "termux-auth-wrapper wurde deinstalliert."
hash -r 2>/dev/null || true

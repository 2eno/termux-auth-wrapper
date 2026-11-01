# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016  # INST_*-Variablen für Aufrufer; $PATH bewusst literal
# =============================================================================
# termux-auth-wrapper – Installations-Hilfsfunktionen
#
# Gemeinsam genutzt von install.sh, uninstall.sh und "termux-auth repair".
# Erwartet gesetzte Variablen:
#   INST_PREFIX   Termux-Präfix ($PREFIX)
#   INST_MODE     prefix | home
#   INST_BIN_DIR  Zielverzeichnis der Wrapper ($PREFIX/bin oder ~/.bin)
#   INST_LIB_DIR  $PREFIX/lib/termux-auth-wrapper
#   INST_REAL_DIR $PREFIX/libexec/termux-auth-wrapper (gesicherte Originale)
#
# Update-Sicherheit:
#   * Gehört eine Datei in $PREFIX/bin einem Paket (z. B. ssh -> openssh),
#     wird sie per "dpkg-divert --local --rename" umgeleitet. Künftige
#     "pkg upgrade"-Läufe installieren das neue Binary dann automatisch an den
#     umgeleiteten Ort, der Wrapper bleibt unangetastet.
#   * Zusätzlich prüft ein apt-Hook (DPkg::Post-Invoke) nach jedem pkg-Lauf
#     die Wrapper und repariert sie bei Bedarf ("termux-auth repair").
#   * Die Termux-APK selbst wird nie verändert.
# =============================================================================

[[ -n "${_TAW_INSTLIB_LOADED:-}" ]] && return 0
_TAW_INSTLIB_LOADED=1

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

TAW_ALL_WRAPPERS=(sudo ssh)
TAW_PROFILE_BEGIN="# >>> termux-auth-wrapper >>>"
TAW_PROFILE_END="# <<< termux-auth-wrapper <<<"

inst_state_file()  { printf '%s/install.state' "$INST_LIB_DIR"; }
inst_apt_hook()    { printf '%s/etc/apt/apt.conf.d/99-termux-auth-wrapper' "$INST_PREFIX"; }

# --- dpkg --------------------------------------------------------------------
# Nur nutzen, wenn die dpkg-Datenbank im Präfix liegt (= echtes Termux).
# Schützt zudem davor, auf einem Desktop-Linux die System-dpkg-DB anzufassen.
inst_dpkg_available() {
    [[ -d $INST_PREFIX/var/lib/dpkg ]] \
        && command -v dpkg >/dev/null 2>&1 \
        && command -v dpkg-divert >/dev/null 2>&1
}

# Gibt das besitzende Paket einer Datei aus (oder Exit 1)
inst_dpkg_owner() {
    local out
    out=$(dpkg -S "$1" 2>/dev/null | grep -v '^diversion ' | head -n1) || return 1
    [[ -n $out ]] || return 1
    printf '%s' "${out%%:*}"
}

inst_is_diverted_by_us() {
    local name=$1 target="$INST_BIN_DIR/$1"
    inst_dpkg_available || return 1
    [[ $(dpkg-divert --listpackage "$target" 2>/dev/null) == LOCAL ]] || return 1
    [[ $(dpkg-divert --truename "$target" 2>/dev/null) == "$INST_REAL_DIR/$name" ]]
}

# --- Skripte mit Pfad-Ersetzung installieren ---------------------------------
_inst_sed_escape() { printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'; }

# inst_install_script <quelle> <ziel> [modus]
inst_install_script() {
    local src=$1 dest=$2 mode=${3:-0755} lib bash_path tmp
    lib=$(_inst_sed_escape "$INST_LIB_DIR")
    tmp="$dest.taw-new.$$"
    if [[ -x $INST_PREFIX/bin/bash ]]; then
        # Absoluter Shebang: funktioniert auch auf der Root-Seite ohne termux-exec
        bash_path=$(_inst_sed_escape "$INST_PREFIX/bin/bash")
        sed -e "1s|^#!/usr/bin/env bash\$|#!$bash_path|" -e "s|@TAW_LIB_DIR@|$lib|g" "$src" >"$tmp"
    else
        sed -e "s|@TAW_LIB_DIR@|$lib|g" "$src" >"$tmp"
    fi
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"   # atomar ersetzen (laufende Aufrufe bleiben intakt)
}

# --- Wrapper platzieren / entfernen ------------------------------------------
# inst_place_wrapper <name>
inst_place_wrapper() {
    local name=$1 target="$INST_BIN_DIR/$1" tmpl="$INST_LIB_DIR/wrappers/$1" pkg
    [[ -f $tmpl ]] || { taw_err "Vorlage fehlt: $tmpl"; return 1; }
    taw_ensure_dir "$INST_BIN_DIR" 755

    if [[ -e $target || -L $target ]] && ! taw_is_wrapper "$target"; then
        if [[ $INST_MODE == prefix ]]; then
            taw_ensure_dir "$INST_REAL_DIR" 755
            if inst_dpkg_available && pkg=$(inst_dpkg_owner "$target"); then
                if ! inst_is_diverted_by_us "$name"; then
                    if ! dpkg-divert --local --rename --divert "$INST_REAL_DIR/$name" --add "$target" >/dev/null; then
                        taw_err "dpkg-divert für $target fehlgeschlagen."
                        return 1
                    fi
                    taw_info "'$name' (Paket $pkg) per dpkg-divert nach $INST_REAL_DIR/$name umgeleitet – update-sicher."
                else
                    # Diversion besteht, Datei wurde trotzdem ersetzt -> Original sichern
                    mv -f "$target" "$INST_REAL_DIR/$name"
                fi
            else
                mv -f "$target" "$INST_REAL_DIR/$name"
                taw_info "Vorhandenes '$target' gesichert nach $INST_REAL_DIR/$name."
            fi
        else
            mv -f "$target" "$target.taw-backup"
            taw_info "Vorhandenes '$target' gesichert als $target.taw-backup."
        fi
    fi
    local tmp="$target.taw-new.$$"
    cp -f "$tmpl" "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$target"
}

# inst_remove_wrapper <name>
inst_remove_wrapper() {
    local name=$1 target="$INST_BIN_DIR/$1"
    if taw_is_wrapper "$target"; then
        rm -f "$target"
    elif [[ -e $target ]]; then
        taw_warn "$target ist kein termux-auth-wrapper – wird nicht gelöscht."
    fi
    if [[ $INST_MODE == prefix ]]; then
        if inst_is_diverted_by_us "$name"; then
            if dpkg-divert --local --rename --remove "$target" >/dev/null; then
                taw_info "Original von '$name' wiederhergestellt (dpkg-divert entfernt)."
            else
                taw_err "dpkg-divert --remove für $target fehlgeschlagen."
            fi
        elif [[ -e $INST_REAL_DIR/$name && ! -e $target ]]; then
            mv -f "$INST_REAL_DIR/$name" "$target"
            taw_info "Original von '$name' wiederhergestellt."
        fi
    elif [[ -e $target.taw-backup && ! -e $target ]]; then
        mv -f "$target.taw-backup" "$target"
        taw_info "Sicherung von '$name' wiederhergestellt."
    fi
}

inst_same_file() {
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$1" "$2"
    else
        [[ $(sha256sum <"$1") == "$(sha256sum <"$2")" ]]
    fi
}

# Prüft einen Wrapper; gibt ok | outdated | replaced | missing aus
inst_wrapper_state() {
    local target="$INST_BIN_DIR/$1" tmpl="$INST_LIB_DIR/wrappers/$1"
    if [[ ! -e $target ]]; then
        printf 'missing'
    elif ! taw_is_wrapper "$target"; then
        printf 'replaced'
    elif ! inst_same_file "$target" "$tmpl"; then
        printf 'outdated'
    else
        printf 'ok'
    fi
}

# --- apt-Hook ----------------------------------------------------------------
inst_install_apt_hook() {
    local hook dir tool
    hook=$(inst_apt_hook)
    dir=$(dirname "$hook")
    tool="$INST_BIN_DIR/termux-auth"
    [[ -d $dir ]] || { taw_warn "apt-Konfigurationsverzeichnis fehlt ($dir) – kein Hook installiert."; return 0; }
    cat >"$hook" <<EOF
// termux-auth-wrapper: prüft nach jedem pkg/apt-Lauf, ob die Wrapper noch
// intakt sind, und repariert sie bei Bedarf. Entfernen: uninstall.sh
DPkg::Post-Invoke { "[ -x $tool ] && $tool repair --quiet || true"; };
EOF
    chmod 644 "$hook"
}

inst_remove_apt_hook() { rm -f "$(inst_apt_hook)"; }

# --- PATH-Eintrag für den home-Modus -----------------------------------------
inst_profile_add() {
    local file=$1
    [[ -f $file ]] && grep -qF "$TAW_PROFILE_BEGIN" "$file" && return 0
    {
        printf '\n%s\n' "$TAW_PROFILE_BEGIN"
        printf '%s\n' '# Wrapper-Verzeichnis VOR $PREFIX/bin, damit sudo/ssh-Wrapper greifen'
        printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$INST_BIN_DIR" "$INST_BIN_DIR"
        printf '%s\n' "$TAW_PROFILE_END"
    } >>"$file"
}

inst_profile_remove() {
    local file=$1 tmp
    [[ -f $file ]] && grep -qF "$TAW_PROFILE_BEGIN" "$file" || return 0
    tmp="$file.taw-tmp.$$"
    awk -v b="$TAW_PROFILE_BEGIN" -v e="$TAW_PROFILE_END" '
        $0 == b {skip=1; next}
        $0 == e {skip=0; next}
        !skip {print}' "$file" >"$tmp" && cat "$tmp" >"$file"
    rm -f "$tmp"
}

# --- Installationszustand ----------------------------------------------------
inst_write_state() {
    # $1 = Wrapper-Liste, $2 = apt-Hook (true/false), $3 = Profil-Dateien
    local f
    f=$(inst_state_file)
    {
        printf '# Automatisch erzeugt von install.sh – nicht bearbeiten\n'
        printf 'VERSION="%s"\n' "$TAW_VERSION"
        printf 'MODE="%s"\n' "$INST_MODE"
        printf 'PREFIX="%s"\n' "$INST_PREFIX"
        printf 'BIN_DIR="%s"\n' "$INST_BIN_DIR"
        printf 'REAL_DIR="%s"\n' "$INST_REAL_DIR"
        printf 'WRAPPERS="%s"\n' "$1"
        printf 'APT_HOOK="%s"\n' "$2"
        printf 'PROFILE_FILES="%s"\n' "$3"
    } >"$f"
    chmod 644 "$f"
}

_inst_state_cb() {
    case $1 in
        VERSION)       INST_VERSION=$2 ;;
        MODE)          INST_MODE=$2 ;;
        PREFIX)        INST_PREFIX=$2 ;;
        BIN_DIR)       INST_BIN_DIR=$2 ;;
        REAL_DIR)      INST_REAL_DIR=$2 ;;
        WRAPPERS)      INST_WRAPPERS=$2 ;;
        APT_HOOK)      INST_APT_HOOK=$2 ;;
        PROFILE_FILES) INST_PROFILE_FILES=$2 ;;
    esac
}

# inst_read_state <lib-dir>
inst_read_state() {
    INST_LIB_DIR=$1
    local f
    f=$(inst_state_file)
    [[ -f $f ]] || return 1
    INST_VERSION="" INST_MODE="" INST_PREFIX="" INST_BIN_DIR="" INST_REAL_DIR=""
    INST_WRAPPERS="" INST_APT_HOOK="" INST_PROFILE_FILES=""
    taw_parse_kv_file "$f" _inst_state_cb
    [[ -n $INST_MODE && -n $INST_BIN_DIR ]]
}

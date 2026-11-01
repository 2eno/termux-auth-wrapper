#!/usr/bin/env bash
# =============================================================================
# termux-auth-wrapper – Installationsskript
#
#   ./install.sh [Optionen]
#
# Installiert:
#   $PREFIX/lib/termux-auth-wrapper/        Bibliotheken, Wrapper-Vorlagen, Zustand
#   $PREFIX/libexec/termux-auth-wrapper/    gesicherte Original-Binaries (dpkg-divert)
#   <BIN>/sudo, <BIN>/ssh                   Wrapper   (BIN = $PREFIX/bin oder ~/.bin)
#   <BIN>/termux-auth, <BIN>/check_biometric
#   ~/.config/termux-auth-wrapper/          Konfiguration (wird nie überschrieben)
#   $PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper   Selbstreparatur nach pkg upgrade
#
# Die Termux-APK wird nicht verändert; App-Updates lassen alles unberührt.
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TAW_COMPONENT="install"
# shellcheck source=lib/install-lib.sh
source "$SRC_DIR/lib/install-lib.sh"

usage() {
    cat <<EOF
Aufruf: ./install.sh [Optionen]

  --mode prefix|home   prefix (Standard): Wrapper nach \$PREFIX/bin – greift für
                       alle Prozesse inkl. Hintergrund-Skripte, cron, Termux:Boot.
                       home: Wrapper nach ~/.bin + PATH-Eintrag in ~/.bashrc etc.
  --only sudo|ssh      nur einen Wrapper installieren (mehrfach möglich)
  --no-sudo            sudo-Wrapper nicht installieren
  --no-ssh             ssh-Wrapper nicht installieren
  --install-deps       fehlende Pakete automatisch per pkg installieren
  --skip-deps          Abhängigkeitsprüfung überspringen
  --no-apt-hook        keinen apt-Hook zur Selbstreparatur anlegen
  --prefix DIR         abweichendes Präfix (Tests/Entwicklung)
  --force              auch außerhalb von Termux installieren
  -y, --yes            keine Rückfragen
  -h, --help           diese Hilfe
EOF
}

# --- Optionen ----------------------------------------------------------------
MODE=prefix
WANT_SUDO=true
WANT_SSH=true
ONLY=()
INSTALL_DEPS=false
SKIP_DEPS=false
APT_HOOK=true
FORCE=false
ASSUME_YES=false
OPT_PREFIX="${PREFIX:-}"

while (($#)); do
    case $1 in
        --mode)         [[ $# -ge 2 ]] || taw_die "--mode benötigt einen Wert"; MODE=$2; shift ;;
        --mode=*)       MODE=${1#*=} ;;
        --only)         [[ $# -ge 2 ]] || taw_die "--only benötigt einen Wert"; ONLY+=("$2"); shift ;;
        --no-sudo)      WANT_SUDO=false ;;
        --no-ssh)       WANT_SSH=false ;;
        --install-deps) INSTALL_DEPS=true ;;
        --skip-deps)    SKIP_DEPS=true ;;
        --no-apt-hook)  APT_HOOK=false ;;
        --prefix)       [[ $# -ge 2 ]] || taw_die "--prefix benötigt einen Wert"; OPT_PREFIX=$2; shift ;;
        --force)        FORCE=true ;;
        -y|--yes)       ASSUME_YES=true ;;
        -h|--help)      usage; exit 0 ;;
        *)              taw_err "Unbekannte Option: $1"; usage >&2; exit 1 ;;
    esac
    shift
done

[[ $MODE == prefix || $MODE == home ]] || taw_die "Ungültiger Modus '$MODE' (prefix|home)."

if ((${#ONLY[@]})); then
    WANT_SUDO=false; WANT_SSH=false
    for o in "${ONLY[@]}"; do
        case $o in
            sudo) WANT_SUDO=true ;;
            ssh)  WANT_SSH=true ;;
            *)    taw_die "Unbekannter Wrapper für --only: $o" ;;
        esac
    done
fi
WRAPPERS=()
[[ $WANT_SUDO == true ]] && WRAPPERS+=(sudo)
[[ $WANT_SSH == true ]] && WRAPPERS+=(ssh)
((${#WRAPPERS[@]})) || taw_die "Keine Wrapper ausgewählt."

# --- Umgebung prüfen ---------------------------------------------------------
[[ -n $OPT_PREFIX ]] || taw_die "\$PREFIX ist nicht gesetzt – läuft das Skript in Termux? (sonst --prefix DIR --force)"
[[ -d $OPT_PREFIX ]] || taw_die "Präfix-Verzeichnis existiert nicht: $OPT_PREFIX"
INST_PREFIX=$(cd "$OPT_PREFIX" && pwd)

if [[ $INST_PREFIX != */com.termux/files/usr && $FORCE != true ]]; then
    taw_die "Das sieht nicht nach Termux aus (PREFIX=$INST_PREFIX). Mit --force trotzdem installieren."
fi
# TAW_ALLOW_ROOT=1 nur für automatisierte Tests in Containern
if [[ $(id -u) == 0 && ${TAW_ALLOW_ROOT:-0} != 1 ]]; then
    taw_die "Bitte NICHT als root ausführen – als normaler Termux-Benutzer starten."
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    taw_die "Bash >= 4.4 erforderlich (gefunden: $BASH_VERSION)."
fi

INST_MODE=$MODE
INST_LIB_DIR="$INST_PREFIX/lib/termux-auth-wrapper"
INST_REAL_DIR="$INST_PREFIX/libexec/termux-auth-wrapper"
if [[ $MODE == prefix ]]; then
    INST_BIN_DIR="$INST_PREFIX/bin"
else
    INST_BIN_DIR="$HOME/.bin"
fi
CONFIG_DIR="$TAW_CONFIG_DIR"

# --- Abhängigkeiten ----------------------------------------------------------
# Befehl -> Termux-Paket
declare -A REQUIRED=([jq]=jq [termux-fingerprint]=termux-api [timeout]=coreutils
                     [sha256sum]=coreutils [mktemp]=coreutils [readlink]=coreutils
                     [awk]=gawk [sed]=sed [grep]=grep)
declare -A OPTIONAL=()
if [[ $WANT_SSH == true ]]; then
    REQUIRED[ssh]=openssh
    OPTIONAL[sshpass]=sshpass
    OPTIONAL[ssh-add]=openssh
fi

check_deps() {
    local cmd missing=() missing_pkgs=() opt_missing=()
    for cmd in "${!REQUIRED[@]}"; do
        # ssh kann bereits durch einen alten Wrapper ersetzt/umgeleitet sein
        if [[ $cmd == ssh && -x $INST_REAL_DIR/ssh ]]; then continue; fi
        command -v "$cmd" >/dev/null 2>&1 || { missing+=("$cmd"); missing_pkgs+=("${REQUIRED[$cmd]}"); }
    done
    for cmd in "${!OPTIONAL[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || opt_missing+=("$cmd (${OPTIONAL[$cmd]})")
    done

    if ((${#missing[@]})); then
        local pkgs
        pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
        if [[ $INSTALL_DEPS == true ]]; then
            command -v pkg >/dev/null 2>&1 || taw_die "'pkg' nicht gefunden – Pakete manuell installieren: $pkgs"
            taw_info "Installiere fehlende Pakete: $pkgs"
            # shellcheck disable=SC2086
            pkg install -y $pkgs || taw_die "Paketinstallation fehlgeschlagen."
        else
            taw_err "Fehlende Abhängigkeiten: ${missing[*]}"
            taw_hint "Installieren mit:  pkg install $pkgs"
            taw_hint "oder:              ./install.sh --install-deps"
            exit 1
        fi
    fi
    if ((${#opt_missing[@]})); then
        taw_warn "Optionale Werkzeuge fehlen: ${opt_missing[*]}"
        taw_hint "Für Bitwarden-Passwörter: pkg install sshpass"
    fi
    if ! command -v bw >/dev/null 2>&1; then
        taw_info "Bitwarden CLI nicht gefunden (optional): pkg install nodejs && npm install -g @bitwarden/cli"
    fi
    taw_hint "Wichtig: Zusätzlich muss die App 'Termux:API' installiert sein (gleiche Quelle wie Termux: F-Droid oder GitHub)."
}

if [[ $SKIP_DEPS == true ]]; then
    taw_warn "Abhängigkeitsprüfung übersprungen."
else
    check_deps
fi

if [[ $WANT_SUDO == true ]]; then
    su_found=""
    for c in /system/bin/su /data/adb/ksu/bin/su /system/xbin/su /sbin/su; do
        [[ -x $c ]] && { su_found=$c; break; }
    done
    if [[ -n $su_found ]]; then
        taw_ok "su gefunden: $su_found"
    else
        taw_warn "Kein su gefunden. In der KernelSU-Manager-App Termux Root-Rechte gewähren, sonst funktioniert sudo nicht."
    fi
fi

# --- Bestätigung -------------------------------------------------------------
cat >&2 <<EOF

  Präfix:      $INST_PREFIX
  Modus:       $MODE
  Wrapper:     ${WRAPPERS[*]}  ->  $INST_BIN_DIR
  Bibliothek:  $INST_LIB_DIR
  Konfig:      $CONFIG_DIR

EOF
if [[ $ASSUME_YES != true && -t 0 ]]; then
    read -r -p "Fortfahren? [J/n] " answer
    case ${answer,,} in
        ""|j|ja|y|yes) ;;
        *) taw_info "Abgebrochen."; exit 0 ;;
    esac
fi

# --- Bestehende Installation (Moduswechsel) ----------------------------------
new_mode=$INST_MODE new_prefix=$INST_PREFIX new_bin=$INST_BIN_DIR
new_lib=$INST_LIB_DIR new_real=$INST_REAL_DIR
if inst_read_state "$new_lib" 2>/dev/null; then
    if [[ $INST_MODE != "$new_mode" || $INST_BIN_DIR != "$new_bin" ]]; then
        taw_info "Vorherige Installation (Modus $INST_MODE, $INST_BIN_DIR) wird zuerst entfernt."
        for w in $INST_WRAPPERS; do inst_remove_wrapper "$w"; done
        rm -f "$INST_BIN_DIR/termux-auth" "$INST_BIN_DIR/check_biometric"
        for rc in $INST_PROFILE_FILES; do inst_profile_remove "$rc"; done
    fi
fi
INST_MODE=$new_mode INST_PREFIX=$new_prefix INST_BIN_DIR=$new_bin
INST_LIB_DIR=$new_lib INST_REAL_DIR=$new_real

# --- Dateien installieren ----------------------------------------------------
taw_ensure_dir "$INST_LIB_DIR" 755
taw_ensure_dir "$INST_LIB_DIR/wrappers" 755
taw_ensure_dir "$INST_REAL_DIR" 755
taw_ensure_dir "$INST_BIN_DIR" 755
taw_ensure_dir "$CONFIG_DIR" 700

for f in common.sh auth.sh bitwarden.sh install-lib.sh; do
    inst_install_script "$SRC_DIR/lib/$f" "$INST_LIB_DIR/$f" 0644
done
inst_install_script "$SRC_DIR/lib/check_biometric.sh" "$INST_LIB_DIR/check_biometric.sh" 0755
inst_install_script "$SRC_DIR/bin/termux-auth" "$INST_LIB_DIR/termux-auth" 0755
inst_install_script "$SRC_DIR/uninstall.sh" "$INST_LIB_DIR/uninstall.sh" 0755
for w in "${TAW_ALL_WRAPPERS[@]}"; do
    inst_install_script "$SRC_DIR/wrappers/$w" "$INST_LIB_DIR/wrappers/$w" 0755
done
cp -f "$SRC_DIR/config/config.conf.example" "$INST_LIB_DIR/config.conf.example"
cp -f "$SRC_DIR/config/ssh-hosts.conf.example" "$INST_LIB_DIR/ssh-hosts.conf.example"
taw_ok "Bibliothek installiert: $INST_LIB_DIR"

# Nicht mehr gewünschte Wrapper (z. B. nach --no-ssh) entfernen
for w in "${TAW_ALL_WRAPPERS[@]}"; do
    if [[ " ${WRAPPERS[*]} " != *" $w "* ]] && taw_is_wrapper "$INST_BIN_DIR/$w"; then
        inst_remove_wrapper "$w"
    fi
done

for w in "${WRAPPERS[@]}"; do
    inst_place_wrapper "$w" || taw_die "Wrapper '$w' konnte nicht installiert werden."
    taw_ok "Wrapper installiert: $INST_BIN_DIR/$w"
done

ln -sfn "$INST_LIB_DIR/termux-auth" "$INST_BIN_DIR/termux-auth"
ln -sfn "$INST_LIB_DIR/check_biometric.sh" "$INST_BIN_DIR/check_biometric"
taw_ok "Werkzeuge verlinkt: termux-auth, check_biometric"

# --- Konfiguration (niemals überschreiben) -----------------------------------
if [[ ! -f $CONFIG_DIR/config.conf ]]; then
    cp "$SRC_DIR/config/config.conf.example" "$CONFIG_DIR/config.conf"
    chmod 600 "$CONFIG_DIR/config.conf"
    taw_ok "Konfiguration angelegt: $CONFIG_DIR/config.conf"
else
    taw_info "Bestehende Konfiguration bleibt erhalten: $CONFIG_DIR/config.conf"
    taw_hint "Neue Optionen siehe: $INST_LIB_DIR/config.conf.example"
fi
if [[ ! -f $CONFIG_DIR/ssh-hosts.conf ]]; then
    cp "$SRC_DIR/config/ssh-hosts.conf.example" "$CONFIG_DIR/ssh-hosts.conf"
    chmod 600 "$CONFIG_DIR/ssh-hosts.conf"
fi

# --- Update-Sicherheit / PATH ------------------------------------------------
profile_files=()
if [[ $MODE == prefix ]]; then
    if [[ $APT_HOOK == true ]]; then
        inst_install_apt_hook
        [[ -f $(inst_apt_hook) ]] && taw_ok "apt-Hook angelegt: $(inst_apt_hook)"
    else
        inst_remove_apt_hook
    fi
else
    APT_HOOK=false
    inst_remove_apt_hook
    for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
        # .bashrc immer, .zshrc nur wenn vorhanden, .profile nur wenn vorhanden
        if [[ $rc == "$HOME/.bashrc" || -f $rc ]]; then
            inst_profile_add "$rc"
            profile_files+=("$rc")
        fi
    done
    taw_ok "PATH-Eintrag ergänzt in: ${profile_files[*]}"
    taw_warn "home-Modus: Prozesse, die nicht aus einer Shell mit angepasstem PATH starten"
    taw_hint "(z. B. Termux:Boot, Termux:Widget, crond) umgehen die Wrapper. Dafür --mode prefix verwenden."
fi

inst_write_state "${WRAPPERS[*]}" "$APT_HOOK" "${profile_files[*]}"

# --- Abschluss ---------------------------------------------------------------
cat >&2 <<EOF

Installation abgeschlossen.

Nächste Schritte:
  1. Konfiguration prüfen:      termux-auth config edit
  2. Zustand prüfen:            termux-auth doctor
  3. Fingerabdruck testen:      termux-auth test
  4. Ausprobieren:              sudo id
EOF
if [[ $MODE == home ]]; then
    echo "  Neue Shell öffnen oder:     export PATH=\"$INST_BIN_DIR:\$PATH\"" >&2
fi
printf '\nDeinstallation: %s/uninstall.sh\n' "$INST_LIB_DIR" >&2

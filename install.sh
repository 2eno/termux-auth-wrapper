#!/usr/bin/env bash
# =============================================================================
# termux-auth-wrapper – installer
#
#   ./install.sh [options]
#
# Installs:
#   $PREFIX/lib/termux-auth-wrapper/        libraries, wrapper templates, state
#   $PREFIX/libexec/termux-auth-wrapper/    saved original binaries (dpkg-divert)
#   <BIN>/sudo, <BIN>/ssh                   wrappers   (BIN = $PREFIX/bin or ~/.bin)
#   <BIN>/termux-auth, <BIN>/check_biometric
#   ~/.config/termux-auth-wrapper/          configuration (never overwritten)
#   $PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper   self-repair after pkg upgrade
#
# The Termux APK is not modified; app updates leave everything untouched.
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TAW_COMPONENT="install"
# shellcheck source=lib/install-lib.sh
source "$SRC_DIR/lib/install-lib.sh"

usage() {
    cat <<EOF
Usage: ./install.sh [options]

  --mode prefix|home   prefix (default): wrappers in \$PREFIX/bin – applies to
                       all processes incl. background scripts, cron, Termux:Boot.
                       home: wrappers in ~/.bin + PATH entry in ~/.bashrc etc.
  --only sudo|ssh      install only one wrapper (can be repeated)
  --no-sudo            don't install the sudo wrapper
  --no-ssh             don't install the ssh wrapper
  --install-deps       install missing packages automatically with pkg
  --skip-deps          skip the dependency check
  --no-apt-hook        don't create the apt hook for self-repair
  --prefix DIR         different prefix (tests/development)
  --force              install outside of Termux too
  -y, --yes            no questions
  -h, --help           this help
EOF
}

# --- Options -----------------------------------------------------------------
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
        --mode)         [[ $# -ge 2 ]] || taw_die "--mode requires a value"; MODE=$2; shift ;;
        --mode=*)       MODE=${1#*=} ;;
        --only)         [[ $# -ge 2 ]] || taw_die "--only requires a value"; ONLY+=("$2"); shift ;;
        --no-sudo)      WANT_SUDO=false ;;
        --no-ssh)       WANT_SSH=false ;;
        --install-deps) INSTALL_DEPS=true ;;
        --skip-deps)    SKIP_DEPS=true ;;
        --no-apt-hook)  APT_HOOK=false ;;
        --prefix)       [[ $# -ge 2 ]] || taw_die "--prefix requires a value"; OPT_PREFIX=$2; shift ;;
        --force)        FORCE=true ;;
        -y|--yes)       ASSUME_YES=true ;;
        -h|--help)      usage; exit 0 ;;
        *)              taw_err "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
    shift
done

[[ $MODE == prefix || $MODE == home ]] || taw_die "Invalid mode '$MODE' (prefix|home)."

if ((${#ONLY[@]})); then
    WANT_SUDO=false; WANT_SSH=false
    for o in "${ONLY[@]}"; do
        case $o in
            sudo) WANT_SUDO=true ;;
            ssh)  WANT_SSH=true ;;
            *)    taw_die "Unknown wrapper for --only: $o" ;;
        esac
    done
fi
WRAPPERS=()
[[ $WANT_SUDO == true ]] && WRAPPERS+=(sudo)
[[ $WANT_SSH == true ]] && WRAPPERS+=(ssh)
((${#WRAPPERS[@]})) || taw_die "No wrappers selected."

# --- Check the environment ---------------------------------------------------
[[ -n $OPT_PREFIX ]] || taw_die "\$PREFIX is not set – is the script running in Termux? (otherwise --prefix DIR --force)"
[[ -d $OPT_PREFIX ]] || taw_die "Prefix directory does not exist: $OPT_PREFIX"
INST_PREFIX=$(cd "$OPT_PREFIX" && pwd)

if [[ $INST_PREFIX != */com.termux/files/usr && $FORCE != true ]]; then
    taw_die "This does not look like Termux (PREFIX=$INST_PREFIX). Use --force to install anyway."
fi
# TAW_ALLOW_ROOT=1 only for automated tests in containers
if [[ $(id -u) == 0 && ${TAW_ALLOW_ROOT:-0} != 1 ]]; then
    taw_die "Do NOT run this as root – start it as the normal Termux user."
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    taw_die "Bash >= 4.4 required (found: $BASH_VERSION)."
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

# --- Dependencies ------------------------------------------------------------
# command -> Termux package
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
        # ssh may already have been replaced/diverted by an old wrapper
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
            command -v pkg >/dev/null 2>&1 || taw_die "'pkg' not found – install the packages manually: $pkgs"
            taw_info "Installing missing packages: $pkgs"
            # shellcheck disable=SC2086
            pkg install -y $pkgs || taw_die "Package installation failed."
        else
            taw_err "Missing dependencies: ${missing[*]}"
            taw_hint "Install with:  pkg install $pkgs"
            taw_hint "or:            ./install.sh --install-deps"
            exit 1
        fi
    fi
    if ((${#opt_missing[@]})); then
        taw_warn "Optional tools missing: ${opt_missing[*]}"
        taw_hint "For Bitwarden passwords: pkg install sshpass"
    fi
    if ! command -v bw >/dev/null 2>&1; then
        taw_info "Bitwarden CLI not found (optional): pkg install nodejs && npm install -g @bitwarden/cli"
    fi
    taw_hint "Important: the 'Termux:API' app must be installed too (same source as Termux: F-Droid or GitHub)."
}

if [[ $SKIP_DEPS == true ]]; then
    taw_warn "Dependency check skipped."
else
    check_deps
fi

if [[ $WANT_SUDO == true ]]; then
    su_found=""
    for c in /system/bin/su /data/adb/ksu/bin/su /system/xbin/su /sbin/su; do
        [[ -x $c ]] && { su_found=$c; break; }
    done
    if [[ -n $su_found ]]; then
        taw_ok "su found: $su_found"
    else
        taw_warn "No su found. Grant Termux root access in the KernelSU manager app, otherwise sudo will not work."
    fi
fi

# --- Confirmation ------------------------------------------------------------
cat >&2 <<EOF

  Prefix:      $INST_PREFIX
  Mode:        $MODE
  Wrappers:    ${WRAPPERS[*]}  ->  $INST_BIN_DIR
  Library:     $INST_LIB_DIR
  Config:      $CONFIG_DIR

EOF
if [[ $ASSUME_YES != true && -t 0 ]]; then
    read -r -p "Continue? [Y/n] " answer
    case ${answer,,} in
        ""|j|ja|y|yes) ;;
        *) taw_info "Cancelled."; exit 0 ;;
    esac
fi

# --- Existing installation (mode change) -------------------------------------
new_mode=$INST_MODE new_prefix=$INST_PREFIX new_bin=$INST_BIN_DIR
new_lib=$INST_LIB_DIR new_real=$INST_REAL_DIR
if inst_read_state "$new_lib" 2>/dev/null; then
    if [[ $INST_MODE != "$new_mode" || $INST_BIN_DIR != "$new_bin" ]]; then
        taw_info "Removing the previous installation (mode $INST_MODE, $INST_BIN_DIR) first."
        for w in $INST_WRAPPERS; do inst_remove_wrapper "$w"; done
        rm -f "$INST_BIN_DIR/termux-auth" "$INST_BIN_DIR/check_biometric"
        for rc in $INST_PROFILE_FILES; do inst_profile_remove "$rc"; done
    fi
fi
INST_MODE=$new_mode INST_PREFIX=$new_prefix INST_BIN_DIR=$new_bin
INST_LIB_DIR=$new_lib INST_REAL_DIR=$new_real

# --- Install files -----------------------------------------------------------
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
taw_ok "Library installed: $INST_LIB_DIR"

# Remove wrappers that are no longer wanted (e.g. after --no-ssh)
for w in "${TAW_ALL_WRAPPERS[@]}"; do
    if [[ " ${WRAPPERS[*]} " != *" $w "* ]] && taw_is_wrapper "$INST_BIN_DIR/$w"; then
        inst_remove_wrapper "$w"
    fi
done

for w in "${WRAPPERS[@]}"; do
    inst_place_wrapper "$w" || taw_die "Could not install wrapper '$w'."
    taw_ok "Wrapper installed: $INST_BIN_DIR/$w"
done

ln -sfn "$INST_LIB_DIR/termux-auth" "$INST_BIN_DIR/termux-auth"
ln -sfn "$INST_LIB_DIR/check_biometric.sh" "$INST_BIN_DIR/check_biometric"
taw_ok "Tools linked: termux-auth, check_biometric"

# --- Configuration (never overwrite) -----------------------------------------
if [[ ! -f $CONFIG_DIR/config.conf ]]; then
    cp "$SRC_DIR/config/config.conf.example" "$CONFIG_DIR/config.conf"
    chmod 600 "$CONFIG_DIR/config.conf"
    taw_ok "Configuration created: $CONFIG_DIR/config.conf"
else
    taw_info "Keeping the existing configuration: $CONFIG_DIR/config.conf"
    taw_hint "For new options see: $INST_LIB_DIR/config.conf.example"
fi
if [[ ! -f $CONFIG_DIR/ssh-hosts.conf ]]; then
    cp "$SRC_DIR/config/ssh-hosts.conf.example" "$CONFIG_DIR/ssh-hosts.conf"
    chmod 600 "$CONFIG_DIR/ssh-hosts.conf"
fi

# --- Update safety / PATH ----------------------------------------------------
profile_files=()
if [[ $MODE == prefix ]]; then
    if [[ $APT_HOOK == true ]]; then
        inst_install_apt_hook
        [[ -f $(inst_apt_hook) ]] && taw_ok "apt hook created: $(inst_apt_hook)"
    else
        inst_remove_apt_hook
    fi
else
    APT_HOOK=false
    inst_remove_apt_hook
    for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
        # .bashrc always, .zshrc and .profile only if they exist
        if [[ $rc == "$HOME/.bashrc" || -f $rc ]]; then
            inst_profile_add "$rc"
            profile_files+=("$rc")
        fi
    done
    taw_ok "PATH entry added to: ${profile_files[*]}"
    taw_warn "home mode: processes that do not start from a shell with the adjusted PATH"
    taw_hint "(e.g. Termux:Boot, Termux:Widget, crond) bypass the wrappers. Use --mode prefix for those."
fi

inst_write_state "${WRAPPERS[*]}" "$APT_HOOK" "${profile_files[*]}"

# --- Done --------------------------------------------------------------------
cat >&2 <<EOF

Installation complete.

Next steps:
  1. Check the configuration:   termux-auth config edit
  2. Check the state:           termux-auth doctor
  3. Test the fingerprint:      termux-auth test
  4. Try it:                    sudo id
EOF
if [[ $MODE == home ]]; then
    echo "  Open a new shell or:        export PATH=\"$INST_BIN_DIR:\$PATH\"" >&2
fi
printf '\nUninstall: %s/uninstall.sh\n' "$INST_LIB_DIR" >&2

# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by other components
# =============================================================================
# termux-auth-wrapper – shared functions
#
# Sourced by all components (wrappers, check_biometric.sh, termux-auth).
# Contains: paths, logging, safe config loading, resolving the "real"
# binaries, locking and the audit log.
# =============================================================================

# Prevent sourcing more than once
[[ -n "${_TAW_COMMON_LOADED:-}" ]] && return 0
_TAW_COMMON_LOADED=1

TAW_VERSION="1.0.0"
TAW_MARKER="TERMUX_AUTH_WRAPPER_MARKER"

# --- Paths -------------------------------------------------------------------
# Note: everything lives in the Linux prefix or in $HOME – never in the APK.
TAW_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TAW_LIB_DIR="${TAW_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
TAW_REAL_DIR="${TAW_REAL_DIR:-$TAW_PREFIX/libexec/termux-auth-wrapper}"
TAW_CONFIG_DIR="${TAW_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/termux-auth-wrapper}"
TAW_CONFIG_FILE="${TAW_CONFIG_FILE:-$TAW_CONFIG_DIR/config.conf}"
TAW_HOSTS_FILE="${TAW_HOSTS_FILE:-$TAW_CONFIG_DIR/ssh-hosts.conf}"
TAW_STATE_DIR="${TAW_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/termux-auth-wrapper}"
TAW_RUNTIME_DIR="${TAW_RUNTIME_DIR:-${TMPDIR:-$TAW_PREFIX/tmp}/termux-auth-wrapper-$(id -u)}"
TAW_COMPONENT="${TAW_COMPONENT:-termux-auth}"

# --- Logging -----------------------------------------------------------------
_taw_color() {
    # $1 = ANSI code; only if stderr is a terminal and color is allowed
    local mode="${TAW_COLOR:-auto}"
    if [[ $mode == never || -n ${NO_COLOR:-} ]]; then return 1; fi
    if [[ $mode == always || -t 2 ]]; then printf '\033[%sm' "$1"; return 0; fi
    return 1
}

_taw_log() {
    local level=$1 code=$2; shift 2
    local on="" off=""
    if on=$(_taw_color "$code"); then off=$'\033[0m'; fi
    printf '%s[%s] %s:%s %s\n' "$on" "$TAW_COMPONENT" "$level" "$off" "$*" >&2
}

taw_err()   { _taw_log "error" "1;31" "$@"; }
taw_warn()  { _taw_log "warning" "1;33" "$@"; }
taw_info()  { [[ ${TAW_QUIET:-false} == true ]] || _taw_log "info" "1;36" "$@"; }
taw_ok()    { [[ ${TAW_QUIET:-false} == true ]] || _taw_log "OK" "1;32" "$@"; }
taw_debug() { taw_is_true "${TAW_DEBUG:-false}" && _taw_log "debug" "2" "$@"; return 0; }
taw_hint()  { [[ ${TAW_QUIET:-false} == true ]] || printf '    -> %s\n' "$*" >&2; }

# taw_die <message> [exit code]
taw_die() {
    taw_err "$1"
    exit "${2:-1}"
}

# --- Helpers -----------------------------------------------------------------
taw_is_true() {
    case "${1,,}" in
        1|true|yes|y|on|ja) return 0 ;;
        *) return 1 ;;
    esac
}

taw_is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

taw_now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

# POSIX-compatible quoting (for /system/bin/sh on the root side).
# The result is always in single quotes: abc'd -> 'abc'\''d'
taw_shell_quote() {
    local s=$1
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

# Print several arguments quoted and separated by spaces
taw_shell_join() {
    local out="" arg
    for arg in "$@"; do
        out+="${out:+ }$(taw_shell_quote "$arg")"
    done
    printf '%s' "$out"
}

# Checks whether an interactive terminal is available for input
taw_have_tty() {
    { : </dev/tty; } 2>/dev/null
}

taw_ensure_dir() {
    # $1 = directory, $2 = mode
    if [[ ! -d $1 ]]; then
        mkdir -p "$1" || taw_die "Cannot create directory: $1"
    fi
    chmod "${2:-700}" "$1" 2>/dev/null || true
}

# --- Configuration -----------------------------------------------------------
# Allowed keys and their defaults. The config file is NOT sourced but parsed
# line by line (no code from the file is executed).
# Priority: environment variable TAW_<KEY>  >  file  >  default.
declare -gA _TAW_DEFAULTS=(
    # Biometrics
    [BIO_TITLE]="Termux authentication"
    [BIO_TIMEOUT]="30"
    [BIO_MAX_ATTEMPTS]="2"
    [BIO_DIALOG_TEXT]="true"
    # Auth cache (grace period like sudo)
    [AUTH_CACHE_TIMEOUT]="300"
    [AUTH_CACHE_SCOPE]="session"
    [AUTH_CACHE_SHARED]="false"
    [LOCK_TIMEOUT]="120"
    # Fallbacks
    [FALLBACK_MODE]="none"
    [FALLBACK_ON_REJECT]="false"
    [FALLBACK_PIN_HASH]=""
    # sudo
    [SUDO_ENABLED]="true"
    [SU_BINARY]="auto"
    [SUDO_PRESERVE_TERMUX_ENV]="true"
    [SUDO_HOME]="suroot"
    [SUDO_SHELL]="auto"
    [SUDO_MOUNT_MASTER]="false"
    [SUDO_WARN_PKG]="true"
    # ssh
    [SSH_ENABLED]="true"
    [SSH_BINARY]="auto"
    [SSH_AUTH_SCOPE]="all"
    [SSH_SKIP_HOSTS]=""
    [SSH_KEY_METHOD]="auto"
    [SSH_AGENT_KEY_LIFETIME]="300"
    # Bitwarden
    [BW_ENABLED]="false"
    [BW_UNLOCK_MODE]="prompt"
    [BW_SESSION_CACHE]="false"
    [BW_TIMEOUT]="60"
    [BW_SYNC]="false"
    [BW_FALLBACK]="prompt"
    # General
    [AUDIT_LOG]="true"
    [AUDIT_LOG_ARGS]="false"
    [DEBUG]="false"
    [COLOR]="auto"
)

taw_is_config_key() { [[ -n ${1:-} && -v "_TAW_DEFAULTS[$1]" ]]; }

# Expands ~, $HOME, $PREFIX in values (no other expansion!)
_taw_expand_value() {
    local v=$1
    [[ $v == "~" ]] && v=$HOME
    # shellcheck disable=SC2088  # literal ~ is intended
    [[ $v == "~/"* ]] && v="$HOME/${v#\~/}"
    v=${v//\$\{HOME\}/$HOME}
    v=${v//\$HOME/$HOME}
    v=${v//\$\{PREFIX\}/$TAW_PREFIX}
    v=${v//\$PREFIX/$TAW_PREFIX}
    printf '%s' "$v"
}

# Reads KEY=VALUE lines from a file. Calls the callback "$2 KEY VALUE LINE"
# for every valid entry.
taw_parse_kv_file() {
    local file=$1 callback=$2 line key value lineno=0
    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key=${BASH_REMATCH[2]}
            value=${BASH_REMATCH[3]}
            if [[ $value =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
                value=${BASH_REMATCH[1]}
            elif [[ $value =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
                value=${BASH_REMATCH[1]}
            else
                value=${value%%[[:space:]]#*}
                value=${value%"${value##*[![:space:]]}"}
            fi
            "$callback" "$key" "$(_taw_expand_value "$value")" "$file:$lineno"
        else
            taw_warn "Invalid line in $file:$lineno – ignored"
        fi
    done <"$file"
}

declare -gA _TAW_FROM_ENV=()

_taw_config_cb() {
    local key=${1^^} value=$2 where=$3
    if ! taw_is_config_key "$key"; then
        taw_warn "Unknown config key '$key' ($where) – ignored"
        return 0
    fi
    # Environment variables take precedence
    [[ -n ${_TAW_FROM_ENV[$key]:-} ]] && return 0
    printf -v "TAW_$key" '%s' "$value"
}

taw_load_config() {
    local key var
    # 1) What comes from the environment?
    for key in "${!_TAW_DEFAULTS[@]}"; do
        var="TAW_$key"
        [[ -v $var ]] && _TAW_FROM_ENV[$key]=1
    done
    # 2) File
    if [[ -f $TAW_CONFIG_FILE ]]; then
        [[ -r $TAW_CONFIG_FILE ]] || taw_die "Config file not readable: $TAW_CONFIG_FILE"
        taw_parse_kv_file "$TAW_CONFIG_FILE" _taw_config_cb
    else
        taw_debug "No config file found ($TAW_CONFIG_FILE) – using defaults"
    fi
    # 3) Defaults for everything else
    for key in "${!_TAW_DEFAULTS[@]}"; do
        var="TAW_$key"
        [[ -v $var ]] || printf -v "$var" '%s' "${_TAW_DEFAULTS[$key]}"
    done
    _taw_validate_config
}

_taw_validate_config() {
    local key
    for key in BIO_TIMEOUT BIO_MAX_ATTEMPTS AUTH_CACHE_TIMEOUT LOCK_TIMEOUT \
               BW_TIMEOUT SSH_AGENT_KEY_LIFETIME; do
        local var="TAW_$key"
        if ! taw_is_uint "${!var}"; then
            taw_warn "$key='${!var}' is not a number – using default ${_TAW_DEFAULTS[$key]}"
            printf -v "$var" '%s' "${_TAW_DEFAULTS[$key]}"
        fi
    done
    (( TAW_BIO_MAX_ATTEMPTS >= 1 )) || TAW_BIO_MAX_ATTEMPTS=1
    (( TAW_BIO_TIMEOUT >= 5 )) || TAW_BIO_TIMEOUT=5
    _taw_check_enum FALLBACK_MODE none pin allow
    _taw_check_enum AUTH_CACHE_SCOPE global session
    _taw_check_enum SSH_AUTH_SCOPE all mapped
    _taw_check_enum SSH_KEY_METHOD auto agent tempfile
    _taw_check_enum BW_UNLOCK_MODE prompt never
    _taw_check_enum BW_FALLBACK prompt fail
    return 0
}

_taw_check_enum() {
    local key=$1; shift
    local var="TAW_$key" allowed
    for allowed in "$@"; do
        [[ ${!var} == "$allowed" ]] && return 0
    done
    taw_warn "$key='${!var}' is invalid (allowed: $*) – using '${_TAW_DEFAULTS[$key]}'"
    printf -v "$var" '%s' "${_TAW_DEFAULTS[$key]}"
}

# --- Finding the real binaries -----------------------------------------------
# Is the file one of our wrappers?
taw_is_wrapper() {
    [[ -f $1 ]] && head -c 512 "$1" 2>/dev/null | grep -qF "$TAW_MARKER"
}

# taw_find_real <name> [override]
# Order: explicit path from the config -> saved original in $TAW_REAL_DIR
# (dpkg-divert) -> first match in $PATH that is not a wrapper.
taw_find_real() {
    local name=$1 override=${2:-auto} dir candidate
    if [[ -n $override && $override != auto ]]; then
        if [[ -x $override ]] && ! taw_is_wrapper "$override"; then
            printf '%s' "$override"
            return 0
        fi
        taw_err "Configured binary for '$name' is invalid or not executable: $override"
        return 1
    fi
    candidate="$TAW_REAL_DIR/$name"
    if [[ -x $candidate ]] && ! taw_is_wrapper "$candidate"; then
        printf '%s' "$candidate"
        return 0
    fi
    local -a dirs
    IFS=: read -ra dirs <<<"${PATH:-}"
    for dir in "${dirs[@]}"; do
        [[ -n $dir ]] || continue
        candidate="$dir/$name"
        [[ -f $candidate && -x $candidate ]] || continue
        taw_is_wrapper "$candidate" && continue
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

# --- Locking (mkdir-based, no flock dependency) ------------------------------
_TAW_HELD_LOCK=""

taw_lock_acquire() {
    # $1 = name, $2 = timeout in seconds
    local lockdir="$TAW_RUNTIME_DIR/$1.lock" max=$(( ${2:-60} * 10 )) waited=0 pid
    taw_ensure_dir "$TAW_RUNTIME_DIR" 700
    while ! mkdir "$lockdir" 2>/dev/null; do
        pid=$(cat "$lockdir/pid" 2>/dev/null || true)
        if [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; then
            taw_debug "Removed stale lock of PID $pid"
            rm -rf "$lockdir"
            continue
        fi
        if (( waited >= max )); then
            return 1
        fi
        waited=$((waited + 1))
        sleep 0.1
    done
    printf '%s\n' "$$" >"$lockdir/pid"
    _TAW_HELD_LOCK=$lockdir
    return 0
}

taw_lock_release() {
    if [[ -n $_TAW_HELD_LOCK ]]; then
        rm -rf "$_TAW_HELD_LOCK"
        _TAW_HELD_LOCK=""
    fi
    return 0
}

# --- Audit log ---------------------------------------------------------------
# taw_audit <result> <method> <details>
taw_audit() {
    taw_is_true "${TAW_AUDIT_LOG:-true}" || return 0
    local log="$TAW_STATE_DIR/audit.log"
    {
        taw_ensure_dir "$TAW_STATE_DIR" 700
        if [[ -f $log ]] && (( $(wc -c <"$log") > 1048576 )); then
            mv -f "$log" "$log.1"
        fi
        printf '%s pid=%s ppid=%s comp=%s result=%s method=%s %s\n' \
            "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$PPID" "$TAW_COMPONENT" \
            "$1" "$2" "${3:-}" >>"$log"
        chmod 600 "$log"
    } 2>/dev/null || true
    return 0
}

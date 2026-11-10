# shellcheck shell=bash
# shellcheck disable=SC2153  # TAW_* values come from taw_load_config
# =============================================================================
# termux-auth-wrapper – authentication flow
#
#   taw_authenticate <cache-key> <description> [non-interactive: true|false]
#
#   1. valid auth cache (grace period)?            -> OK, no dialog
#   2. take the lock (parallel calls from scripts share ONE dialog)
#   3. fingerprint (check_biometric.sh)
#   4. fallback (PIN / allow) if configured
#   5. update the cache, write the audit log
# =============================================================================

[[ -n "${_TAW_AUTH_LOADED:-}" ]] && return 0
_TAW_AUTH_LOADED=1

_taw_auth_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/common.sh
source "$_taw_auth_dir/common.sh"
# shellcheck source=lib/check_biometric.sh
source "$_taw_auth_dir/check_biometric.sh"

TAW_AUTH_METHOD=""

# --- Auth cache --------------------------------------------------------------
_taw_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown'
}

# Identifier of the terminal session (tty_nr + session ID from /proc/self/stat).
# Also works when stdin/stdout are redirected (scripts, pipes).
_taw_session_id() {
    local stat rest
    stat=$(cat "/proc/$$/stat" 2>/dev/null) || { printf 'nosession'; return; }
    rest=${stat##*) }               # everything after "(comm) "
    local -a f
    read -ra f <<<"$rest"
    # f[0]=state f[1]=ppid f[2]=pgrp f[3]=session f[4]=tty_nr
    printf 'tty%s-sid%s' "${f[4]:-0}" "${f[3]:-0}"
}

taw_cache_file() {
    local key=$1
    taw_is_true "$TAW_AUTH_CACHE_SHARED" && key="shared"
    if [[ $TAW_AUTH_CACHE_SCOPE == session ]]; then
        key+="-$(_taw_session_id)"
    fi
    printf '%s/auth-%s.ts' "$TAW_RUNTIME_DIR" "$key"
}

taw_cache_valid() {
    local f ts boot now
    (( TAW_AUTH_CACHE_TIMEOUT > 0 )) || return 1
    f=$(taw_cache_file "$1")
    [[ -f $f && ! -L $f ]] || return 1
    read -r ts boot <"$f" 2>/dev/null || return 1
    taw_is_uint "${ts:-}" || return 1
    [[ $boot == "$(_taw_boot_id)" ]] || return 1
    now=$(taw_now)
    (( ts <= now && now - ts < TAW_AUTH_CACHE_TIMEOUT ))
}

taw_cache_update() {
    (( TAW_AUTH_CACHE_TIMEOUT > 0 )) || return 0
    local f
    taw_ensure_dir "$TAW_RUNTIME_DIR" 700
    f=$(taw_cache_file "$1")
    (umask 077; printf '%s %s\n' "$(taw_now)" "$(_taw_boot_id)" >"$f") || true
}

# Clear all caches (sudo -K, termux-auth reset)
taw_cache_clear_all() {
    rm -f "$TAW_RUNTIME_DIR"/auth-*.ts 2>/dev/null || true
}

taw_cache_clear() {
    rm -f "$(taw_cache_file "$1")" 2>/dev/null || true
}

# --- Fallback ----------------------------------------------------------------
taw_pin_hash() {
    # $1 = salt, $2 = PIN
    printf '%s:%s' "$1" "$2" | sha256sum | cut -d' ' -f1
}

_taw_fallback_pin() {
    local stored=$TAW_FALLBACK_PIN_HASH salt hash pin try
    if [[ ! $stored =~ ^sha256:([A-Za-z0-9]+):([0-9a-f]{64})$ ]]; then
        taw_err "FALLBACK_MODE=pin, but FALLBACK_PIN_HASH is not set/invalid."
        taw_hint "Set a PIN with: termux-auth set-pin"
        return 1
    fi
    salt=${BASH_REMATCH[1]}
    hash=${BASH_REMATCH[2]}
    if ! taw_have_tty; then
        taw_err "The PIN fallback needs a terminal (/dev/tty) – not possible in the background."
        return 1
    fi
    for try in 1 2 3; do
        printf '[%s] Fallback PIN (%s/3): ' "$TAW_COMPONENT" "$try" >/dev/tty
        IFS= read -r -s pin </dev/tty || pin=""
        printf '\n' >/dev/tty
        if [[ -n $pin && $(taw_pin_hash "$salt" "$pin") == "$hash" ]]; then
            pin=""
            return 0
        fi
        taw_warn "Wrong PIN."
    done
    pin=""
    return 1
}

# Called when the fingerprint check was not successful.
_taw_fallback() {
    case $TAW_BIO_STATUS in
        unavailable) ;;
        rejected|locked)
            if ! taw_is_true "$TAW_FALLBACK_ON_REJECT"; then
                return 1
            fi ;;
        *) return 1 ;;
    esac
    case $TAW_FALLBACK_MODE in
        none)
            if [[ $TAW_BIO_STATUS == unavailable ]]; then
                taw_hint "No fallback configured (FALLBACK_MODE=none) – access denied."
            fi
            return 1 ;;
        pin)
            taw_info "Biometrics not possible – using the PIN fallback."
            _taw_fallback_pin && TAW_AUTH_METHOD=pin && return 0
            return 1 ;;
        allow)
            taw_warn "INSECURE: FALLBACK_MODE=allow – access granted WITHOUT authentication!"
            TAW_AUTH_METHOD=fallback-allow
            return 0 ;;
    esac
    return 1
}

# --- Main entry point --------------------------------------------------------
# taw_authenticate <cache-key> <description> [non-interactive] [ignore cache]
taw_authenticate() {
    local key=$1 desc=$2 nonint=${3:-false} nocache=${4:-false} rc=1
    TAW_AUTH_METHOD=""

    if [[ $nocache != true ]] && taw_cache_valid "$key"; then
        TAW_AUTH_METHOD=cache
        taw_debug "Valid auth cache ($key) – no dialog needed"
        return 0
    fi
    if [[ $nonint == true ]]; then
        taw_err "Authentication required, but non-interactive mode is active (no valid cache)."
        taw_audit denied noninteractive "${TAW_AUDIT_DETAIL:-$desc}"
        return 1
    fi

    if ! taw_lock_acquire auth "$TAW_LOCK_TIMEOUT"; then
        taw_err "Timed out waiting for another authentication in progress (${TAW_LOCK_TIMEOUT}s)."
        return 1
    fi
    # A parallel call may have authenticated while we were waiting
    if [[ $nocache != true ]] && taw_cache_valid "$key"; then
        taw_lock_release
        TAW_AUTH_METHOD=cache
        return 0
    fi

    if taw_biometric_check "$desc"; then
        TAW_AUTH_METHOD=fingerprint
        rc=0
    elif _taw_fallback; then
        rc=0
    fi

    if (( rc == 0 )); then
        taw_cache_update "$key"
        taw_audit success "$TAW_AUTH_METHOD" "${TAW_AUDIT_DETAIL:-$desc}"
    else
        taw_audit denied "${TAW_BIO_STATUS:-error}" "${TAW_AUDIT_DETAIL:-$desc}"
    fi
    taw_lock_release
    return "$rc"
}

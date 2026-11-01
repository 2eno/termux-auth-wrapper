# shellcheck shell=bash
# shellcheck disable=SC2153  # TAW_*-Werte stammen aus taw_load_config
# =============================================================================
# termux-auth-wrapper – Authentifizierungs-Ablauf
#
#   taw_authenticate <cache-key> <Beschreibung> [nicht-interaktiv: true|false]
#
#   1. gültiger Auth-Cache (Gnadenfrist)?          -> OK, ohne Dialog
#   2. Lock holen (parallele Aufrufe aus Skripten teilen sich EINEN Dialog)
#   3. Fingerabdruck (check_biometric.sh)
#   4. ggf. Fallback (PIN / allow) laut Konfiguration
#   5. Cache aktualisieren, Audit-Log schreiben
# =============================================================================

[[ -n "${_TAW_AUTH_LOADED:-}" ]] && return 0
_TAW_AUTH_LOADED=1

_taw_auth_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/common.sh
source "$_taw_auth_dir/common.sh"
# shellcheck source=lib/check_biometric.sh
source "$_taw_auth_dir/check_biometric.sh"

TAW_AUTH_METHOD=""

# --- Auth-Cache --------------------------------------------------------------
_taw_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown'
}

# Kennung der Terminal-Sitzung (tty_nr + Session-ID aus /proc/self/stat).
# Funktioniert auch, wenn stdin/stdout umgeleitet sind (Skripte, Pipes).
_taw_session_id() {
    local stat rest
    stat=$(cat "/proc/$$/stat" 2>/dev/null) || { printf 'nosession'; return; }
    rest=${stat##*) }               # alles nach "(comm) "
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

# Alle Caches löschen (sudo -K, termux-auth reset)
taw_cache_clear_all() {
    rm -f "$TAW_RUNTIME_DIR"/auth-*.ts 2>/dev/null || true
}

taw_cache_clear() {
    rm -f "$(taw_cache_file "$1")" 2>/dev/null || true
}

# --- Fallback ----------------------------------------------------------------
taw_pin_hash() {
    # $1 = Salt, $2 = PIN
    printf '%s:%s' "$1" "$2" | sha256sum | cut -d' ' -f1
}

_taw_fallback_pin() {
    local stored=$TAW_FALLBACK_PIN_HASH salt hash pin try
    if [[ ! $stored =~ ^sha256:([A-Za-z0-9]+):([0-9a-f]{64})$ ]]; then
        taw_err "FALLBACK_MODE=pin, aber FALLBACK_PIN_HASH ist nicht gesetzt/ungültig."
        taw_hint "PIN festlegen mit: termux-auth set-pin"
        return 1
    fi
    salt=${BASH_REMATCH[1]}
    hash=${BASH_REMATCH[2]}
    if ! taw_have_tty; then
        taw_err "PIN-Fallback benötigt ein Terminal (/dev/tty) – im Hintergrund nicht möglich."
        return 1
    fi
    for try in 1 2 3; do
        printf '[%s] Fallback-PIN (%s/3): ' "$TAW_COMPONENT" "$try" >/dev/tty
        IFS= read -r -s pin </dev/tty || pin=""
        printf '\n' >/dev/tty
        if [[ -n $pin && $(taw_pin_hash "$salt" "$pin") == "$hash" ]]; then
            pin=""
            return 0
        fi
        taw_warn "Falsche PIN."
    done
    pin=""
    return 1
}

# Wird aufgerufen, wenn der Fingerabdruck nicht erfolgreich war.
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
                taw_hint "Kein Fallback konfiguriert (FALLBACK_MODE=none) – Zugriff verweigert."
            fi
            return 1 ;;
        pin)
            taw_info "Biometrie nicht möglich – PIN-Fallback."
            _taw_fallback_pin && TAW_AUTH_METHOD=pin && return 0
            return 1 ;;
        allow)
            taw_warn "UNSICHER: FALLBACK_MODE=allow – Zugriff OHNE Authentifizierung freigegeben!"
            TAW_AUTH_METHOD=fallback-allow
            return 0 ;;
    esac
    return 1
}

# --- Haupteinstieg -----------------------------------------------------------
# taw_authenticate <cache-key> <Beschreibung> [nicht-interaktiv] [cache ignorieren]
taw_authenticate() {
    local key=$1 desc=$2 nonint=${3:-false} nocache=${4:-false} rc=1
    TAW_AUTH_METHOD=""

    if [[ $nocache != true ]] && taw_cache_valid "$key"; then
        TAW_AUTH_METHOD=cache
        taw_debug "Gültiger Auth-Cache ($key) – kein Dialog nötig"
        return 0
    fi
    if [[ $nonint == true ]]; then
        taw_err "Authentifizierung erforderlich, aber nicht-interaktiver Modus aktiv (kein gültiger Cache)."
        taw_audit denied noninteractive "${TAW_AUDIT_DETAIL:-$desc}"
        return 1
    fi

    if ! taw_lock_acquire auth "$TAW_LOCK_TIMEOUT"; then
        taw_err "Zeitüberschreitung beim Warten auf eine andere laufende Authentifizierung (${TAW_LOCK_TIMEOUT}s)."
        return 1
    fi
    # Während wir gewartet haben, hat evtl. ein paralleler Aufruf authentifiziert
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

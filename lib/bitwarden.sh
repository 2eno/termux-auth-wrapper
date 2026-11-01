# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # TAW_*-Werte stammen aus taw_load_config
# =============================================================================
# termux-auth-wrapper – Bitwarden-CLI-Anbindung (optional)
#
#   taw_bw_ensure_unlocked            -> 0, wenn BW_SESSION gültig ist
#   taw_bw_get_secret <item> <typ>    -> setzt TAW_BW_SECRET / TAW_BW_SECRET_TYPE
#                                        (typ: password | key | auto)
#
# Geheimnisse werden ausschließlich in Variablen gehalten und nie geloggt.
# =============================================================================

[[ -n "${_TAW_BW_LOADED:-}" ]] && return 0
_TAW_BW_LOADED=1

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

TAW_BW_SECRET=""
TAW_BW_SECRET_TYPE=""
_TAW_BW_SESSION_FILE="$TAW_STATE_DIR/bw-session"

# bw mit Zeitlimit und ohne interaktive Rückfragen ausführen
_taw_bw() {
    local -a cmd=(bw)
    if command -v timeout >/dev/null 2>&1; then
        cmd=(timeout "$TAW_BW_TIMEOUT" bw)
    fi
    "${cmd[@]}" "$@" --nointeraction </dev/null
}

taw_bw_require() {
    if ! command -v bw >/dev/null 2>&1; then
        taw_err "Bitwarden CLI 'bw' nicht gefunden."
        taw_hint "Installation: pkg install nodejs && npm install -g @bitwarden/cli"
        taw_hint "Anschließend einmalig anmelden: bw login"
        return 1
    fi
    command -v jq >/dev/null 2>&1 || { taw_err "jq fehlt: pkg install jq"; return 1; }
}

# Gibt locked | unlocked | unauthenticated | error aus
taw_bw_status() {
    local out
    out=$(_taw_bw status 2>/dev/null) || { printf 'error'; return 0; }
    jq -r '.status // "error"' <<<"$out" 2>/dev/null || printf 'error'
}

_taw_bw_load_cached_session() {
    [[ -n ${BW_SESSION:-} ]] && return 0
    taw_is_true "$TAW_BW_SESSION_CACHE" || return 1
    [[ -f $_TAW_BW_SESSION_FILE && ! -L $_TAW_BW_SESSION_FILE ]] || return 1
    local s
    s=$(<"$_TAW_BW_SESSION_FILE")
    [[ -n $s ]] || return 1
    export BW_SESSION=$s
    taw_debug "BW_SESSION aus Cache geladen"
}

_taw_bw_store_session() {
    taw_is_true "$TAW_BW_SESSION_CACHE" || return 0
    taw_ensure_dir "$TAW_STATE_DIR" 700
    (umask 077; printf '%s' "$BW_SESSION" >"$_TAW_BW_SESSION_FILE") || \
        taw_warn "BW-Session konnte nicht zwischengespeichert werden."
}

taw_bw_forget_session() {
    rm -f "$_TAW_BW_SESSION_FILE" 2>/dev/null || true
}

_taw_bw_unlock_interactive() {
    local pw session rc=0
    if ! taw_have_tty; then
        taw_err "Bitwarden-Tresor ist gesperrt und es steht kein Terminal zur Passworteingabe zur Verfügung."
        return 1
    fi
    printf '[%s] Bitwarden Master-Passwort: ' "$TAW_COMPONENT" >/dev/tty
    IFS= read -r -s pw </dev/tty || pw=""
    printf '\n' >/dev/tty
    [[ -n $pw ]] || { taw_err "Kein Master-Passwort eingegeben."; return 1; }
    # Übergabe per Umgebungsvariable (--passwordenv) statt als Argument,
    # damit das Passwort nicht in der Prozessliste erscheint.
    session=$(TAW_BW_MASTER_PW=$pw _taw_bw unlock --raw --passwordenv TAW_BW_MASTER_PW 2>/dev/null) || rc=$?
    pw=""
    if (( rc != 0 )) || [[ -z $session ]]; then
        if (( rc == 124 )); then
            taw_err "Zeitüberschreitung beim Entsperren von Bitwarden (${TAW_BW_TIMEOUT}s)."
        else
            taw_err "Entsperren von Bitwarden fehlgeschlagen (falsches Master-Passwort?)."
        fi
        return 1
    fi
    export BW_SESSION=$session
    _taw_bw_store_session
    taw_ok "Bitwarden entsperrt."
}

taw_bw_ensure_unlocked() {
    taw_bw_require || return 1
    _taw_bw_load_cached_session || true

    local status
    status=$(taw_bw_status)
    taw_debug "Bitwarden-Status: $status"
    case $status in
        unlocked)
            return 0 ;;
        unauthenticated)
            taw_err "Nicht bei Bitwarden angemeldet."
            taw_hint "Einmalig ausführen: bw login"
            return 1 ;;
        locked)
            # Ggf. abgelaufene zwischengespeicherte Session verwerfen
            taw_bw_forget_session
            unset BW_SESSION
            if [[ $TAW_BW_UNLOCK_MODE == prompt ]]; then
                _taw_bw_unlock_interactive
                return
            fi
            taw_err "Bitwarden-Tresor ist gesperrt."
            taw_hint "Entsperren mit: export BW_SESSION=\"\$(bw unlock --raw)\""
            taw_hint "oder in der Konfiguration BW_UNLOCK_MODE=prompt setzen."
            return 1 ;;
        *)
            taw_err "Bitwarden-Status konnte nicht ermittelt werden (Timeout/Netzwerk/Installation?)."
            taw_hint "Manuell prüfen mit: bw status"
            return 1 ;;
    esac
}

# taw_bw_get_secret <item-id-oder-name> <password|key|auto>
taw_bw_get_secret() {
    local ref=$1 want=${2:-auto} item err rc=0
    TAW_BW_SECRET=""
    TAW_BW_SECRET_TYPE=""

    taw_bw_ensure_unlocked || return 1

    if taw_is_true "$TAW_BW_SYNC"; then
        _taw_bw sync >/dev/null 2>&1 || taw_warn "bw sync fehlgeschlagen – verwende lokalen Stand."
    fi

    taw_ensure_dir "$TAW_RUNTIME_DIR" 700
    local errfile
    errfile=$(mktemp "$TAW_RUNTIME_DIR/bw-err.XXXXXX")
    item=$(_taw_bw get item "$ref" 2>"$errfile") || rc=$?
    err=$(head -c 300 "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    if (( rc != 0 )) || [[ -z $item ]]; then
        taw_err "Bitwarden-Eintrag '$ref' konnte nicht gelesen werden${err:+: ${err//$'\n'/ }}"
        [[ $err == *"More than one"* ]] && taw_hint "Eindeutige Item-ID statt Namen verwenden (bw list items --search \"$ref\")."
        return 1
    fi

    local pw key
    pw=$(jq -r '.login.password // empty' <<<"$item")
    # SSH-Schlüssel: nativer Bitwarden-SSH-Key-Typ, Custom-Field oder Notiz
    key=$(jq -r '
        .sshKey.privateKey
        // ((.fields // []) | map(select(.name == "ssh_private_key" or .name == "private_key")) | .[0].value)
        // (if ((.notes // "") | test("-----BEGIN [A-Z ]*PRIVATE KEY-----")) then .notes else empty end)
        // empty' <<<"$item")
    item=""

    case $want in
        password)
            [[ -n $pw ]] || { taw_err "Eintrag '$ref' enthält kein Passwort."; return 1; }
            TAW_BW_SECRET=$pw; TAW_BW_SECRET_TYPE=password ;;
        key)
            [[ -n $key ]] || { taw_err "Eintrag '$ref' enthält keinen privaten SSH-Schlüssel."; return 1; }
            TAW_BW_SECRET=$key; TAW_BW_SECRET_TYPE=key ;;
        auto)
            if [[ -n $key ]]; then
                TAW_BW_SECRET=$key; TAW_BW_SECRET_TYPE=key
            elif [[ -n $pw ]]; then
                TAW_BW_SECRET=$pw; TAW_BW_SECRET_TYPE=password
            else
                taw_err "Eintrag '$ref' enthält weder Passwort noch SSH-Schlüssel."
                return 1
            fi ;;
        *)
            taw_err "Unbekannter Geheimnistyp '$want' (erlaubt: password, key, auto)."
            return 1 ;;
    esac
    pw=""; key=""
    taw_debug "Bitwarden-Geheimnis vom Typ '$TAW_BW_SECRET_TYPE' geladen"
    return 0
}

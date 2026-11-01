#!/usr/bin/env bash
# TERMUX_AUTH_WRAPPER_MARKER
# shellcheck disable=SC2153  # TAW_*-Werte stammen aus taw_load_config
# =============================================================================
# check_biometric.sh – zentrale Fingerabdruck-Prüfung via Termux:API
#
# Aufruf als Programm:
#     check_biometric [-d BESCHREIBUNG] [-t TITEL] [-q]
#     Exit-Code 0 = Fingerabdruck erfolgreich, 1 = Fehlschlag/nicht verfügbar
#
# Aufruf als Bibliothek (source):
#     taw_biometric_check "Beschreibung"   -> return 0/1
#     danach gesetzt: TAW_BIO_STATUS  (success | rejected | locked | unavailable)
#                     TAW_BIO_REASON  (menschenlesbarer Grund)
#
# Ausgewertet wird das JSON von termux-fingerprint, z. B.:
#     {"errors":[],"failed_attempts":0,"auth_result":"AUTH_RESULT_SUCCESS"}
# =============================================================================

# readlink -f: funktioniert auch, wenn das Skript per Symlink aufgerufen wird
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

TAW_BIO_STATUS=""
TAW_BIO_REASON=""

_taw_bio_set() {
    TAW_BIO_STATUS=$1
    TAW_BIO_REASON=$2
}

# Ein einzelner Dialog-Aufruf. Setzt TAW_BIO_STATUS/REASON.
_taw_bio_attempt() {
    local fp=$1 desc=$2 out errfile rc=0
    local -a cmd=()

    if command -v timeout >/dev/null 2>&1; then
        cmd=(timeout "$TAW_BIO_TIMEOUT")
    else
        taw_debug "'timeout' nicht verfügbar – Dialog läuft ohne Zeitlimit"
    fi
    cmd+=("$fp")
    # Titel/Beschreibung abschaltbar, falls eine termux-api-Version die
    # Optionen nicht kennt
    if taw_is_true "${TAW_BIO_DIALOG_TEXT:-true}"; then
        cmd+=(-t "${TAW_BIO_TITLE:-Termux-Authentifizierung}" -d "$desc")
    fi

    taw_ensure_dir "$TAW_RUNTIME_DIR" 700
    errfile=$(mktemp "$TAW_RUNTIME_DIR/fp-err.XXXXXX")
    # stdin von /dev/null: der Check darf niemals Daten aus einer Pipe
    # "stehlen" (z. B. bei: echo foo | sudo tee /datei)
    out=$("${cmd[@]}" </dev/null 2>"$errfile") || rc=$?
    local errtext
    errtext=$(head -c 300 "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    taw_debug "termux-fingerprint rc=$rc out=${out//$'\n'/ } err=${errtext//$'\n'/ }"

    if (( rc == 124 )); then
        _taw_bio_set unavailable "Keine Antwort von Termux:API innerhalb von ${TAW_BIO_TIMEOUT}s. Entweder wurde der Dialog nicht bestätigt, oder die App 'Termux:API' reagiert nicht (Quelle/Signatur, Akku-Einschränkung, nie geöffnet). Ursache eingrenzen mit: termux-auth diag"
        return 1
    fi
    if (( rc == 126 || rc == 127 )); then
        _taw_bio_set unavailable "termux-fingerprint konnte nicht ausgeführt werden (rc=$rc)."
        return 1
    fi
    if [[ -z ${out//[[:space:]]/} ]]; then
        _taw_bio_set unavailable "termux-fingerprint lieferte keine Ausgabe (rc=$rc)${errtext:+: $errtext}. Ist die App 'Termux:API' installiert und aus derselben Quelle wie Termux (F-Droid/GitHub)?"
        return 1
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
        _taw_bio_set unavailable "Unerwartete Ausgabe von termux-fingerprint (kein JSON): ${out:0:120}"
        return 1
    fi

    local result errors failed
    result=$(jq -r '.auth_result // "AUTH_RESULT_UNKNOWN"' <<<"$out")
    errors=$(jq -r '(.errors // []) | map(tostring) | join(",")' <<<"$out")
    failed=$(jq -r '.failed_attempts // 0' <<<"$out")

    case ",$errors," in
        *,ERROR_NO_HARDWARE,*)
            _taw_bio_set unavailable "Dieses Gerät hat keinen Fingerabdrucksensor (ERROR_NO_HARDWARE)."
            return 1 ;;
        *,ERROR_NO_ENROLLED_FINGERPRINTS,*)
            _taw_bio_set unavailable "Kein Fingerabdruck eingerichtet – in den Android-Einstellungen unter 'Sicherheit' hinzufügen (ERROR_NO_ENROLLED_FINGERPRINTS)."
            return 1 ;;
        *,ERROR_UNSUPPORTED_OS_VERSION,*)
            _taw_bio_set unavailable "Android-Version wird von termux-fingerprint nicht unterstützt (ERROR_UNSUPPORTED_OS_VERSION)."
            return 1 ;;
        *,ERROR_LOCKOUT,*|*,ERROR_TOO_MANY_FAILED_ATTEMPTS,*)
            _taw_bio_set locked "Sensor nach zu vielen Fehlversuchen gesperrt – bitte später erneut versuchen bzw. Gerät mit PIN entsperren."
            return 1 ;;
    esac

    if [[ $result == AUTH_RESULT_SUCCESS ]]; then
        _taw_bio_set success "Fingerabdruck bestätigt."
        return 0
    fi

    local why="Fingerabdruck nicht erkannt oder Dialog abgebrochen"
    [[ $failed != 0 ]] && why+=" ($failed Fehlversuch(e))"
    [[ -n $errors ]] && why+=" [$errors]"
    _taw_bio_set rejected "$why."
    return 1
}

# taw_biometric_check [Beschreibung]
taw_biometric_check() {
    local desc=${1:-"Bitte Identität bestätigen"} fp attempt

    if ! fp=$(command -v termux-fingerprint 2>/dev/null); then
        _taw_bio_set unavailable "termux-fingerprint nicht gefunden. Installation: 'pkg install termux-api' sowie die App 'Termux:API' (F-Droid/GitHub)."
        taw_err "$TAW_BIO_REASON"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _taw_bio_set unavailable "jq nicht gefunden. Installation: 'pkg install jq'."
        taw_err "$TAW_BIO_REASON"
        return 1
    fi

    for (( attempt = 1; attempt <= TAW_BIO_MAX_ATTEMPTS; attempt++ )); do
        if _taw_bio_attempt "$fp" "$desc"; then
            taw_debug "$TAW_BIO_REASON"
            return 0
        fi
        # Nur bei "rejected" erneut fragen – Sperre/Nichtverfügbarkeit ist endgültig
        if [[ $TAW_BIO_STATUS == rejected ]] && (( attempt < TAW_BIO_MAX_ATTEMPTS )); then
            taw_warn "$TAW_BIO_REASON Neuer Versuch ($((attempt + 1))/$TAW_BIO_MAX_ATTEMPTS) …"
            continue
        fi
        break
    done
    taw_err "$TAW_BIO_REASON"
    return 1
}

# --- Direkter Aufruf ---------------------------------------------------------
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    TAW_COMPONENT="check_biometric"

    _usage() {
        cat <<EOF
Aufruf: check_biometric [-d BESCHREIBUNG] [-t TITEL] [-q] [-h]

Zeigt den Android-Fingerabdruckdialog (termux-fingerprint) an.
Exit-Code 0 bei Erfolg, 1 bei Fehlschlag oder wenn keine Biometrie verfügbar ist.

  -d TEXT   Beschreibung im Dialog
  -t TEXT   Titel des Dialogs
  -q        keine Ausgaben (nur Exit-Code)
  -h        diese Hilfe

Beispiel in eigenen Skripten:
  if check_biometric -d "Backup löschen?"; then rm -rf ~/backup; fi
EOF
    }

    _desc="Bitte Identität bestätigen"
    _title=""
    while getopts ":d:t:qh" _opt; do
        case $_opt in
            d) _desc=$OPTARG ;;
            t) _title=$OPTARG ;;
            q) TAW_QUIET=true ;;
            h) _usage; exit 0 ;;
            :) taw_err "Option -$OPTARG benötigt ein Argument"; _usage >&2; exit 1 ;;
            *) taw_err "Unbekannte Option: -$OPTARG"; _usage >&2; exit 1 ;;
        esac
    done

    taw_load_config
    [[ -n $_title ]] && TAW_BIO_TITLE=$_title

    if [[ ${TAW_QUIET:-false} == true ]]; then
        taw_biometric_check "$_desc" 2>/dev/null && exit 0
        exit 1
    fi
    if taw_biometric_check "$_desc"; then
        taw_ok "$TAW_BIO_REASON"
        exit 0
    fi
    exit 1
fi

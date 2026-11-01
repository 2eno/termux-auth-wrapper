# termux-auth-wrapper

Fingerabdruck-Authentifizierung für `sudo` und `ssh` in **Termux** auf Android mit
**KernelSU** und **Termux:API**, optional mit Zugangsdaten aus der **Bitwarden CLI** (`bw`).

```
$ sudo iptables -L              ┌────────────────────────────┐
                                │  Termux-Authentifizierung  │
                                │  sudo – iptables -L        │
                                │       [ Fingerabdruck ]    │
                                └────────────────────────────┘
```

- **Transparent:** Die Wrapper heißen `sudo` und `ssh` und werden über die normale
  `$PATH`-Auflösung gefunden, also auch aus Shell-Skripten, cron-Jobs, `git`, `rsync` usw.
- **Update-sicher:** Alles liegt im Linux-Präfix (`$PREFIX`) bzw. im `$HOME`, die Termux-APK
  wird nie verändert. Paket-Updates (`pkg upgrade openssh`) überschreiben die Wrapper nicht
  (`dpkg-divert` plus Selbstreparatur per apt-Hook).
- **Skriptfähig:** stdin/stdout/stderr und Exit-Codes werden unverändert durchgereicht.
  Eine Gnadenfrist (Auth-Cache) und ein Lock sorgen dafür, dass parallele Aufrufe aus einem
  Skript nur **einen** Dialog auslösen.
- **Konfigurierbar:** Eine einzige Datei regelt Timeouts, Cache, Fallbacks und Bitwarden.
- **Klare Fehlermeldungen,** z. B. wenn Termux:API fehlt, kein Fingerabdruck eingerichtet ist
  oder der Bitwarden-Tresor gesperrt ist.

---

## Inhalt

1. [Sicherheitsmodell](#sicherheitsmodell)
2. [Voraussetzungen](#voraussetzungen)
3. [Installation](#installation)
4. [Funktionsweise](#funktionsweise)
5. [Konfiguration](#konfiguration)
6. [Bitwarden einrichten](#bitwarden-einrichten)
7. [Verwendung in Skripten](#verwendung-in-skripten)
8. [Update-Sicherheit](#update-sicherheit)
9. [Verwaltung: `termux-auth`](#verwaltung-termux-auth)
10. [Fehlerbehebung](#fehlerbehebung)
11. [Deinstallation](#deinstallation)
12. [Entwicklung & Tests](#entwicklung--tests)
13. [Bekannte Einschränkungen](#bekannte-einschränkungen)

---

## Sicherheitsmodell

Bitte zuerst lesen, damit klar ist, was das Tool leistet und was nicht.

**Es schützt vor**
- jemandem, der dein **entsperrtes** Telefon in der Hand hat und in Termux `sudo …` oder
  `ssh server` eintippt,
- versehentlich oder unbeaufsichtigt laufenden Skripten, die ohne deine Bestätigung root-Rechte
  oder SSH-Zugänge benutzen würden,
- Klartext-Passwörtern in Skripten oder `~/.ssh/config`, weil Zugangsdaten erst **nach** dem
  Fingerabdruck aus Bitwarden geholt werden.

**Es ist keine harte Sicherheitsgrenze gegen Code, der bereits als Termux-Benutzer läuft.**
Alle Termux-Prozesse teilen sich dieselbe Android-UID. Ein bösartiges Programm in Termux
könnte `/system/bin/su` oder das echte `ssh` direkt aufrufen und die Wrapper damit umgehen.
Dasselbe gilt für Auth-Cache und Konfiguration. Dagegen hilft nur die Root-Verwaltung von
KernelSU selbst, also Termux nur bei Bedarf Root-Rechte zu geben.

Weitere Designentscheidungen:
- Die Konfiguration wird **geparst, nicht ausgeführt** (kein `source`).
- Geheimnisse landen nie in `argv`. Passwörter gehen per Dateideskriptor an `sshpass -d`, das
  Bitwarden-Master-Passwort per `--passwordenv`. Private Schlüssel landen im `ssh-agent` (mit
  Ablaufzeit) oder in einer `0600`-Datei, die nach dem Ende von ssh überschrieben und gelöscht wird.
- Ein Fehlschlag verweigert standardmäßig den Zugriff (`FALLBACK_MODE=none`).
- Ein Audit-Log protokolliert jede Authentifizierung, ohne Geheimnisse.

---

## Voraussetzungen

| Komponente | Zweck | Installation |
|---|---|---|
| Termux (F-Droid oder GitHub) | Basis | – |
| **Termux:API-App** | Fingerabdruckdialog | aus **derselben Quelle** wie Termux (Signatur muss passen) |
| `termux-api` | `termux-fingerprint` | `pkg install termux-api` |
| `jq` | JSON-Auswertung | `pkg install jq` |
| `coreutils` | `timeout`, `sha256sum` | (vorinstalliert) |
| KernelSU | root via `su` | Termux in der KernelSU-App unter *Superuser* freigeben |
| `openssh` | ssh-Wrapper | `pkg install openssh` |
| `sshpass` *(optional)* | Passwort-Logins mit Bitwarden | `pkg install sshpass` |
| Bitwarden CLI *(optional)* | Zugangsdaten | `pkg install nodejs && npm install -g @bitwarden/cli` |

Außerdem muss auf dem Gerät mindestens ein Fingerabdruck eingerichtet sein.

---

## Installation

```bash
pkg install git
git clone https://github.com/2eno/termux-auth-wrapper.git
cd termux-auth-wrapper
./install.sh --install-deps
```

Danach:

```bash
termux-auth doctor   # Zustand, Abhängigkeiten, su- und Bitwarden-Test
termux-auth test     # Fingerabdruckdialog testen
sudo id              # -> uid=0(root) …
```

### Installationsmodi

| Modus | Wrapper-Ort | Greift für | Empfehlung |
|---|---|---|---|
| `--mode prefix` *(Standard)* | `$PREFIX/bin` | **alle** Prozesse, auch Termux:Boot, Termux:Widget, crond, `scp` | ✅ |
| `--mode home` | `~/.bin` (+ PATH-Eintrag in `~/.bashrc`, `~/.profile`, `~/.zshrc`) | nur Prozesse aus Shells mit angepasstem `PATH` | wenn `$PREFIX/bin` tabu sein soll |

### Optionen von `install.sh`

```
--mode prefix|home   Installationsmodus (siehe oben)
--only sudo|ssh      nur einen Wrapper installieren (mehrfach möglich)
--no-sudo / --no-ssh einen Wrapper auslassen
--install-deps       fehlende Pakete per pkg installieren
--skip-deps          Abhängigkeitsprüfung überspringen
--no-apt-hook        keinen apt-Hook zur Selbstreparatur anlegen
-y, --yes            keine Rückfragen
```

Das Skript ist **idempotent**: Ein erneuter Aufruf, etwa nach `git pull`, aktualisiert
Bibliothek und Wrapper und lässt die Konfiguration unangetastet.

---

## Funktionsweise

### Repository-Struktur

```
termux-auth-wrapper/
├── install.sh                  Installation (Abhängigkeiten, Verzeichnisse, Wrapper)
├── uninstall.sh                Deinstallation (stellt Originale wieder her)
├── lib/
│   ├── check_biometric.sh      zentrale Fingerabdruck-Prüfung (Exit 0/1)
│   ├── common.sh               Pfade, Logging, Konfig-Parser, Binary-Suche, Lock, Audit
│   ├── auth.sh                 Ablauf: Cache -> Lock -> Fingerabdruck -> Fallback
│   ├── bitwarden.sh            bw-Status, Entsperren, Geheimnisse abrufen
│   └── install-lib.sh          Platzieren/Reparieren/Entfernen der Wrapper
├── wrappers/
│   ├── sudo                    sudo-Wrapper (KernelSU: su -c)
│   └── ssh                     ssh-Wrapper (Bitwarden, sshpass, ssh-agent)
├── bin/termux-auth             Verwaltungswerkzeug
├── config/
│   ├── config.conf.example     Vorlage der Konfiguration
│   └── ssh-hosts.conf.example  Vorlage: Host -> Bitwarden-Eintrag
└── tests/                      Testsuite mit Mocks (läuft auf jedem Linux)
```

### Installierte Dateien

```
$PREFIX/bin/sudo, $PREFIX/bin/ssh          Wrapper
$PREFIX/bin/termux-auth                    -> Verwaltungswerkzeug
$PREFIX/bin/check_biometric                -> lib/check_biometric.sh (für eigene Skripte)
$PREFIX/lib/termux-auth-wrapper/           Bibliotheken, Wrapper-Vorlagen, install.state
$PREFIX/libexec/termux-auth-wrapper/ssh    Original-ssh (per dpkg-divert umgeleitet)
$PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper   Selbstreparatur nach pkg-Läufen
~/.config/termux-auth-wrapper/config.conf  Konfiguration
~/.config/termux-auth-wrapper/ssh-hosts.conf
~/.local/state/termux-auth-wrapper/audit.log
$TMPDIR/termux-auth-wrapper-<uid>/         Auth-Cache, Locks (flüchtig)
```

### Ablauf

```
sudo BEFEHL / ssh HOST
        │
        ▼
 gültiger Auth-Cache? ──ja──────────────────────────────┐
        │ nein                                          │
        ▼                                               │
 Lock holen (parallele Aufrufe warten hier)             │
        │                                               │
        ▼                                               │
 check_biometric.sh ─ termux-fingerprint ─ jq           │
        │                                               │
   Erfolg? ──nein──> Fallback (none | pin | allow) ─────┤
        │ ja                       │ verweigert         │
        ▼                          ▼                    │
 Cache + Audit-Log           Fehler, Exit 1/255         │
        │                                               │
        ▼◄──────────────────────────────────────────────┘
 sudo: exec su -c "<Termux-Umgebung>; exec <BEFEHL>"
 ssh : [Bitwarden -> sshpass | ssh-agent | -i tmpfile]  exec ssh-Original
```

### `check_biometric.sh`

Zentrales Prüfskript, auch für eigene Skripte nutzbar:

```bash
check_biometric -d "Backup wirklich löschen?" && rm -rf ~/backup
```

Es ruft `termux-fingerprint` mit Zeitlimit und `stdin=/dev/null` auf (damit kein Pipe-Input
„gestohlen“ wird) und wertet das JSON mit `jq` aus:

```json
{"errors": [], "failed_attempts": 0, "auth_result": "AUTH_RESULT_SUCCESS"}
```

| Ergebnis | Exit | interner Status |
|---|---|---|
| `AUTH_RESULT_SUCCESS` | 0 | `success` |
| Finger nicht erkannt / abgebrochen | 1 | `rejected` (wird bis `BIO_MAX_ATTEMPTS` wiederholt) |
| `ERROR_LOCKOUT`, `ERROR_TOO_MANY_FAILED_ATTEMPTS` | 1 | `locked` |
| `ERROR_NO_HARDWARE`, `ERROR_NO_ENROLLED_FINGERPRINTS`, Timeout, kein/ungültiges JSON, Befehl fehlt | 1 | `unavailable` (Fallback möglich) |

### `sudo`-Wrapper

Unterstützt die gängigen Optionen:

```
sudo BEFEHL …              Befehl als root
sudo FOO=bar BEFEHL        Umgebungsvariablen setzen
sudo -u BENUTZER BEFEHL    als anderer Benutzer (su BENUTZER)
sudo -E BEFEHL             gesamte Umgebung erhalten (su -p)
sudo -s [BEFEHL]           Root-Shell bzw. Befehl über Shell
sudo -i                    Login-Shell als root
sudo -n BEFEHL             nie Dialog zeigen, nur gültigen Cache nutzen
sudo -v                    authentifizieren und Cache auffrischen
sudo -k [BEFEHL]           Cache verwerfen
sudo -K                    alle Caches löschen
```

Auf der Root-Seite wird die Termux-Umgebung (`PATH`, `PREFIX`, `TERM`, `LD_PRELOAD`, …)
gesetzt, damit Termux-Programme auch als root funktionieren. `HOME` zeigt standardmäßig auf
`~/.suroot`, so wie bei `tsu`, damit root keine Dateien in dein `$HOME` schreibt.
Argumente werden POSIX-sicher gequotet (getestet mit Leerzeichen, `'`, `"`, `$`, `` ` ``, `;`).

### `ssh`-Wrapper

1. Das Ziel wird über `ssh -G` aufgelöst, damit Aliasse aus `~/.ssh/config`, `-l` und `-p`
   korrekt berücksichtigt werden.
2. `ssh -V/-G/-Q/-O` und Hosts in `SSH_SKIP_HOSTS` werden ohne Dialog durchgereicht.
3. Fingerabdruck bzw. gültiger Cache.
4. Ist dem Host in `ssh-hosts.conf` ein Bitwarden-Eintrag zugeordnet:
   - **Passwort:** `sshpass -d 3 ssh -o NumberOfPasswordPrompts=1 …`, das Passwort kommt über FD 3.
   - **Schlüssel:** `ssh-add -t <Lebensdauer> -` in einen laufenden `ssh-agent`, sonst eine
     temporäre `0600`-Datei plus `-i … -o IdentitiesOnly=yes`.
5. Exit-Code wie bei ssh (`255` bei Verbindungs- oder Authentifizierungsfehlern).

---

## Konfiguration

Datei: `~/.config/termux-auth-wrapper/config.conf` (bearbeiten mit `termux-auth config edit`).
Die Vorlage mit allen Kommentaren liegt unter `config/config.conf.example`.

Jeder Schlüssel lässt sich pro Aufruf per Umgebungsvariable `TAW_<SCHLÜSSEL>` überschreiben:

```bash
TAW_DEBUG=true sudo id
TAW_AUTH_CACHE_TIMEOUT=0 ssh server     # diesmal garantiert Fingerabdruck
```

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `BIO_TITLE` | `Termux-Authentifizierung` | Titel des Dialogs |
| `BIO_TIMEOUT` | `30` | Sekunden bis zum Abbruch des Dialogs (auch Schutz vor Hängern bei fehlender Termux:API) |
| `BIO_MAX_ATTEMPTS` | `2` | Wiederholungen bei „nicht erkannt/abgebrochen“ |
| `AUTH_CACHE_TIMEOUT` | `300` | Gnadenfrist in Sekunden; `0` = immer fragen |
| `AUTH_CACHE_SCOPE` | `session` | `session` = pro Terminal-Sitzung (Skripte erben sie), `global` = überall |
| `AUTH_CACHE_SHARED` | `false` | gemeinsamer Cache für sudo **und** ssh |
| `LOCK_TIMEOUT` | `120` | Wartezeit paralleler Aufrufe auf einen laufenden Dialog |
| `FALLBACK_MODE` | `none` | bei nicht verfügbarer Biometrie: `none` / `pin` / `allow` (unsicher) |
| `FALLBACK_ON_REJECT` | `false` | Fallback auch nach abgelehntem Fingerabdruck |
| `FALLBACK_PIN_HASH` | – | wird von `termux-auth set-pin` gesetzt |
| `SUDO_ENABLED` | `true` | sudo-Wrapper aktiv |
| `SU_BINARY` | `auto` | `/system/bin/su` (KernelSU), `/data/adb/ksu/bin/su`, … |
| `SUDO_PRESERVE_TERMUX_ENV` | `true` | Termux-Umgebung auf der Root-Seite setzen |
| `SUDO_HOME` | `suroot` | `suroot` (`~/.suroot`), `keep` oder ein Pfad |
| `SUDO_SHELL` | `auto` | Shell für `sudo -s/-i` (`$PREFIX/bin/bash`) |
| `SUDO_MOUNT_MASTER` | `false` | KernelSU `-M` (globaler Mount-Namespace) |
| `SUDO_WARN_PKG` | `true` | warnen bei `sudo pkg/apt` |
| `SSH_ENABLED` | `true` | ssh-Wrapper aktiv |
| `SSH_BINARY` | `auto` | Pfad zum echten ssh |
| `SSH_AUTH_SCOPE` | `all` | `all` = jede Verbindung, `mapped` = nur Hosts aus `ssh-hosts.conf` |
| `SSH_SKIP_HOSTS` | – | Host-Globs ohne Dialog, z. B. `"github.com gitlab.com *.lan"` |
| `SSH_KEY_METHOD` | `auto` | `agent` / `tempfile` / `auto` |
| `SSH_AGENT_KEY_LIFETIME` | `300` | Lebensdauer von Schlüsseln im Agent (s) |
| `BW_ENABLED` | `false` | Bitwarden verwenden |
| `BW_UNLOCK_MODE` | `prompt` | gesperrt: Master-Passwort abfragen (`prompt`) oder abbrechen (`never`) |
| `BW_SESSION_CACHE` | `false` | `BW_SESSION` in einer `0600`-Datei merken |
| `BW_TIMEOUT` | `60` | Zeitlimit für bw-Aufrufe |
| `BW_SYNC` | `false` | vor dem Abruf `bw sync` |
| `BW_FALLBACK` | `prompt` | wenn Bitwarden nichts liefert: normal weiter (`prompt`) oder abbrechen (`fail`) |
| `AUDIT_LOG` | `true` | Audit-Log schreiben |
| `AUDIT_LOG_ARGS` | `false` | volle sudo-Befehlszeilen loggen |
| `DEBUG` | `false` | ausführliche Ausgaben |
| `COLOR` | `auto` | `auto` / `always` / `never` |

### Fallback-PIN

```bash
termux-auth set-pin                  # PIN zweimal eingeben -> gesalzener SHA-256-Hash
termux-auth config edit              # FALLBACK_MODE=pin setzen
```

Die PIN ist nur ein Notbehelf für Geräte oder Situationen ohne Biometrie. Sie wird nur bei
`unavailable` angeboten (bei `rejected` nur mit `FALLBACK_ON_REJECT=true`) und braucht ein Terminal.

---

## Bitwarden einrichten

```bash
pkg install nodejs sshpass
npm install -g @bitwarden/cli
bw config server https://vault.bitwarden.eu   # nur bei EU-/Self-Hosted-Server
bw login
```

1. In der Konfiguration `BW_ENABLED=true` setzen.
2. Die Item-ID heraussuchen:
   ```bash
   bw list items --search "Mein Server" | jq -r '.[] | "\(.id)  \(.name)"'
   ```
3. Die Zuordnung in `~/.config/termux-auth-wrapper/ssh-hosts.conf` eintragen:
   ```
   # <host-muster>   <bitwarden-item>                       [password|key|auto]
   homeserver        0b8c5d6e-1111-2222-3333-abcdefabcdef   password
   pi@192.168.178.*  "Raspberry Pi"                         password
   *.example.org     7f3e2a10-4444-5555-6666-abcdefabcdef   key
   ```
   Muster werden gegen den Alias, den aufgelösten Hostnamen und `user@host` geprüft.
   Die erste passende Zeile gewinnt.

Schlüssel werden in dieser Reihenfolge gesucht: nativer **SSH-Key-Eintrag** von Bitwarden
(`sshKey.privateKey`), Custom-Field `ssh_private_key`, Notiz mit `-----BEGIN … PRIVATE KEY-----`.

**Entsperren:**
- `BW_UNLOCK_MODE=prompt`: Bei gesperrtem Tresor fragt der Wrapper **nach** dem Fingerabdruck
  im Terminal nach dem Master-Passwort.
- `BW_UNLOCK_MODE=never`: Die Session muss vorher exportiert sein:
  `export BW_SESSION="$(bw unlock --raw)"`
- `BW_SESSION_CACHE=true` merkt sich die Session über Shells hinweg. `termux-auth reset --bw`
  verwirft sie wieder und sperrt den Tresor.

Für einen einzelnen Aufruf: `TAW_BW_ITEM=<id> TAW_BW_TYPE=key ssh host`

---

## Verwendung in Skripten

Weil die Wrapper `sudo` und `ssh` heißen, braucht man in bestehenden Skripten nichts zu ändern:

```bash
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
sudo mount -o remount,rw /data/local/tmp   # -> Fingerabdruck
sudo cp config.xml /data/local/tmp/        # -> innerhalb der Gnadenfrist kein weiterer Dialog
ssh backup@nas 'df -h'                      # -> eigener Cache für ssh
echo "data" | sudo tee /data/local/tmp/x    # stdin funktioniert
```

Tipps:
- **Hintergrundjobs** (Termux:Boot, crond, Termux:Widget) teilen sich keine Terminal-Sitzung.
  Mit `AUTH_CACHE_SCOPE=global` gilt eine Bestätigung auch für sie.
- **Vorab authentifizieren:** `sudo -v` am Skriptanfang, danach greift der Cache.
- **Nie blockieren:** `sudo -n …` schlägt sofort fehl, wenn kein gültiger Cache existiert.
- **Parallele Aufrufe** (`cmd1 & cmd2 &`) lösen nur einen Dialog aus, die übrigen warten auf
  das Ergebnis.
- Eigene Bestätigungen: `check_biometric -d "Text"` (Exit 0/1).

---

## Update-Sicherheit

| Ereignis | Auswirkung |
|---|---|
| Update der **Termux-App** (APK) | keine, denn die Wrapper liegen in `$PREFIX`/`$HOME` und nicht in der APK |
| Update der **Termux:API-App** | keine |
| `pkg upgrade openssh` | `$PREFIX/bin/ssh` ist per `dpkg-divert --local --rename` umgeleitet, dpkg schreibt das neue Binary nach `$PREFIX/libexec/termux-auth-wrapper/ssh` und der Wrapper bleibt stehen |
| Wrapper trotzdem überschrieben/gelöscht | der apt-Hook `DPkg::Post-Invoke` führt nach jedem pkg-Lauf `termux-auth repair --quiet` aus: das neue Binary wird gesichert und der Wrapper wiederhergestellt |
| `git pull` im Repository | `./install.sh -y` aktualisiert Bibliothek und Wrapper, die Konfiguration bleibt |

Manuell prüfen: `termux-auth status`, reparieren: `termux-auth repair`.

---

## Verwaltung: `termux-auth`

```
termux-auth status          Installationszustand, PATH-Auflösung, Abhängigkeiten, Konfiguration
termux-auth doctor          wie status, plus Live-Test von su -c und Bitwarden
termux-auth test            Fingerabdruckdialog testen
termux-auth reset [--bw]    Auth-Cache löschen (--bw: Bitwarden-Session verwerfen + bw lock)
termux-auth set-pin         Fallback-PIN festlegen
termux-auth repair [-q]     Wrapper prüfen/wiederherstellen
termux-auth config [edit]   Konfigurationspfade anzeigen / im $EDITOR öffnen
termux-auth log [N]         letzte N Audit-Log-Einträge
```

---

## Fehlerbehebung

| Meldung | Ursache und Lösung |
|---|---|
| `termux-fingerprint nicht gefunden` | `pkg install termux-api` |
| `Keine Antwort von Termux:API innerhalb von 30s` | Die **App** Termux:API fehlt oder stammt aus einer anderen Quelle als Termux (F-Droid und GitHub nicht mischen). Bei Aufrufen aus dem Hintergrund kann Android den Dialog blockieren, dann Termux/Termux:API die Berechtigung *Über anderen Apps einblenden* geben. |
| `lieferte keine Ausgabe` / `kein JSON` | Termux:API-App installieren oder aktualisieren, die Versionen von App und Paket `termux-api` sollten zusammenpassen |
| `keinen Fingerabdrucksensor` | Gerät ohne Sensor, ggf. `FALLBACK_MODE=pin` |
| `Kein Fingerabdruck eingerichtet` | Android-Einstellungen → Sicherheit → Fingerabdruck |
| `Sensor … gesperrt` | zu viele Fehlversuche, Gerät mit PIN entsperren und später erneut versuchen |
| `Kein su-Binary gefunden` | KernelSU-App → Superuser → Termux freigeben, ggf. `SU_BINARY` setzen |
| `Bitwarden-Tresor ist gesperrt` | `export BW_SESSION="$(bw unlock --raw)"` oder `BW_UNLOCK_MODE=prompt` |
| `Nicht bei Bitwarden angemeldet` | `bw login` |
| `More than one result` | in `ssh-hosts.conf` die Item-**ID** statt des Namens verwenden |
| `sshpass nicht installiert` | `pkg install sshpass` |
| `sudo`/`ssh` fragt nicht nach dem Fingerabdruck | `termux-auth status` zeigt die PATH-Auflösung; mit `hash -r` den Befehls-Cache der Shell leeren |
| allgemein | `TAW_DEBUG=true sudo id` zeigt jeden Schritt |

---

## Deinstallation

```bash
$PREFIX/lib/termux-auth-wrapper/uninstall.sh          # Konfiguration bleibt
$PREFIX/lib/termux-auth-wrapper/uninstall.sh --purge  # alles inkl. Konfiguration und Log
```

Umgeleitete Originale (z. B. `ssh`) werden per `dpkg-divert --remove` zurückgelegt.

---

## Entwicklung & Tests

```bash
tests/run_tests.sh       # oder: tests/run_tests.sh -v
```

Die Testsuite läuft auf jedem Linux mit `bash` und `jq`. Sie baut ein Fake-Termux-Präfix auf
und ersetzt `termux-fingerprint`, `su`, `ssh`, `sshpass`, `bw` und `dpkg-divert` durch Mocks.
Geprüft werden unter anderem:
- alle Biometrie-Ergebnisse inklusive Timeout,
- das Quoting von Sonderzeichen,
- stdin- und Exit-Code-Durchreichung,
- Cache, Lock und parallele Aufrufe,
- Fallbacks und die PIN-Abfrage (über ein Pseudo-Terminal),
- Bitwarden (gesperrt, entsperren, Passwort, Schlüssel),
- `repair` nach einem simulierten `pkg upgrade`, `dpkg-divert`, home-Modus und Deinstallation.

Mit installiertem `shellcheck` wird zusätzlich statisch geprüft. Der GitHub-Workflow unter
`.github/workflows/test.yml` führt beides aus.

---

## Bekannte Einschränkungen

- Der Fingerabdruckdialog ist eine Android-Activity. Läuft Termux komplett im Hintergrund,
  kann Android ihn verzögern oder blockieren (siehe Fehlerbehebung). Nach einem Timeout kann
  der Dialog sichtbar bleiben, das Ergebnis wird dann ignoriert.
- `scp`/`sftp` rufen ssh über einen fest einkompilierten Pfad (`$PREFIX/bin/ssh`) auf. Im
  prefix-Modus läuft das also über den Wrapper, im home-Modus nicht.
- `ssh -J` (ProxyJump) startet intern ein weiteres `ssh`. Innerhalb der Gnadenfrist gibt es
  keinen zweiten Dialog, mit `AUTH_CACHE_TIMEOUT=0` dagegen schon.
- Der sudo-Wrapper kennt nur die oben genannten Optionen. `sudoers`, `-e` (sudoedit) und `-b`
  werden nicht unterstützt.
- Mit `--mode home` umgehen Prozesse, die ohne deinen Shell-PATH starten, die Wrapper.

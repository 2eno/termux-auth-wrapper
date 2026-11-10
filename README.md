# termux-auth-wrapper

*English · [Deutsch](README.de.md)*

Fingerprint authentication for `sudo` and `ssh` in **Termux** on Android with
**KernelSU** and **Termux:API**, optionally with credentials from the **Bitwarden CLI** (`bw`).

```
$ sudo iptables -L              ┌────────────────────────────┐
                                │  Termux authentication     │
                                │  sudo – iptables -L        │
                                │       [ fingerprint ]      │
                                └────────────────────────────┘
```

- **Transparent:** the wrappers are called `sudo` and `ssh` and are found through the normal
  `$PATH` lookup – so also from shell scripts, cron jobs, `git`, `rsync` etc.
- **Update-safe:** everything lives in the Linux prefix (`$PREFIX`) or in `$HOME`; the Termux APK
  is never modified. Package updates (`pkg upgrade openssh`) don’t overwrite the wrappers
  (`dpkg-divert` plus self-repair via an apt hook).
- **Scriptable:** stdin/stdout/stderr and exit codes are passed through unchanged. A grace period
  (auth cache) and a lock make sure parallel calls from a script trigger only **one** dialog.
- **Configurable:** a single file controls timeouts, cache, fallbacks and Bitwarden.
- **Clear error messages,** e.g. when Termux:API is missing, no fingerprint is enrolled or the
  Bitwarden vault is locked.

---

## Contents

1. [Security model](#security-model)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [How it works](#how-it-works)
5. [Configuration](#configuration)
6. [Setting up Bitwarden](#setting-up-bitwarden)
7. [Use in scripts](#use-in-scripts)
8. [Update safety](#update-safety)
9. [Management: `termux-auth`](#management-termux-auth)
10. [Troubleshooting](#troubleshooting)
11. [Uninstalling](#uninstalling)
12. [Development & tests](#development--tests)
13. [Known limitations](#known-limitations)

---

## Security model

Please read this first so it’s clear what the tool does and what it doesn’t.

**It protects against**
- someone who holds your **unlocked** phone and types `sudo …` or `ssh server` in Termux,
- scripts running by accident or unattended that would use root or SSH access without your
  confirmation,
- plain-text passwords in scripts or `~/.ssh/config`, because credentials are only fetched from
  Bitwarden **after** the fingerprint.

**It is not a hard security boundary against code already running as the Termux user.**
All Termux processes share the same Android UID. A malicious program in Termux could call
`/system/bin/su` or the real `ssh` directly and bypass the wrappers. The same applies to the auth
cache and the configuration. Only KernelSU’s own root management helps here, i.e. granting Termux
root only when needed.

Further design decisions:
- The configuration is **parsed, not executed** (no `source`).
- Secrets never end up in `argv`. Passwords go to `sshpass -d` through a file descriptor, the
  Bitwarden master password through `--passwordenv`. Private keys go into `ssh-agent` (with an
  expiry) or into a `0600` file that is overwritten and deleted after ssh exits.
- A failure denies access by default (`FALLBACK_MODE=none`).
- An audit log records every authentication, without secrets.

---

## Requirements

| Component | Purpose | Installation |
|---|---|---|
| Termux (F-Droid or GitHub) | base | – |
| **Termux:API app** | fingerprint dialog | from the **same source** as Termux (signatures must match) |
| `termux-api` | `termux-fingerprint` | `pkg install termux-api` |
| `jq` | JSON parsing | `pkg install jq` |
| `coreutils` | `timeout`, `sha256sum` | (preinstalled) |
| KernelSU | root via `su` | grant Termux under *Superuser* in the KernelSU app |
| `openssh` | ssh wrapper | `pkg install openssh` |
| `sshpass` *(optional)* | password logins with Bitwarden | `pkg install sshpass` |
| Bitwarden CLI *(optional)* | credentials | `pkg install nodejs && npm install -g @bitwarden/cli` |

At least one fingerprint must also be enrolled on the device.

---

## Installation

```bash
pkg install git
git clone https://github.com/2eno/termux-auth-wrapper.git
cd termux-auth-wrapper
./install.sh --install-deps
```

Then:

```bash
termux-auth doctor   # state, dependencies, su and Bitwarden test
termux-auth test     # test the fingerprint dialog
sudo id              # -> uid=0(root) …
```

### Installation modes

| Mode | Wrapper location | Applies to | Recommendation |
|---|---|---|---|
| `--mode prefix` *(default)* | `$PREFIX/bin` | **all** processes, including Termux:Boot, Termux:Widget, crond, `scp` | ✅ |
| `--mode home` | `~/.bin` (+ PATH entry in `~/.bashrc`, `~/.profile`, `~/.zshrc`) | only processes from shells with the adjusted `PATH` | if `$PREFIX/bin` is off limits |

### `install.sh` options

```
--mode prefix|home   installation mode (see above)
--only sudo|ssh      install only one wrapper (can be repeated)
--no-sudo / --no-ssh leave out one wrapper
--install-deps       install missing packages with pkg
--skip-deps          skip the dependency check
--no-apt-hook        don't create the apt hook for self-repair
-y, --yes            no questions
```

The script is **idempotent**: running it again, e.g. after `git pull`, updates the library and the
wrappers and leaves the configuration untouched.

---

## How it works

### Repository layout

```
termux-auth-wrapper/
├── install.sh                  installation (dependencies, directories, wrappers)
├── uninstall.sh                uninstall (restores the originals)
├── lib/
│   ├── check_biometric.sh      central fingerprint check (exit 0/1)
│   ├── common.sh               paths, logging, config parser, binary lookup, lock, audit
│   ├── auth.sh                 flow: cache -> lock -> fingerprint -> fallback
│   ├── bitwarden.sh            bw status, unlocking, fetching secrets
│   └── install-lib.sh          placing/repairing/removing the wrappers
├── wrappers/
│   ├── sudo                    sudo wrapper (KernelSU: su -c)
│   └── ssh                     ssh wrapper (Bitwarden, sshpass, ssh-agent)
├── bin/termux-auth             management tool
├── config/
│   ├── config.conf.example     configuration template
│   └── ssh-hosts.conf.example  template: host -> Bitwarden item
└── tests/                      test suite with mocks (runs on any Linux)
```

### Installed files

```
$PREFIX/bin/sudo, $PREFIX/bin/ssh          wrappers
$PREFIX/bin/termux-auth                    -> management tool
$PREFIX/bin/check_biometric                -> lib/check_biometric.sh (for your own scripts)
$PREFIX/lib/termux-auth-wrapper/           libraries, wrapper templates, install.state
$PREFIX/libexec/termux-auth-wrapper/ssh    original ssh (diverted with dpkg-divert)
$PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper   self-repair after pkg runs
~/.config/termux-auth-wrapper/config.conf  configuration
~/.config/termux-auth-wrapper/ssh-hosts.conf
~/.local/state/termux-auth-wrapper/audit.log
$TMPDIR/termux-auth-wrapper-<uid>/         auth cache, locks (volatile)
```

### Flow

```
sudo COMMAND / ssh HOST
        │
        ▼
 valid auth cache? ──yes────────────────────────────────┐
        │ no                                            │
        ▼                                               │
 take the lock (parallel calls wait here)               │
        │                                               │
        ▼                                               │
 check_biometric.sh ─ termux-fingerprint ─ jq           │
        │                                               │
   success? ──no──> fallback (none | pin | allow) ──────┤
        │ yes                      │ denied             │
        ▼                          ▼                    │
 cache + audit log           error, exit 1/255          │
        │                                               │
        ▼◄──────────────────────────────────────────────┘
 sudo: exec su -c "<Termux environment>; exec <COMMAND>"
 ssh : [Bitwarden -> sshpass | ssh-agent | -i tmpfile]  exec the original ssh
```

### `check_biometric.sh`

The central check script, also usable in your own scripts:

```bash
check_biometric -d "Really delete the backup?" && rm -rf ~/backup
```

It calls `termux-fingerprint` with a time limit and `stdin=/dev/null` (so it never “steals” pipe
input) and evaluates the JSON with `jq`:

```json
{"errors": [], "failed_attempts": 0, "auth_result": "AUTH_RESULT_SUCCESS"}
```

| Result | Exit | Internal status |
|---|---|---|
| `AUTH_RESULT_SUCCESS` | 0 | `success` |
| finger not recognized / cancelled | 1 | `rejected` (retried up to `BIO_MAX_ATTEMPTS`) |
| `ERROR_LOCKOUT`, `ERROR_TOO_MANY_FAILED_ATTEMPTS` | 1 | `locked` |
| `ERROR_NO_HARDWARE`, `ERROR_NO_ENROLLED_FINGERPRINTS`, timeout, no/invalid JSON, command missing | 1 | `unavailable` (fallback possible) |

### `sudo` wrapper

Supports the common options:

```
sudo COMMAND …             command as root
sudo FOO=bar COMMAND       set environment variables
sudo -u USER COMMAND       as another user (su USER)
sudo -E COMMAND            keep the whole environment (su -p)
sudo -s [COMMAND]          root shell, or run the command through a shell
sudo -i                    login shell as root
sudo -n COMMAND            never show a dialog, only use a valid cache
sudo -v                    authenticate and refresh the cache
sudo -k [COMMAND]          discard the cache
sudo -K                    delete all caches
```

On the root side, the Termux environment (`PATH`, `PREFIX`, `TERM`, `LD_PRELOAD`, …) is set so
Termux programs also work as root. `HOME` points to `~/.suroot` by default, like with `tsu`, so
root doesn’t write files into your `$HOME`. Arguments are quoted POSIX-safely (tested with spaces,
`'`, `"`, `$`, `` ` ``, `;`).

### `ssh` wrapper

1. The target is resolved with `ssh -G`, so aliases from `~/.ssh/config`, `-l` and `-p` are taken
   into account correctly.
2. `ssh -V/-G/-Q/-O` and hosts in `SSH_SKIP_HOSTS` are passed through without a dialog.
3. Fingerprint, or a valid cache.
4. If a Bitwarden item is mapped to the host in `ssh-hosts.conf`:
   - **Password:** `sshpass -d 3 ssh -o NumberOfPasswordPrompts=1 …`, the password comes through FD 3.
   - **Key:** `ssh-add -t <lifetime> -` into a running `ssh-agent`, otherwise a temporary `0600`
     file plus `-i … -o IdentitiesOnly=yes`.
5. Exit code like ssh (`255` on connection or authentication errors).

---

## Configuration

File: `~/.config/termux-auth-wrapper/config.conf` (edit with `termux-auth config edit`).
The template with all comments is `config/config.conf.example`.

Every key can be overridden per call with the environment variable `TAW_<KEY>`:

```bash
TAW_DEBUG=true sudo id
TAW_AUTH_CACHE_TIMEOUT=0 ssh server     # guaranteed fingerprint this time
```

| Key | Default | Meaning |
|---|---|---|
| `BIO_TITLE` | `Termux authentication` | title of the dialog |
| `BIO_TIMEOUT` | `30` | seconds until the dialog is aborted (also protects against hangs when Termux:API is missing) |
| `BIO_MAX_ATTEMPTS` | `2` | retries after “not recognized/cancelled” |
| `AUTH_CACHE_TIMEOUT` | `300` | grace period in seconds; `0` = always ask |
| `AUTH_CACHE_SCOPE` | `session` | `session` = per terminal session (scripts inherit it), `global` = everywhere |
| `AUTH_CACHE_SHARED` | `false` | shared cache for sudo **and** ssh |
| `LOCK_TIMEOUT` | `120` | how long parallel calls wait for a running dialog |
| `FALLBACK_MODE` | `none` | when biometrics are unavailable: `none` / `pin` / `allow` (insecure) |
| `FALLBACK_ON_REJECT` | `false` | fallback also after a rejected fingerprint |
| `FALLBACK_PIN_HASH` | – | set by `termux-auth set-pin` |
| `SUDO_ENABLED` | `true` | sudo wrapper active |
| `SU_BINARY` | `auto` | `/system/bin/su` (KernelSU), `/data/adb/ksu/bin/su`, … |
| `SUDO_PRESERVE_TERMUX_ENV` | `true` | set the Termux environment on the root side |
| `SUDO_HOME` | `suroot` | `suroot` (`~/.suroot`), `keep` or a path |
| `SUDO_SHELL` | `auto` | shell for `sudo -s/-i` (`$PREFIX/bin/bash`) |
| `SUDO_MOUNT_MASTER` | `false` | KernelSU `-M` (global mount namespace) |
| `SUDO_WARN_PKG` | `true` | warn on `sudo pkg/apt` |
| `SSH_ENABLED` | `true` | ssh wrapper active |
| `SSH_BINARY` | `auto` | path to the real ssh |
| `SSH_AUTH_SCOPE` | `all` | `all` = every connection, `mapped` = only hosts from `ssh-hosts.conf` |
| `SSH_SKIP_HOSTS` | – | host globs without dialog, e.g. `"github.com gitlab.com *.lan"` |
| `SSH_KEY_METHOD` | `auto` | `agent` / `tempfile` / `auto` |
| `SSH_AGENT_KEY_LIFETIME` | `300` | lifetime of keys in the agent (s) |
| `BW_ENABLED` | `false` | use Bitwarden |
| `BW_UNLOCK_MODE` | `prompt` | locked: ask for the master password (`prompt`) or abort (`never`) |
| `BW_SESSION_CACHE` | `false` | remember `BW_SESSION` in a `0600` file |
| `BW_TIMEOUT` | `60` | time limit for bw calls |
| `BW_SYNC` | `false` | `bw sync` before fetching |
| `BW_FALLBACK` | `prompt` | if Bitwarden delivers nothing: continue normally (`prompt`) or abort (`fail`) |
| `AUDIT_LOG` | `true` | write the audit log |
| `AUDIT_LOG_ARGS` | `false` | log full sudo command lines |
| `DEBUG` | `false` | verbose output |
| `COLOR` | `auto` | `auto` / `always` / `never` |

### Fallback PIN

```bash
termux-auth set-pin                  # enter the PIN twice -> salted SHA-256 hash
termux-auth config edit              # set FALLBACK_MODE=pin
```

The PIN is only a stopgap for devices or situations without biometrics. It is only offered for
`unavailable` (for `rejected` only with `FALLBACK_ON_REJECT=true`) and needs a terminal.

---

## Setting up Bitwarden

```bash
pkg install nodejs sshpass
npm install -g @bitwarden/cli
bw config server https://vault.bitwarden.eu   # only for EU/self-hosted servers
bw login
```

### Quick start: fingerprint instead of password

```bash
termux-auth bw-unlock                 # master password ONCE, the session is stored
termux-auth map nas "NAS"             # map host "nas" to a Bitwarden item (pick by number)
termux-auth map pi@192.168.178.20 "Raspberry" password
ssh nas                               # -> only the fingerprint, the password comes from Bitwarden
```

`bw-unlock` sets `BW_ENABLED=true` and, after asking, `BW_SESSION_CACHE=true`. After that the
master password is only needed again when the vault gets locked, e.g. by
`termux-auth reset --bw`, `bw lock` or a logout. `map` searches the vault, lets you pick the item
and writes the mapping to `ssh-hosts.conf`.

### Manual setup

1. Set `BW_ENABLED=true` in the configuration.
2. Look up the item ID:
   ```bash
   bw list items --search "My server" | jq -r '.[] | "\(.id)  \(.name)"'
   ```
3. Add the mapping to `~/.config/termux-auth-wrapper/ssh-hosts.conf`:
   ```
   # <host-pattern>  <bitwarden-item>                       [password|key|auto]
   homeserver        0b8c5d6e-1111-2222-3333-abcdefabcdef   password
   pi@192.168.178.*  "Raspberry Pi"                         password
   *.example.org     7f3e2a10-4444-5555-6666-abcdefabcdef   key
   ```
   Patterns are matched against the alias, the resolved host name and `user@host`.
   The first matching line wins.

Keys are looked up in this order: Bitwarden’s native **SSH key item** (`sshKey.privateKey`),
the custom field `ssh_private_key`, a note containing `-----BEGIN … PRIVATE KEY-----`.

**Unlocking:**
- `BW_UNLOCK_MODE=prompt`: if the vault is locked, the wrapper asks for the master password in the
  terminal **after** the fingerprint.
- `BW_UNLOCK_MODE=never`: the session has to be exported beforehand:
  `export BW_SESSION="$(bw unlock --raw)"`
- `BW_SESSION_CACHE=true` remembers the session across shells. `termux-auth reset --bw` discards it
  again and locks the vault.

For a single call: `TAW_BW_ITEM=<id> TAW_BW_TYPE=key ssh host`

---

## Use in scripts

Because the wrappers are called `sudo` and `ssh`, existing scripts need no changes:

```bash
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
sudo mount -o remount,rw /data/local/tmp   # -> fingerprint
sudo cp config.xml /data/local/tmp/        # -> no further dialog within the grace period
ssh backup@nas 'df -h'                      # -> separate cache for ssh
echo "data" | sudo tee /data/local/tmp/x    # stdin works
```

Tips:
- **Background jobs** (Termux:Boot, crond, Termux:Widget) don’t share a terminal session.
  With `AUTH_CACHE_SCOPE=global` one confirmation also covers them.
- **Authenticate up front:** `sudo -v` at the start of a script, then the cache applies.
- **Never block:** `sudo -n …` fails immediately if there is no valid cache.
- **Parallel calls** (`cmd1 & cmd2 &`) trigger only one dialog; the others wait for its result.
- Your own confirmations: `check_biometric -d "Text"` (exit 0/1).

---

## Update safety

| Event | Effect |
|---|---|
| Update of the **Termux app** (APK) | none, because the wrappers live in `$PREFIX`/`$HOME`, not in the APK |
| Update of the **Termux:API app** | none |
| `pkg upgrade openssh` | `$PREFIX/bin/ssh` is diverted with `dpkg-divert --local --rename`, dpkg writes the new binary to `$PREFIX/libexec/termux-auth-wrapper/ssh` and the wrapper stays in place |
| Wrapper overwritten/deleted anyway | the apt hook `DPkg::Post-Invoke` runs `termux-auth repair --quiet` after every pkg run: the new binary is saved and the wrapper restored |
| `git pull` in the repository | `./install.sh -y` updates the library and the wrappers, the configuration stays |

Check manually: `termux-auth status`, repair: `termux-auth repair`.

---

## Management: `termux-auth`

```
termux-auth status          installation state, PATH resolution, dependencies, configuration
termux-auth doctor          like status, plus a live test of su -c and Bitwarden
termux-auth diag            step-by-step diagnosis of the Termux:API connection
termux-auth test            test the fingerprint dialog
termux-auth reset [--bw]    clear the auth cache (--bw: discard the Bitwarden session + bw lock)
termux-auth set-pin         set the fallback PIN
termux-auth bw-unlock       unlock Bitwarden once, remember the session
termux-auth map HOST [SEARCH] [password|key|auto]
                            map an SSH host to a Bitwarden item
termux-auth repair [-q]     check/restore the wrappers
termux-auth config [edit]   show the config paths / open in $EDITOR
termux-auth log [N]         last N audit log entries
```

---

## Troubleshooting

| Message | Cause and solution |
|---|---|
| `termux-fingerprint not found` | `pkg install termux-api` |
| `No answer from Termux:API within 30s` | **Run `termux-auth diag` first**, see below. |
| `printed nothing` / `not JSON` | install or update the Termux:API app; the versions of the app and the `termux-api` package should match |
| `no fingerprint sensor` | device without a sensor, possibly `FALLBACK_MODE=pin` |
| `No fingerprint enrolled` | Android settings → Security → Fingerprint |
| `Sensor locked …` | too many failed attempts; unlock the device with your PIN and try again later |
| `No su binary found` | KernelSU app → Superuser → grant Termux, possibly set `SU_BINARY` |
| `The Bitwarden vault is locked` | `export BW_SESSION="$(bw unlock --raw)"` or `BW_UNLOCK_MODE=prompt` |
| `Not signed in to Bitwarden` | `bw login` |
| `More than one result` | use the item **ID** instead of the name in `ssh-hosts.conf` |
| `sshpass is not installed` | `pkg install sshpass` |
| `sudo`/`ssh` doesn’t ask for the fingerprint | `termux-auth status` shows the PATH resolution; clear the shell’s command cache with `hash -r` |
| in general | `TAW_DEBUG=true sudo id` shows every step |

### Termux:API does not answer (timeout)

`termux-auth diag` checks one after another:

1. Termux version and source (`TERMUX_APK_RELEASE`)
2. version of the `termux-api` package
3. via root (read-only) `dumpsys package` for `com.termux` and `com.termux.api`: installed?
   `stopped`? Installation source? Background restrictions?
4. `termux-battery-status`, i.e. an API **without** a dialog. If it hangs too, no request reaches
   the app at all.
5. `termux-fingerprint` without options, then with `-t/-d`

Typical causes:
- Termux and Termux:API come from **different sources** (F-Droid, GitHub, Play Store), so the
  signatures don’t match.
- Termux:API was never opened or was stopped with “Force stop” (`stopped=true`): open the app once.
- Battery restriction: set Termux:API to **“Unrestricted”** under battery.
- Only the dialog hangs: allow Termux:API to *display over other apps*.
- It hangs with `-t/-d` but not without: set `BIO_DIALOG_TEXT=false`.

---

## Uninstalling

```bash
$PREFIX/lib/termux-auth-wrapper/uninstall.sh          # keeps the configuration
$PREFIX/lib/termux-auth-wrapper/uninstall.sh --purge  # everything incl. configuration and log
```

Diverted originals (e.g. `ssh`) are put back with `dpkg-divert --remove`.

---

## Development & tests

```bash
tests/run_tests.sh       # or: tests/run_tests.sh -v
```

The test suite runs on any Linux with `bash` and `jq`. It builds a fake Termux prefix and
replaces `termux-fingerprint`, `su`, `ssh`, `sshpass`, `bw` and `dpkg-divert` with mocks.
Among other things it checks:
- all biometric results including timeout,
- quoting of special characters,
- passing through stdin and exit codes,
- cache, lock and parallel calls,
- fallbacks and the PIN prompt (through a pseudo-terminal),
- Bitwarden (locked, unlocking, password, key),
- `repair` after a simulated `pkg upgrade`, `dpkg-divert`, home mode and uninstalling.

With `shellcheck` installed, static checks run too. The GitHub workflow in
`.github/workflows/test.yml` runs both.

---

## Known limitations

- The fingerprint dialog is an Android activity. If Termux runs completely in the background,
  Android may delay or block it (see troubleshooting). After a timeout the dialog may stay
  visible; its result is then ignored.
- `scp`/`sftp` call ssh through a path compiled in (`$PREFIX/bin/ssh`). In prefix mode that goes
  through the wrapper, in home mode it doesn’t.
- `ssh -J` (ProxyJump) starts another `ssh` internally. Within the grace period there is no second
  dialog; with `AUTH_CACHE_TIMEOUT=0` there is.
- The sudo wrapper only knows the options listed above. `sudoers`, `-e` (sudoedit) and `-b` are
  not supported.
- With `--mode home`, processes that start without your shell PATH bypass the wrappers.

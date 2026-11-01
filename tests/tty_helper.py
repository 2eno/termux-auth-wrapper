#!/usr/bin/env python3
"""Führt einen Befehl in einem Pseudo-Terminal aus und beantwortet Prompts.

Aufruf:  tty_helper.py "Prompt-Teiltext=Antwort" [...] -- befehl [argumente]

Jede Antwort wird gesendet, sobald ihr Prompt-Teiltext in der Ausgabe
erscheint (in der angegebenen Reihenfolge). Gibt die gesamte Ausgabe aus
und beendet sich mit dem Exit-Code des Befehls.
"""
import os
import pty
import select
import sys
import time


def main() -> int:
    if "--" not in sys.argv:
        print(__doc__, file=sys.stderr)
        return 2
    sep = sys.argv.index("--")
    answers = [a.split("=", 1) for a in sys.argv[1:sep]]
    cmd = sys.argv[sep + 1:]

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)

    out = b""
    scan_from = 0
    deadline = time.time() + 30
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out += data
        if answers:
            prompt, answer = answers[0]
            idx = out.find(prompt.encode(), scan_from)
            if idx >= 0:
                scan_from = idx + len(prompt)
                os.write(fd, answer.encode() + b"\n")
                answers.pop(0)
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(out.decode(errors="replace"))
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())

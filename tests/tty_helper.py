#!/usr/bin/env python3
"""Runs a command in a pseudo-terminal and answers prompts.

Usage:  tty_helper.py "prompt substring=answer" [...] -- command [arguments]

Each answer is sent as soon as its prompt substring appears in the output
(in the given order). Prints the whole output and exits with the command's
exit code.
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
    # Deadline reached or output ended: kill hanging child processes
    done, status = 0, 0
    for _ in range(40):  # wait up to 2 s for a regular exit
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
        time.sleep(0.05)
    if done == 0:
        os.kill(pid, 9)
        _, status = os.waitpid(pid, 0)
        out += b"\n[tty_helper: time limit, process killed]\n"
    sys.stdout.write(out.decode(errors="replace"))
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())

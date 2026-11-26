"""A throwaway SSH server on 127.0.0.1 that only checks passwords.

OpenSSH run without root cannot check a password: it has no PAM and cannot
read the system password file. This server, on paramiko, can, so the tests
can run the password logins of the app against a real SSH handshake.

Usage: password_sshd.py MODE, with the password in SHELLHERD_TEST_PASSWORD.

MODE is what the server offers:
  password   the "password" method only
  kbdint     keyboard-interactive only, one hidden "Password:" prompt
  both       both methods
  otp        keyboard-interactive: "Password:", then a hidden code prompt
  two        keyboard-interactive: one round with two prompts
  none       the "none" method, as Tailscale SSH: no credentials
  check      "none", after a Tailscale check: a banner with a link, then
             the login waits CHECK_SECONDS before it goes through
  stuck      "none", after a Tailscale check that no one approves

It prints "PORT <n>", then one line per answer it gets:
  AUTH password ok|bad
  AUTH kbdint <number of answers> ok|bad|more
  AUTH none ok
It never prints a password or an answer.

For each line <n> on stdin, it waits until every connection it took has
ended, then prints "SYNC <n>": the answers of those connections all come
before it on stdout.
"""

import os
import socket
import sys
import threading
import time

from paramiko import RSAKey, ServerInterface, Transport
from paramiko.common import (
    AUTH_FAILED,
    AUTH_SUCCESSFUL,
    OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED,
)
from paramiko.server import InteractiveQuery

PASSWORD = os.environ["SHELLHERD_TEST_PASSWORD"]
MODE = sys.argv[1]
CHECK_URL = "https://login.tailscale.com/a/test0123"
CHECK_SECONDS = 0.5


def log(line):
    print(line, flush=True)


class Server(ServerInterface):
    def __init__(self):
        self.round = 0

    def get_allowed_auths(self, username):
        return {
            "password": "password",
            "kbdint": "keyboard-interactive",
            "both": "password,keyboard-interactive",
            "otp": "keyboard-interactive",
            "two": "keyboard-interactive",
            "none": "none",
            "check": "none",
            "stuck": "none",
        }[MODE]

    def get_banner(self):
        if MODE in ("check", "stuck"):
            return (
                "# Tailscale SSH requires an additional check.\n"
                f"# To authenticate, visit: {CHECK_URL}\n",
                "en-US",
            )
        return (None, None)

    def check_auth_none(self, username):
        if MODE not in ("none", "check", "stuck"):
            return AUTH_FAILED
        # Tailscale SSH holds the login until the check is approved.
        if MODE == "check":
            time.sleep(CHECK_SECONDS)
        elif MODE == "stuck":
            time.sleep(3600)
        log("AUTH none ok")
        return AUTH_SUCCESSFUL

    def check_auth_password(self, username, password):
        # paramiko asks this even for a method the server did not offer.
        if "password" not in self.get_allowed_auths(username).split(","):
            return AUTH_FAILED
        ok = password == PASSWORD
        log(f"AUTH password {'ok' if ok else 'bad'}")
        return AUTH_SUCCESSFUL if ok else AUTH_FAILED

    def check_auth_interactive(self, username, submethods):
        self.round = 0
        query = InteractiveQuery("", "")
        query.add_prompt("Password: ", False)
        if MODE == "two":
            query.add_prompt("Verification code: ", False)
        return query

    def check_auth_interactive_response(self, responses):
        ok = len(responses) >= 1 and responses[0] == PASSWORD
        if MODE == "otp" and ok and self.round == 0:
            self.round = 1
            log(f"AUTH kbdint {len(responses)} more")
            query = InteractiveQuery("", "")
            query.add_prompt("Verification code: ", False)
            return query
        if MODE in ("otp", "two"):
            ok = False
        log(f"AUTH kbdint {len(responses)} {'ok' if ok else 'bad'}")
        return AUTH_SUCCESSFUL if ok else AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


connections = []
connections_lock = threading.Lock()


def sync():
    """Answers each line on stdin once the connections so far have ended."""
    while True:
        line = sys.stdin.readline()
        if not line:
            return
        with connections_lock:
            ongoing = list(connections)
        for thread in ongoing:
            thread.join()
        log(f"SYNC {line.strip()}")


def serve(conn, host_key):
    transport = Transport(conn)
    transport.add_server_key(host_key)
    try:
        transport.start_server(server=Server())
        while transport.is_active():
            time.sleep(0.05)
    except Exception:
        pass
    finally:
        transport.close()


def main():
    host_key = RSAKey.generate(2048)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    log(f"PORT {listener.getsockname()[1]}")
    threading.Thread(target=sync, daemon=True).start()
    while True:
        conn, _ = listener.accept()
        thread = threading.Thread(target=serve, args=(conn, host_key), daemon=True)
        with connections_lock:
            connections.append(thread)
        thread.start()


if __name__ == "__main__":
    main()

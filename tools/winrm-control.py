#!/usr/bin/env python3

import argparse
import getpass
import sys

import winrm

DEFAULT_PASSWORD = "ChangeMe-Lab123!"

ACTIONS = {
    "restart": "Restart-Computer -Force",
    "shutdown": "Stop-Computer -Force",
}


def prompt_action():
    while True:
        action = input("Action [restart/shutdown] (default: restart): ").strip().lower()

        if action == "":
            return "restart"

        if action in ACTIONS:
            return action

        print("Invalid action. Please enter 'restart' or 'shutdown'.")


def main():
    parser = argparse.ArgumentParser(
        description="Control a remote Windows host via WinRM."
    )
    parser.add_argument(
        "host",
        help="IP address or hostname of the Windows machine"
    )
    parser.add_argument(
        "-u",
        "--username",
        default="Administrator",
        help="WinRM username (default: Administrator)"
    )

    args = parser.parse_args()

    action = prompt_action()

    password = getpass.getpass(
        prompt=(
            f"Password for {args.username}@{args.host} "
            "(press Enter for default): "
        )
    )

    if not password:
        password = DEFAULT_PASSWORD
        print("Using default password.")

    try:
        session = winrm.Session(
            args.host,
            auth=(args.username, password),
        )

        command = ACTIONS[action]
        result = session.run_ps(command)

        if result.status_code == 0:
            print(f"Successfully sent '{action}' command to {args.host}.")
        else:
            print(f"Failed to execute '{action}'.")
            print(f"Status Code: {result.status_code}")

            if result.std_out:
                print("STDOUT:")
                print(result.std_out.decode(errors="ignore"))

            if result.std_err:
                print("STDERR:")
                print(result.std_err.decode(errors="ignore"))

            sys.exit(1)

    except Exception as e:
        print(f"Connection error: {e}")
        sys.exit(2)


if __name__ == "__main__":
    main()

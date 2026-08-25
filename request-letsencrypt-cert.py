#!/usr/bin/env python3

import os
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_EMAIL = "xlshcn@outlook.com"


def normalize_domain(value):
    try:
        domain = value.strip().rstrip(".").encode("idna").decode("ascii").lower()
    except UnicodeError as error:
        raise ValueError("invalid domain") from error
    labels = domain.split(".")
    if (
        len(domain) > 253
        or len(labels) < 2
        or any(
            not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
            for label in labels
        )
    ):
        raise ValueError("enter a valid DNS domain, for example www.example.com")
    return domain


def read_domain_file(path):
    try:
        return normalize_domain(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ValueError(f"cannot read domain file {path}: {error}") from error


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def user_home():
    sudo_user = os.environ.get("SUDO_USER")
    if os.geteuid() == 0 and sudo_user and sudo_user != "root":
        try:
            return Path(pwd.getpwnam(sudo_user).pw_dir)
        except KeyError:
            pass
    return Path.home()


def main():
    print(f"Default email: {DEFAULT_EMAIL}")

    domain_file = user_home() / ".xz_domain"
    try:
        if domain_file.is_file():
            domain = read_domain_file(domain_file)
            print(f"Domain loaded from {domain_file}: {domain}")
        else:
            domain = normalize_domain(input("Domain: "))
    except (EOFError, ValueError) as error:
        print(f"Error: {error or 'domain is required'}", file=sys.stderr)
        return 1

    try:
        confirmed = input(f"Confirm domain '{domain}'? [y/N]: ")
    except EOFError:
        confirmed = ""
    if confirmed.strip().lower() != "y":
        print("Aborted by user.")
        return 1

    sudo = [] if os.geteuid() == 0 else ["sudo"]
    certbot = shutil.which("certbot")
    if not certbot:
        print("Certbot not found; installing it...")
        if brew := shutil.which("brew"):
            run([brew, "install", "certbot"])
        elif apt_get := shutil.which("apt-get"):
            run([*sudo, apt_get, "update"])
            run([*sudo, apt_get, "install", "-y", "certbot"])
        else:
            print(
                "Error: install Homebrew or apt-get before running this script.",
                file=sys.stderr,
            )
            return 1
        certbot = shutil.which("certbot")
        if not certbot:
            print("Error: certbot installation failed.", file=sys.stderr)
            return 1

    run([
        *sudo,
        certbot,
        "certonly",
        "--manual",
        "--preferred-challenges",
        "dns",
        "--email",
        DEFAULT_EMAIL,
        "--agree-tos",
        "--no-eff-email",
        "-d",
        domain,
        "--cert-name",
        domain,
    ])

    destination = Path("/etc/letsencrypt/live") / domain
    for filename in ("fullchain.pem", "privkey.pem"):
        certificate_file = destination / filename
        if subprocess.run(
            [*sudo, "test", "-f", str(certificate_file)]
        ).returncode:
            print(
                f"Error: certificate file missing: {certificate_file}",
                file=sys.stderr,
            )
            return 1

    print(f"Certificate saved to: {destination}")
    return 0


def self_test():
    assert normalize_domain("WWW.Example.COM.") == "www.example.com"
    assert normalize_domain("例子.测试") == "xn--fsqu00a.xn--0zwm56d"
    with tempfile.TemporaryDirectory() as directory:
        domain_file = Path(directory) / ".xz_domain"
        domain_file.write_text("XZ.Takecopter.CN\n", encoding="utf-8")
        assert read_domain_file(domain_file) == "xz.takecopter.cn"


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif sys.argv[1:]:
        print(f"Usage: {Path(sys.argv[0]).name} [--self-test]", file=sys.stderr)
        raise SystemExit(2)
    else:
        raise SystemExit(main())

#!/usr/bin/env python3
"""Generate a main_config.json for percona-binlog-server (branch 0.4).

Collects MySQL connection credentials and server settings from CLI flags,
environment variables, or interactive prompts, validates them against the
rules enforced by binsrv's own config parser, and writes out a JSON config
file consumable by the `binlog_server` utility.

Schema reference: https://github.com/Percona-Lab/percona-binlog-server (0.4)
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from typing import Any, Optional

SIZE_UNIT_RE = re.compile(r"^\d+[KMGTP]?$")
TIME_UNIT_RE = re.compile(r"^\d+[smhd]?$")

LOG_LEVELS = ("trace", "debug", "info", "warning", "error", "fatal")
SSL_MODES = ("disabled", "preferred", "required", "verify_ca", "verify_identity")
REPLICATION_MODES = ("position", "gtid")
STORAGE_BACKENDS = ("file", "s3")

DEFAULT_ENCRYPTION_KEK_ID = "alpha"
DEFAULT_ENCRYPTION_CIPHER = "AES-256-CTR"


def to_file_uri(path: str) -> str:
    return "file://" + os.path.abspath(os.path.expanduser(path))


class ConfigError(Exception):
    """Raised when the collected settings fail validation."""


def env(name: str, default: Optional[str] = None) -> Optional[str]:
    # An exported-but-empty variable (as left by the pbs_env.sh template) is
    # treated the same as an unset one, not as an explicit empty value.
    return os.environ.get(name) or default


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    out = p.add_argument_group("output")
    out.add_argument(
        "-o", "--output", default="main_config.json",
        help="path to write the generated config file (default: %(default)s)",
    )
    out.add_argument(
        "--stdout", action="store_true",
        help="print the generated config to stdout instead of writing a file",
    )
    out.add_argument(
        "--force", action="store_true",
        help="overwrite the output file if it already exists",
    )
    out.add_argument(
        "--non-interactive", action="store_true",
        help="never prompt; fail instead if a required value is missing",
    )

    logger = p.add_argument_group("logger")
    logger.add_argument("--log-level", choices=LOG_LEVELS, default=env("LOG_LEVEL", "info"))
    logger.add_argument(
        "--log-file", default=env("LOG_FILE", ""),
        help="log file path, or empty string for console logging (default: console)",
    )

    conn = p.add_argument_group("connection (credentials)")
    conn.add_argument("--host", default=env("MYSQL_HOST"), help="MySQL host (mutually exclusive with --dns-srv-name)")
    conn.add_argument("--port", type=int, default=_int_env("MYSQL_PORT"), help="MySQL port (default: 3306)")
    conn.add_argument("--dns-srv-name", default=env("MYSQL_DNS_SRV_NAME"), help="DNS SRV name (mutually exclusive with --host/--port)")
    conn.add_argument("--user", default=env("MYSQL_USER"), help="MySQL user with REPLICATION SLAVE privilege (default: root)")
    conn.add_argument("--password", default=env("MYSQL_PASSWORD"), help="MySQL password (prefer --password-env for CI use)")
    conn.add_argument("--password-env", help="name of an env var holding the MySQL password")
    conn.add_argument("--connect-timeout", type=int, default=_int_env("CONNECT_TIMEOUT", 20))
    conn.add_argument("--read-timeout", type=int, default=_int_env("READ_TIMEOUT", 60))
    conn.add_argument("--write-timeout", type=int, default=_int_env("WRITE_TIMEOUT", 60))

    ssl = p.add_argument_group("connection.ssl (optional)")
    ssl.add_argument("--ssl-mode", choices=SSL_MODES, default=env("SSL_MODE"))
    ssl.add_argument("--ssl-ca", default=env("SSL_CA"))
    ssl.add_argument("--ssl-capath", default=env("SSL_CAPATH"))
    ssl.add_argument("--ssl-crl", default=env("SSL_CRL"))
    ssl.add_argument("--ssl-crlpath", default=env("SSL_CRLPATH"))
    ssl.add_argument("--ssl-cert", default=env("SSL_CERT"))
    ssl.add_argument("--ssl-key", default=env("SSL_KEY"))
    ssl.add_argument("--ssl-cipher", default=env("SSL_CIPHER"))
    ssl.add_argument(
        "--ssl-auto-detect", action="store_true",
        help=(
            "connect to the MySQL server with the resolved connection settings and set "
            "--ssl-ca/--ssl-capath/--ssl-crl/--ssl-crlpath to whatever the server reports "
            "for the matching ssl_* variable (a variable the server reports empty is left "
            "unset), overwriting any of those options given explicitly -- NOT --ssl-cert/"
            "--ssl-key/--ssl-cipher, which are the server's own identity/preference, not "
            "the client's, and are never copied even though the server reports them too; "
            "also defaults --ssl-mode to required unless you pass --ssl-mode yourself, in "
            "which case your value is kept as-is (requires the 'mysql' client on PATH)"
        ),
    )

    tls = p.add_argument_group("connection.tls (optional)")
    tls.add_argument("--tls-version", default=env("TLS_VERSION"))
    tls.add_argument("--tls-ciphersuites", default=env("TLS_CIPHERSUITES"))

    repl = p.add_argument_group("replication")
    repl.add_argument("--server-id", type=int, default=_int_env("SERVER_ID", 42))
    repl.add_argument("--idle-time", type=int, default=_int_env("IDLE_TIME", 10))
    repl.add_argument("--verify-checksum", dest="verify_checksum", action="store_true", default=True)
    repl.add_argument("--no-verify-checksum", dest="verify_checksum", action="store_false")
    repl.add_argument("--replication-mode", choices=REPLICATION_MODES, default=env("REPLICATION_MODE", "gtid"))
    repl.add_argument("--rewrite-base-file-name", default=env("REWRITE_BASE_FILE_NAME"))
    repl.add_argument("--rewrite-file-size", default=env("REWRITE_FILE_SIZE"), help="e.g. 128M (requires gtid mode)")

    keyring = p.add_argument_group("keyring (optional, needed to decrypt/encrypt binlogs)")
    keyring.add_argument(
        "--keyring-path", default=env("KEYRING_PATH"),
        help=(
            "local path to the keyring JSON file (absolute or relative; resolved to an "
            "absolute file:// URI — the only scheme the server supports)"
        ),
    )

    storage = p.add_argument_group("storage")
    storage.add_argument("--storage-backend", choices=STORAGE_BACKENDS, default=env("STORAGE_BACKEND", "file"))
    storage.add_argument(
        "--storage-path", default=env("STORAGE_PATH"),
        help=(
            "local directory for --storage-backend file (absolute or relative; resolved "
            "to an absolute file:// URI); not used for the s3 backend"
        ),
    )
    storage.add_argument(
        "--storage-uri", default=env("STORAGE_URI"),
        help="full storage URI for --storage-backend s3; overrides --s3-* helpers; not used for the file backend",
    )
    storage.add_argument("--fs-buffer-directory", default=env("FS_BUFFER_DIRECTORY"))
    storage.add_argument("--checkpoint-size", default=env("CHECKPOINT_SIZE"), help="e.g. 2M")
    storage.add_argument("--checkpoint-interval", default=env("CHECKPOINT_INTERVAL"), help="e.g. 30s")

    s3 = p.add_argument_group("storage s3 helpers (used to build --storage-uri when --storage-backend s3)")
    s3.add_argument("--s3-access-key-id", default=env("S3_ACCESS_KEY_ID"))
    s3.add_argument("--s3-secret-access-key", default=env("S3_SECRET_ACCESS_KEY"))
    s3.add_argument("--s3-secret-access-key-env", help="name of an env var holding the S3 secret access key")
    s3.add_argument("--s3-bucket", default=env("S3_BUCKET"))
    s3.add_argument("--s3-region", default=env("S3_REGION"))
    s3.add_argument("--s3-endpoint", default=env("S3_ENDPOINT"), help="set for S3-compatible endpoints; omit for AWS")
    s3.add_argument("--s3-path", default=env("S3_PATH", ""), help="path/prefix inside the bucket")

    enc = p.add_argument_group("storage.encryption (optional)")
    enc.add_argument(
        "--encryption", action="store_true",
        help=(
            "enable storage.encryption; if --encryption-kek-id/--encryption-cipher are "
            f"not given, defaults to kek_id={DEFAULT_ENCRYPTION_KEK_ID!r}, "
            f"cipher={DEFAULT_ENCRYPTION_CIPHER!r} (requires --keyring-path)"
        ),
    )
    enc.add_argument("--encryption-kek-id", default=env("ENCRYPTION_KEK_ID"), help="key-encryption-key ID from the keyring")
    enc.add_argument("--encryption-cipher", default=env("ENCRYPTION_CIPHER"), help="must be a CTR-mode cipher, e.g. AES-256-CTR")

    return p


def _int_env(name: str, default: Optional[int] = None) -> Optional[int]:
    val = os.environ.get(name)
    return int(val) if val else default


def prompt_if_missing(args: argparse.Namespace) -> None:
    if args.non_interactive:
        return
    if not sys.stdin.isatty():
        return

    if not args.dns_srv_name and not args.host:
        value = input("MySQL host [127.0.0.1]: ").strip()
        args.host = value or "127.0.0.1"
    if not args.dns_srv_name and not args.port:
        value = input("MySQL port [3306]: ").strip()
        args.port = int(value) if value else 3306
    if not args.user:
        value = input("MySQL user [root]: ").strip()
        args.user = value or "root"
    if args.password is None and not args.password_env:
        args.password = getpass.getpass("MySQL password (leave empty for none): ")


def apply_defaults(args: argparse.Namespace) -> None:
    if not args.user:
        args.user = "root"
    if not args.dns_srv_name and args.port is None:
        args.port = 3306
    if args.encryption or args.encryption_kek_id or args.encryption_cipher:
        if not args.encryption_kek_id:
            args.encryption_kek_id = DEFAULT_ENCRYPTION_KEK_ID
        if not args.encryption_cipher:
            args.encryption_cipher = DEFAULT_ENCRYPTION_CIPHER


def resolve_password(args: argparse.Namespace) -> str:
    if args.password_env:
        value = os.environ.get(args.password_env)
        if value is None:
            raise ConfigError(f"--password-env references unset env var: {args.password_env}")
        return value
    return args.password or ""


def resolve_s3_secret(args: argparse.Namespace) -> str:
    if args.s3_secret_access_key_env:
        value = os.environ.get(args.s3_secret_access_key_env)
        if value is None:
            raise ConfigError(
                f"--s3-secret-access-key-env references unset env var: {args.s3_secret_access_key_env}"
            )
        return value
    return args.s3_secret_access_key or ""


def build_storage_uri(args: argparse.Namespace) -> str:
    if args.storage_backend == "file":
        if not args.storage_path:
            raise ConfigError(
                "--storage-path is required when --storage-backend file (e.g. /var/lib/pbs/vault)"
            )
        if args.storage_uri:
            raise ConfigError(
                "both --storage-path and --storage-uri were given "
                f"(--storage-path={args.storage_path!r}, --storage-uri={args.storage_uri!r}); "
                "--storage-uri is not used with --storage-backend file, drop it and keep only --storage-path"
            )
        return to_file_uri(args.storage_path)

    # storage_backend == s3
    if not args.storage_uri and not (args.s3_access_key_id and args.s3_bucket):
        raise ConfigError(
            "--storage-uri is required, or provide --s3-access-key-id, "
            "--s3-secret-access-key(-env) and --s3-bucket to build one"
        )
    if args.storage_path:
        raise ConfigError(
            f"--storage-path={args.storage_path!r} was given but is not used with "
            "--storage-backend s3; drop it and use --storage-uri or --s3-* flags instead"
        )
    if args.storage_uri:
        return args.storage_uri
    secret = resolve_s3_secret(args)
    encoded_secret = secret.replace("/", "%2F")
    path = args.s3_path or ""
    if path and not path.startswith("/"):
        path = "/" + path

    if args.s3_endpoint:
        return (
            f"s3://{args.s3_access_key_id}:{encoded_secret}@{args.s3_endpoint}"
            f"/{args.s3_bucket}{path}"
        )
    bucket = args.s3_bucket
    if args.s3_region:
        bucket = f"{bucket}.{args.s3_region}"
    return f"s3://{args.s3_access_key_id}:{encoded_secret}@{bucket}{path}"


# --ssl-auto-detect only ever copies these from the server's own reported
# ssl_* variables onto the client connection: ssl_ca/ssl_capath (the CA
# used to verify a peer certificate) and ssl_crl/ssl_crlpath (its
# revocation list) are look-up material a client verifying that server
# should trust too -- a reasonable shortcut for a local/test setup sharing
# one CA. ssl_cert/ssl_key are the SERVER's own certificate and private
# key -- its identity, not the client's, and not something a client
# connection needs at all -- and ssl_cipher is a server-side preference;
# none of those get copied here even though the server reports them too.
# Set --ssl-cert/--ssl-key/--ssl-cipher explicitly if this client
# genuinely needs its own client certificate or cipher preference.
SSL_VARIABLE_NAMES = ("ssl_ca", "ssl_capath", "ssl_crl", "ssl_crlpath")


def run_mysql_client(args: argparse.Namespace, password: str, sql: str) -> str:
    mysql_bin = shutil.which("mysql")
    if not mysql_bin:
        raise ConfigError(
            "--ssl-auto-detect requires the 'mysql' client binary on PATH to probe the server"
        )

    cmd = [mysql_bin, "--no-defaults", "--connect-timeout", str(args.connect_timeout)]
    if args.dns_srv_name:
        cmd += ["--dns-srv-name", args.dns_srv_name]
    else:
        cmd += ["-h", args.host, "-P", str(args.port)]
    cmd += ["-u", args.user]
    # Always probe with REQUIRED, regardless of --ssl-mode: this call sends
    # real admin credentials to authenticate, so it must never silently
    # fall back to an unencrypted connection the way PREFERRED would if TLS
    # is unavailable or downgraded -- that would leak those credentials in
    # cleartext even when the caller asked for required or a verification
    # mode. REQUIRED still doesn't verify the server's certificate
    # (verify_ca/verify_identity would), since discovering what to verify
    # against is this call's whole job and we don't have that yet -- it
    # just refuses to proceed unencrypted.
    cmd += ["--ssl-mode", "REQUIRED"]
    if args.ssl_ca:
        cmd += ["--ssl-ca", args.ssl_ca]
    if args.ssl_capath:
        cmd += ["--ssl-capath", args.ssl_capath]
    if args.ssl_cert:
        cmd += ["--ssl-cert", args.ssl_cert]
    if args.ssl_key:
        cmd += ["--ssl-key", args.ssl_key]
    cmd += ["-N", "-B", "-e", sql]

    env = os.environ.copy()
    if password:
        env["MYSQL_PWD"] = password

    try:
        result = subprocess.run(
            cmd, env=env, capture_output=True, text=True, timeout=args.connect_timeout + 5
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ConfigError(f"--ssl-auto-detect failed to run the mysql client: {exc}") from exc

    if result.returncode != 0:
        raise ConfigError(
            f"--ssl-auto-detect failed to connect to the MySQL server: {result.stderr.strip()}"
        )
    return result.stdout


def apply_ssl_auto_detect(args: argparse.Namespace, password: str) -> None:
    variables_out = run_mysql_client(
        args,
        password,
        "SHOW VARIABLES WHERE Variable_name IN ("
        + ",".join(f"'{name}'" for name in SSL_VARIABLE_NAMES)
        + ")",
    )
    variables: dict[str, str] = {}
    for line in variables_out.splitlines():
        name, _, value = line.partition("\t")
        if name:
            variables[name] = value

    applied: dict[str, str] = {}
    for name in SSL_VARIABLE_NAMES:
        value = variables.get(name, "")
        if value:
            # An empty result from the server means that setting is unset
            # there; anything already on args (explicit flag or otherwise)
            # is left alone in that case.
            setattr(args, name, value)
            applied[name] = value

    if args.ssl_mode:
        print(f"--ssl-auto-detect: keeping explicitly-given --ssl-mode={args.ssl_mode}", file=sys.stderr)
    else:
        args.ssl_mode = "required"
        print("--ssl-auto-detect: --ssl-mode = required", file=sys.stderr)

    if applied:
        print("--ssl-auto-detect: applied SSL settings from the server:", file=sys.stderr)
        for key, value in applied.items():
            print(f"  --{key.replace('_', '-')} = {value}", file=sys.stderr)
    else:
        print("--ssl-auto-detect: server reported no SSL variables set", file=sys.stderr)


def validate_connection_identity(args: argparse.Namespace) -> None:
    has_dns_srv = bool(args.dns_srv_name)
    has_host = bool(args.host)
    has_port = bool(args.port)
    valid = (has_dns_srv and not has_host and not has_port) or (
        not has_dns_srv and has_host and has_port
    )
    if not valid:
        raise ConfigError(
            "either --dns-srv-name, or both --host and --port, must be specified (not both forms)"
        )
    if not args.user:
        raise ConfigError("--user is required")


def validate(args: argparse.Namespace) -> None:
    validate_connection_identity(args)

    # binlog_server's connection.ssl.mode is mandatory whenever a
    # connection.ssl section exists at all (its ssl_config struct declares
    # "mode" as a plain, non-optional field, unlike ca/capath/crl/crlpath/
    # cert/key/cipher, which are all optional_string) -- the server's own
    # JSON parser rejects an ssl section missing "mode" outright. We build
    # the ssl section at all only when --ssl-mode is given (see
    # build_config() below), so any of these other flags without
    # --ssl-mode would otherwise be silently dropped instead of configuring
    # anything -- fail fast here instead.
    other_ssl_flags = {
        "--ssl-ca": args.ssl_ca,
        "--ssl-capath": args.ssl_capath,
        "--ssl-crl": args.ssl_crl,
        "--ssl-crlpath": args.ssl_crlpath,
        "--ssl-cert": args.ssl_cert,
        "--ssl-key": args.ssl_key,
        "--ssl-cipher": args.ssl_cipher,
    }
    if not args.ssl_mode:
        given = [flag for flag, value in other_ssl_flags.items() if value]
        if given:
            raise ConfigError(
                f"{', '.join(given)} given without --ssl-mode -- connection.ssl.mode is mandatory "
                "whenever connection.ssl is present, so these would otherwise be silently dropped "
                "instead of taking effect; pass --ssl-mode too"
            )

    if args.ssl_mode in ("verify_ca", "verify_identity") and not (args.ssl_ca or args.ssl_capath):
        raise ConfigError(
            f"--ssl-mode {args.ssl_mode} requires --ssl-ca or --ssl-capath "
            "to verify the server certificate"
        )
    if bool(args.ssl_cert) != bool(args.ssl_key):
        raise ConfigError("--ssl-cert and --ssl-key must be set together")

    if args.rewrite_file_size or args.rewrite_base_file_name:
        if not (args.rewrite_file_size and args.rewrite_base_file_name):
            raise ConfigError("--rewrite-base-file-name and --rewrite-file-size must be set together")
        if args.replication_mode != "gtid":
            raise ConfigError("replication.rewrite requires --replication-mode gtid")
        if not SIZE_UNIT_RE.match(args.rewrite_file_size):
            raise ConfigError(f"--rewrite-file-size has an invalid format: {args.rewrite_file_size!r}")

    if args.checkpoint_size and not SIZE_UNIT_RE.match(args.checkpoint_size):
        raise ConfigError(f"--checkpoint-size has an invalid format: {args.checkpoint_size!r}")
    if args.checkpoint_interval and not TIME_UNIT_RE.match(args.checkpoint_interval):
        raise ConfigError(f"--checkpoint-interval has an invalid format: {args.checkpoint_interval!r}")

    if args.encryption_cipher and "CTR" not in args.encryption_cipher.upper():
        raise ConfigError(f"--encryption-cipher must be a CTR-mode cipher, got: {args.encryption_cipher!r}")
    if args.encryption_kek_id and not args.keyring_path:
        raise ConfigError("--keyring-path is required when storage encryption is enabled")


def build_config(args: argparse.Namespace) -> dict[str, Any]:
    config: dict[str, Any] = {
        "logger": {
            "level": args.log_level,
            "file": args.log_file,
        },
        "connection": {},
        "replication": {
            "server_id": args.server_id,
            "idle_time": args.idle_time,
            "verify_checksum": args.verify_checksum,
            "mode": args.replication_mode,
        },
    }

    connection = config["connection"]
    if args.dns_srv_name:
        connection["dns_srv_name"] = args.dns_srv_name
    else:
        connection["host"] = args.host
        connection["port"] = args.port
    connection["user"] = args.user
    connection["password"] = resolve_password(args)
    connection["connect_timeout"] = args.connect_timeout
    connection["read_timeout"] = args.read_timeout
    connection["write_timeout"] = args.write_timeout

    if args.ssl_mode:
        ssl: dict[str, Any] = {"mode": args.ssl_mode}
        for flag, key in (
            (args.ssl_ca, "ca"),
            (args.ssl_capath, "capath"),
            (args.ssl_crl, "crl"),
            (args.ssl_crlpath, "crlpath"),
            (args.ssl_cert, "cert"),
            (args.ssl_key, "key"),
            (args.ssl_cipher, "cipher"),
        ):
            if flag:
                ssl[key] = flag
        connection["ssl"] = ssl

    if args.tls_version or args.tls_ciphersuites:
        tls: dict[str, Any] = {}
        if args.tls_ciphersuites:
            tls["ciphersuites"] = args.tls_ciphersuites
        if args.tls_version:
            tls["version"] = args.tls_version
        connection["tls"] = tls

    if args.rewrite_file_size and args.rewrite_base_file_name:
        config["replication"]["rewrite"] = {
            "base_file_name": args.rewrite_base_file_name,
            "file_size": args.rewrite_file_size,
        }

    if args.keyring_path:
        config["keyring"] = {"uri": to_file_uri(args.keyring_path)}

    storage = config["storage"] = {
        "backend": args.storage_backend,
        "uri": build_storage_uri(args),
    }
    if args.fs_buffer_directory:
        storage["fs_buffer_directory"] = args.fs_buffer_directory
    if args.checkpoint_size:
        storage["checkpoint_size"] = args.checkpoint_size
    if args.checkpoint_interval:
        storage["checkpoint_interval"] = args.checkpoint_interval
    if args.encryption_kek_id and args.encryption_cipher:
        storage["encryption"] = {
            "format": "generic",
            "kek_id": args.encryption_kek_id,
            "cipher": args.encryption_cipher,
        }

    return config


def mask_secrets(config: dict[str, Any]) -> dict[str, Any]:
    masked = json.loads(json.dumps(config))
    if masked.get("connection", {}).get("password"):
        masked["connection"]["password"] = "***hidden***"
    uri = masked.get("storage", {}).get("uri", "")
    masked["storage"]["uri"] = re.sub(r"://([^:/]+):([^/]*)@", r"://\1:***@", uri)
    return masked


def main() -> int:
    args = build_parser().parse_args()

    try:
        prompt_if_missing(args)
        apply_defaults(args)
        validate_connection_identity(args)
        password = resolve_password(args)
        if args.ssl_auto_detect:
            apply_ssl_auto_detect(args, password)
        validate(args)
        config = build_config(args)
    except ConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    text = json.dumps(config, indent=2) + "\n"

    if args.stdout:
        print(text, end="")
        return 0

    if os.path.exists(args.output) and not args.force:
        print(f"error: {args.output} already exists (use --force to overwrite)", file=sys.stderr)
        return 2

    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(args.output, stat.S_IRUSR | stat.S_IWUSR)

    print(f"wrote {args.output}")
    print(json.dumps(mask_secrets(config), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

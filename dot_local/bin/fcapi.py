#!/usr/bin/env python3
"""
fcapi.py - Lightweight, portable CLI for FairCom JSON Action API.

Connects to FairCom API (e.g. https://localhost:8443/api), acquires an authentication
token using credentials, executes the requested action, and cleanly terminates the session.
Zero external dependencies (uses standard library urllib, ssl, json).
"""

import argparse
import json
import netrc
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


COMMANDS = {
    "databases": ("db", "listDatabases", ()),
    "descuser": ("admin", "describeAccounts", ("username",)),
    "grantmanage": ("admin", "linkRoleWithPrivileges", ("roleName",)),
    "hasmanage": ("admin", "hasPermissions", ("userName",)),
    "services": ("admin", "listServices", ()),
    "tables": ("db", "listTables", ("databaseName",)),
}

COMMAND_PARAMS = {
    "descuser": {
        "describeRoles": True,
    },
    "grantmanage": {
        "resetPrivileges": True,
        "permissions": [{"privilege": "manageAnyServer"}],
    },
    "hasmanage": {
        "permissions": [{"privilege": "manageAnyServer"}],
    },
}


def parse_params(params_arg: str | None) -> dict:
    """Parse parameters from JSON string, @filename, or key=value pairs."""
    if not params_arg:
        return {}

    # If argument starts with @, read from file
    if params_arg.startswith("@"):
        filepath = params_arg[1:]
        with open(filepath, "r", encoding="utf-8") as f:
            return json.load(f)

    # Try parsing as standard JSON
    try:
        data = json.loads(params_arg)
        if isinstance(data, dict):
            return data
    except json.JSONDecodeError:
        pass

    # Try parsing key1=val1,key2=val2 format
    result = {}
    for item in params_arg.split(","):
        if "=" in item:
            k, v = item.split("=", 1)
            # Try auto-casting booleans or numbers
            k = k.strip()
            v = v.strip()
            if v.lower() == "true":
                v = True
            elif v.lower() == "false":
                v = False
            elif v.isdigit():
                v = int(v)
            result[k] = v
        else:
            raise ValueError(
                f"Cannot parse parameter '{item}'. Use valid JSON or 'key=value' format."
            )
    return result


def resolve_command(command: str, values: list[str]) -> tuple[str, str, dict]:
    """Resolve a shortcut command to its API namespace, action, and parameters."""
    if command not in COMMANDS:
        available = ", ".join(COMMANDS)
        raise ValueError(f"Unknown command '{command}'. Available commands: {available}")

    api, action, parameter_names = COMMANDS[command]
    if len(values) != len(parameter_names):
        usage = " ".join((command, *[f"<{name}>" for name in parameter_names]))
        raise ValueError(f"Usage: fcapi.py {usage}")

    params = {**COMMAND_PARAMS.get(command, {}), **dict(zip(parameter_names, values))}
    if "username" in params:
        params["usernames"] = [params.pop("username")]
    return api, action, params


def send_request(url: str, payload: dict, ssl_context: ssl.SSLContext) -> dict:
    """Send a POST request with JSON payload to FairCom API."""
    data_bytes = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data_bytes,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, context=ssl_context) as resp:
            content = resp.read().decode("utf-8")
            return json.loads(content)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        try:
            return json.loads(err_body)
        except json.JSONDecodeError:
            print(f"HTTP Error {e.code}: {e.reason}\n{err_body}", file=sys.stderr)
            sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Connection Error: {e.reason}", file=sys.stderr)
        sys.exit(1)


def create_session(url: str, user: str, password: str, ssl_context: ssl.SSLContext) -> str:
    """Authenticate with FairCom and return the authToken."""
    payload = {
        "api": "admin",
        "action": "createSession",
        "params": {
            "username": user,
            "password": password,
        },
    }
    resp = send_request(url, payload, ssl_context)
    if resp.get("errorCode", 0) != 0:
        err_msg = resp.get("errorMessage", "Unknown error")
        print(f"Authentication failed (code {resp.get('errorCode')}): {err_msg}", file=sys.stderr)
        sys.exit(1)

    token = resp.get("authToken")
    if not token:
        print("Error: No authToken received in server response.", file=sys.stderr)
        sys.exit(1)
    return token


def resolve_credentials(
    url: str, user: str | None, password: str | None
) -> tuple[str, str]:
    """Resolve credentials from explicit values and the URL host's .netrc entry."""
    hostname = urllib.parse.urlparse(url).hostname
    credentials = None
    if hostname and (user is None or password is None):
        try:
            credentials = netrc.netrc().authenticators(hostname)
        except FileNotFoundError:
            pass

    if credentials:
        netrc_user, _, netrc_password = credentials
        if user is None:
            user = netrc_user
        if password is None and user == netrc_user:
            password = netrc_password

    user = user or "admin"
    if password is None:
        raise ValueError(
            f"No password found for '{user}' at '{hostname}'. "
            "Set FC_PASSWORD, use --password, or add a matching .netrc entry."
        )

    return user, password


def delete_session(url: str, token: str, ssl_context: ssl.SSLContext) -> None:
    """Delete an active session."""
    payload = {
        "api": "admin",
        "action": "deleteSession",
        "authToken": token,
    }
    try:
        send_request(url, payload, ssl_context)
    except Exception:
        pass


def build_ssl_context(insecure: bool, cacert: str | None) -> ssl.SSLContext:
    """Build SSL context honoring insecure or custom CA bundle options."""
    if cacert:
        ctx = ssl.create_default_context(cafile=cacert)
        return ctx
    if insecure:
        ctx = ssl._create_unverified_context()
        return ctx
    return ssl.create_default_context()


def main():
    parser = argparse.ArgumentParser(
        description="fcapi - FairCom JSON Action API Command-Line Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # List all databases (using credentials from env or ~/.netrc)
  fcapi.py
    fcapi.py databases

  # List tables in database 'faircom'
    fcapi.py tables faircom
  fcapi.py -a listTables -d '{"databaseName":"faircom"}'
  fcapi.py -a listTables -d databaseName=faircom

  # List services under the 'admin' API
    fcapi.py services
  fcapi.py --api admin -a listServices

Shortcut commands:
    databases              List all databases
    descuser <username>    Describe a user account and its roles
    grantmanage <roleName> Grant manageAnyServer to a role
    hasmanage <username>   Check whether a user has manageAnyServer
    tables <databaseName>  List tables in a database
    services               List admin API services

  # Only print the resulting data field
  fcapi.py -q

  # Get just the auth token
  fcapi.py --token-only

    # Use a custom host (looks up 10.0.0.1 in ~/.netrc)
    fcapi.py --url https://10.0.0.1:8443/api -a listDatabases
""",
    )

    parser.add_argument(
        "command",
        nargs="?",
        help="Shortcut command (databases, descuser, grantmanage, hasmanage, tables, or services)",
    )
    parser.add_argument(
        "command_args",
        nargs="*",
        metavar="VALUE",
        help="Values required by the shortcut command",
    )

    parser.add_argument(
        "--url",
        default=os.environ.get("FC_API_URL", "https://localhost:8443/api"),
        help="FairCom API URL (default: env FC_API_URL or https://localhost:8443/api)",
    )
    parser.add_argument(
        "-u",
        "--user",
        default=os.environ.get("FC_USER"),
        help="FairCom username (default: env FC_USER, .netrc login, or admin)",
    )
    parser.add_argument(
        "-p",
        "--password",
        default=os.environ.get("FC_PASSWORD"),
        help="FairCom password (default: env FC_PASSWORD or .netrc password)",
    )
    parser.add_argument(
        "--api",
        default="db",
        help="Target API namespace (default: db; e.g. db, admin, hub, mq)",
    )
    parser.add_argument(
        "-a",
        "--action",
        default="listDatabases",
        help="Action name to execute (default: listDatabases)",
    )
    parser.add_argument(
        "-d",
        "--params",
        default=None,
        help="Parameters as JSON string ('{\"k\":\"v\"}'), key=val pairs ('k=v'), or file ('@params.json')",
    )
    parser.add_argument(
        "--token",
        default=None,
        help="Use existing authToken directly (skips login and logout)",
    )
    parser.add_argument(
        "--token-only",
        action="store_true",
        help="Authenticate, output only the authToken, and exit (leaves session open)",
    )
    parser.add_argument(
        "--keep-session",
        action="store_true",
        help="Do not delete the session after executing the action",
    )
    parser.add_argument(
        "-q",
        "--quiet",
        action="store_true",
        help="Print only the 'result' portion of the JSON response",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="Output raw unformatted JSON instead of pretty-printed JSON",
    )
    parser.add_argument(
        "-k",
        "--insecure",
        action="store_true",
        default=True,
        help="Allow insecure SSL connections / ignore self-signed certificates (default: True)",
    )
    parser.add_argument(
        "--cacert",
        default=None,
        help="Path to custom CA certificate file",
    )
    args = parser.parse_args()

    shortcut_params = {}
    if args.command:
        try:
            args.api, args.action, shortcut_params = resolve_command(
                args.command, args.command_args
            )
        except ValueError as error:
            parser.error(str(error))

    ssl_context = build_ssl_context(args.insecure, args.cacert)

    if not args.token:
        try:
            args.user, args.password = resolve_credentials(
                args.url, args.user, args.password
            )
        except (FileNotFoundError, netrc.NetrcParseError, OSError, ValueError) as error:
            parser.error(str(error))

    # If --token-only requested:
    if args.token_only:
        token = create_session(args.url, args.user, args.password, ssl_context)
        print(token)
        return

    # Obtain token or use provided one
    provided_token = bool(args.token)
    token = args.token if provided_token else create_session(args.url, args.user, args.password, ssl_context)

    try:
        # Build command payload
        params = parse_params(args.params)
        params = {**shortcut_params, **params}
        payload = {
            "api": args.api,
            "action": args.action,
            "authToken": token,
        }
        if params:
            payload["params"] = params

        res = send_request(args.url, payload, ssl_context)

        # Output formatting
        out_obj = res.get("result", res) if args.quiet else res
        if args.raw:
            print(json.dumps(out_obj))
        else:
            print(json.dumps(out_obj, indent=2))

        # Check if error returned in response payload
        err_code = res.get("errorCode", 0)
        if err_code != 0:
            sys.exit(err_code)

    finally:
        # Only cleanup if we initiated the session and --keep-session wasn't set
        if not provided_token and not args.keep_session:
            delete_session(args.url, token, ssl_context)


if __name__ == "__main__":
    main()

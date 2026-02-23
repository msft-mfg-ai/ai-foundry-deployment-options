"""
Generate a bearer token from Entra ID using MSAL client credentials flow.

Usage:
    python generate_token.py --tenant-id <TENANT_ID> --client-id <CLIENT_ID> \
        --client-secret <CLIENT_SECRET> --audience <AUDIENCE>

The token can then be used as:
    curl -H "Authorization: Bearer <token>" https://apim-xxx.azure-api.net/inference/openai/...
"""

import argparse
import json
import subprocess
import sys

import jwt  # PyJWT - for decoding (not validation) to inspect claims
import msal


def get_azd_env_values() -> dict[str, str]:
    """Read all values from azd env and return as a dict."""
    result = subprocess.run(
        ["azd", "env", "get-values"],
        capture_output=True,
        text=True,
        check=True,
    )
    values = {}
    for line in result.stdout.strip().splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            # Strip surrounding quotes if present
            values[key.strip()] = value.strip().strip("'\"")
    return values


def get_token(tenant_id: str, client_id: str, client_secret: str, audience: str) -> dict:
    """Acquire a token using MSAL client credentials flow."""
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    app = msal.ConfidentialClientApplication(
        client_id,
        authority=authority,
        client_credential=client_secret,
    )
    result = app.acquire_token_for_client(scopes=[f"{audience}/.default"])

    if "access_token" in result:
        return result
    else:
        raise RuntimeError(
            f"Failed to acquire token: {result.get('error_description', result.get('error'))}"
        )


def main():
    parser = argparse.ArgumentParser(
        description="Generate bearer tokens for the AI Gateway Quota POC"
    )
    parser.add_argument("--tenant-id", help="Entra ID tenant ID")
    parser.add_argument("--client-id", help="Application (client) ID")
    parser.add_argument("--client-secret", help="Application client secret")
    parser.add_argument(
        "--audience",
        help="Gateway audience (Application ID URI, e.g., api://<app-name>)",
    )
    parser.add_argument(
        "--from-azd",
        choices=["alpha", "beta", "gamma"],
        help="Read credentials from azd env for the specified team (alpha, beta, or gamma)",
    )
    parser.add_argument(
        "--decode",
        action="store_true",
        help="Also decode and print the token claims (without validation)",
    )
    args = parser.parse_args()

    if args.from_azd:
        env = get_azd_env_values()
        team = args.from_azd.upper()
        args.tenant_id = env["TENANT_ID"]
        args.audience = env["GATEWAY_AUDIENCE"]
        args.client_id = env[f"TEAM_{team}_APP_ID"]
        args.client_secret = env[f"TEAM_{team}_SECRET"]

    if not all([args.tenant_id, args.client_id, args.client_secret, args.audience]):
        parser.error(
            "Provide --tenant-id, --client-id, --client-secret, --audience "
            "or use --from-azd <team>"
        )

    result = get_token(args.tenant_id, args.client_id, args.client_secret, args.audience)
    token = result["access_token"]

    if args.decode:
        claims = jwt.decode(token, options={"verify_signature": False})
        print("=== Token Claims ===", file=sys.stderr)
        print(
            json.dumps(
                {k: claims[k] for k in ["azp", "appid", "aud", "iss", "tid"] if k in claims},
                indent=2,
            ),
            file=sys.stderr,
        )
        print("====================", file=sys.stderr)

    # Print just the token to stdout (for piping)
    print(token)


if __name__ == "__main__":
    main()

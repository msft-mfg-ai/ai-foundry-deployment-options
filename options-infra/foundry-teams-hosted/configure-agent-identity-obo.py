#!/usr/bin/env python3

import argparse
import json
import subprocess
import uuid


GRAPH_APP_ID = "00000003-0000-0000-c000-000000000000"
GRAPH_USER_READ_ID = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"


def run(*args: str, allow_failure: bool = False) -> str:
    result = subprocess.run(
        args,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode and not allow_failure:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def graph(method: str, url: str, body: dict | None = None) -> dict:
    args = [
        "az",
        "rest",
        "--method",
        method,
        "--url",
        url,
        "--headers",
        "Content-Type=application/json",
        "OData-Version=4.0",
        "--output",
        "json",
    ]
    if body is not None:
        args.extend(["--body", json.dumps(body, separators=(",", ":"))])
    output = run(*args)
    return json.loads(output) if output else {}


def ensure_resource_scope(
    required: list[dict],
    resource_app_id: str,
    scope_id: str,
) -> None:
    entry = next(
        (
            item
            for item in required
            if item.get("resourceAppId") == resource_app_id
        ),
        None,
    )
    access = {"id": scope_id, "type": "Scope"}
    if entry is None:
        required.append(
            {
                "resourceAppId": resource_app_id,
                "resourceAccess": [access],
            }
        )
        return
    if access not in entry.get("resourceAccess", []):
        entry.setdefault("resourceAccess", []).append(access)


def ensure_inheritance(blueprint_id: str, resource_app_id: str) -> None:
    base = (
        "https://graph.microsoft.com/v1.0/applications/"
        f"microsoft.graph.agentIdentityBlueprint/{blueprint_id}"
        "/inheritablePermissions"
    )
    existing = graph("GET", base).get("value", [])
    body = {
        "inheritableScopes": {
            "@odata.type": "#microsoft.graph.allAllowedScopes",
            "kind": "allAllowed",
        },
        "inheritableRoles": {
            "@odata.type": "#microsoft.graph.noRoles",
            "kind": "none",
        },
    }
    current = next(
        (
            item
            for item in existing
            if item.get("resourceAppId") == resource_app_id
        ),
        None,
    )
    if current is not None:
        if (
            current.get("inheritableScopes", {}).get("kind")
            == "allAllowed"
            and current.get("inheritableRoles", {}).get("kind")
            == "none"
        ):
            return
        graph("PATCH", f"{base}/{resource_app_id}", body)
    else:
        graph(
            "POST",
            base,
            {"resourceAppId": resource_app_id, **body},
        )


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Configure a Foundry Agent Identity blueprint for Teams "
            "SSO bootstrap and delegated OBO."
        )
    )
    parser.add_argument("--blueprint-client-id", required=True)
    parser.add_argument("--bot-app-id", required=True)
    parser.add_argument("--mcp-client-id")
    parser.add_argument("--mcp-scope")
    args = parser.parse_args()

    blueprint_id = args.blueprint_client_id
    blueprint_url = (
        "https://graph.microsoft.com/v1.0/applications/"
        f"microsoft.graph.agentIdentityBlueprint/{blueprint_id}"
    )
    blueprint = graph("GET", blueprint_url)
    identifier_uri = f"api://{blueprint_id}"

    api = blueprint.get("api") or {}
    scopes = list(api.get("oauth2PermissionScopes") or [])
    access_scope = next(
        (scope for scope in scopes if scope.get("value") == "access_as_user"),
        None,
    )
    scope_changed = access_scope is None
    if access_scope is None:
        access_scope = {
            "id": str(uuid.uuid4()),
            "adminConsentDescription": (
                "Allow the client to invoke this Agent Identity blueprint "
                "on behalf of the signed-in user."
            ),
            "adminConsentDisplayName": (
                "Access the Agent Identity blueprint as the user"
            ),
            "userConsentDescription": (
                "Allow the client to access the Agent Identity blueprint "
                "on your behalf."
            ),
            "userConsentDisplayName": (
                "Access the Agent Identity blueprint as you"
            ),
            "value": "access_as_user",
            "type": "Admin",
            "isEnabled": True,
        }
        scopes.append(access_scope)

    preauthorized = list(api.get("preAuthorizedApplications") or [])
    bot_preauth = next(
        (
            item
            for item in preauthorized
            if item.get("appId") == args.bot_app_id
        ),
        None,
    )
    preauth_changed = bot_preauth is None
    if bot_preauth is None:
        preauthorized.append(
            {
                "appId": args.bot_app_id,
                "delegatedPermissionIds": [access_scope["id"]],
            }
        )
    elif access_scope["id"] not in bot_preauth.get(
        "delegatedPermissionIds",
        [],
    ):
        preauth_changed = True
        bot_preauth.setdefault("delegatedPermissionIds", []).append(
            access_scope["id"]
        )

    identifiers = list(blueprint.get("identifierUris") or [])
    identifiers_changed = identifier_uri not in identifiers
    if identifier_uri not in identifiers:
        identifiers.append(identifier_uri)
    if identifiers_changed or scope_changed:
        graph(
            "PATCH",
            blueprint_url,
            {
                "identifierUris": identifiers,
                "api": {
                    **api,
                    "oauth2PermissionScopes": scopes,
                },
            },
        )
    if preauth_changed:
        graph(
            "PATCH",
            blueprint_url,
            {
                "api": {
                    **api,
                    "oauth2PermissionScopes": scopes,
                    "preAuthorizedApplications": preauthorized,
                },
            },
        )

    required = list(blueprint.get("requiredResourceAccess") or [])
    original_required = json.dumps(
        required,
        sort_keys=True,
        separators=(",", ":"),
    )
    ensure_resource_scope(
        required,
        GRAPH_APP_ID,
        GRAPH_USER_READ_ID,
    )
    inheritable_resources = [GRAPH_APP_ID]

    if args.mcp_client_id and args.mcp_scope:
        existing_mcp_access = next(
            (
                access
                for resource in required
                if resource.get("resourceAppId") == args.mcp_client_id
                for access in resource.get("resourceAccess", [])
                if access.get("type") == "Scope"
            ),
            None,
        )
        if existing_mcp_access is None:
            scope_value = args.mcp_scope.rstrip("/").rsplit("/", 1)[-1]
            service_principal = json.loads(
                run(
                    "az",
                    "ad",
                    "sp",
                    "show",
                    "--id",
                    args.mcp_client_id,
                    "--output",
                    "json",
                )
            )
            mcp_scope = next(
                (
                    scope
                    for scope in service_principal.get(
                        "oauth2PermissionScopes",
                        [],
                    )
                    if scope.get("value") == scope_value
                ),
                None,
            )
            if mcp_scope is None:
                raise RuntimeError(
                    f"Scope {scope_value!r} was not found on MCP application "
                    f"{args.mcp_client_id}."
                )
            ensure_resource_scope(
                required,
                args.mcp_client_id,
                mcp_scope["id"],
            )
        inheritable_resources.append(args.mcp_client_id)

    required_changed = json.dumps(
        required,
        sort_keys=True,
        separators=(",", ":"),
    ) != original_required
    if required_changed:
        graph(
            "PATCH",
            blueprint_url,
            {"requiredResourceAccess": required},
        )
    for resource_app_id in inheritable_resources:
        ensure_inheritance(blueprint_id, resource_app_id)

    if required_changed:
        consent = subprocess.run(
            [
                "az",
                "ad",
                "app",
                "permission",
                "admin-consent",
                "--id",
                blueprint_id,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if consent.returncode:
            print(
                "WARNING: admin consent was not granted automatically; run "
                f"'az ad app permission admin-consent --id {blueprint_id}' "
                "as a tenant administrator.",
            )
        elif consent.stdout.strip():
            print(consent.stdout.strip())

    run(
        "azd",
        "env",
        "set",
        "AGENT_IDENTITY_BLUEPRINT_CLIENT_ID",
        blueprint_id,
    )
    run(
        "azd",
        "env",
        "set",
        "AGENT_IDENTITY_SSO_RESOURCE",
        identifier_uri,
    )
    run(
        "azd",
        "env",
        "set",
        "AGENT_IDENTITY_SSO_SCOPES",
        f"{identifier_uri}/access_as_user offline_access",
    )
    print(
        "Configured Agent Identity blueprint delegated permissions for "
        "Graph and the requested MCP API."
    )


if __name__ == "__main__":
    main()

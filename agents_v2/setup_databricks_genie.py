"""Configure the Databricks workspace and Foundry Genie MCP connection."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


DATABRICKS_RESOURCE = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
OAUTH_INTEGRATION_NAME = "foundry-genie-mcp"
WAREHOUSE_NAME = "genie-demo-warehouse"
GENIE_SPACE_TITLE = "Foundry sales analytics"
STORAGE_CREDENTIAL_NAME = "genie-demo-storage"
EXTERNAL_LOCATION_NAME = "genie-demo-managed-location"


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def run(*args: str, capture: bool = True) -> str:
    result = subprocess.run(
        args,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else ""


def azd_get(name: str) -> str:
    result = subprocess.run(
        ("azd", "env", "get-value", name),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def azd_set(name: str, value: str) -> None:
    run("azd", "env", "set", name, value, capture=False)


def setting(name: str, default: str = "") -> str:
    return os.environ.get(name) or azd_get(name) or default


def access_token() -> str:
    return run(
        "az",
        "account",
        "get-access-token",
        "--resource",
        DATABRICKS_RESOURCE,
        "--query",
        "accessToken",
        "-o",
        "tsv",
    )


def service_principal_token(tenant_id: str, client_id: str, client_secret: str) -> str:
    data = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "client_credentials",
            "scope": f"{DATABRICKS_RESOURCE}/.default",
        }
    ).encode()
    req = urllib.request.Request(
        f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token",
        data=data,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.loads(response.read())["access_token"]
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(
            f"Service-principal token acquisition failed ({error.code}): {detail}"
        ) from error


def request(
    method: str,
    url: str,
    token: str,
    body: dict[str, Any] | None = None,
) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(1, 6):
        req = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as response:
                payload = response.read()
                return json.loads(payload) if payload else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            if error.code not in {429, 500, 502, 503, 504} or attempt == 5:
                raise RuntimeError(
                    f"{method} {url} failed ({error.code}): {detail}"
                ) from error
            retry_after = int(error.headers.get("Retry-After", "5"))
            print(
                f"Databricks API returned {error.code}; retrying in {retry_after}s "
                f"({attempt}/5)."
            )
            time.sleep(retry_after)
    raise AssertionError("unreachable")


def list_values(payload: Any, *keys: str) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in keys:
            value = payload.get(key)
            if isinstance(value, list):
                return value
    return []


def ensure_account_service_principal(
    token: str,
    account_id: str,
    workspace_id: str,
    application_id: str,
) -> str:
    filter_value = urllib.parse.quote(f'applicationId eq "{application_id}"')
    base = f"https://accounts.azuredatabricks.net/api/2.1/accounts/{account_id}/scim/v2/ServicePrincipals"
    matches = list_values(request("GET", f"{base}?filter={filter_value}", token), "Resources")
    if matches:
        principal_id = str(matches[0]["id"])
        print(f"Reusing Databricks account service principal {principal_id}.")
    else:
        created = request(
            "POST",
            base,
            token,
            {
                "schemas": ["urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal"],
                "applicationId": application_id,
                "displayName": f"foundry-genie-{application_id[:8]}",
                "active": True,
            },
        )
        principal_id = str(created["id"])
        print(f"Created Databricks account service principal {principal_id}.")

    assignment_url = (
        f"https://accounts.azuredatabricks.net/api/2.0/accounts/{account_id}"
        f"/workspaces/{workspace_id}/permissionassignments/principals/{principal_id}"
    )
    request("PUT", assignment_url, token, {"permissions": ["USER"]})
    print("Assigned the service principal to the Databricks workspace.")
    azd_set("DATABRICKS_ACCOUNT_PRINCIPAL_ID", principal_id)
    return principal_id


def verify_service_principal_access(workspace_url: str) -> None:
    tenant_id = azd_get("DATABRICKS_AUTOMATION_TENANT_ID")
    client_id = azd_get("DATABRICKS_AUTOMATION_CLIENT_ID")
    client_secret = azd_get("DATABRICKS_AUTOMATION_CLIENT_SECRET")
    if not tenant_id or not client_id or not client_secret:
        raise RuntimeError("Databricks automation service-principal credentials are incomplete.")

    for attempt in range(1, 7):
        try:
            token = service_principal_token(tenant_id, client_id, client_secret)
            request(
                "GET",
                f"{workspace_url}/api/2.0/preview/scim/v2/Me",
                token,
            )
            print("Verified Databricks workspace authentication as the service principal.")
            return
        except RuntimeError:
            if attempt == 6:
                raise
            print("Waiting for Databricks workspace assignment propagation.")
            time.sleep(10)


def ensure_oauth_integration(token: str, account_id: str) -> tuple[str, str, str]:
    client_id = azd_get("DATABRICKS_OAUTH_CLIENT_ID")
    client_secret = azd_get("DATABRICKS_OAUTH_CLIENT_SECRET")
    integration_id = azd_get("DATABRICKS_OAUTH_INTEGRATION_ID")
    redirect_url = setting("DATABRICKS_OAUTH_REDIRECT_URL", "https://ai.azure.com/")
    base = (
        f"https://accounts.azuredatabricks.net/api/2.0/accounts/{account_id}"
        "/oauth2/custom-app-integrations"
    )
    if client_id and client_secret and integration_id:
        request(
            "PATCH",
            f"{base}/{integration_id}",
            token,
            {"redirect_urls": [redirect_url]},
        )
        print("Reusing Databricks OAuth integration credentials from the azd environment.")
        print(f"Registered the Foundry OAuth redirect URL: {redirect_url}")
        return client_id, client_secret, integration_id

    integrations = list_values(
        request("GET", base, token),
        "apps",
        "custom_app_integrations",
        "results",
    )
    existing = next(
        (item for item in integrations if item.get("name") == OAUTH_INTEGRATION_NAME),
        None,
    )
    if existing:
        raise RuntimeError(
            "The Databricks OAuth integration already exists, but its one-time client "
            "secret is not in the azd environment. Delete that integration or set "
            "DATABRICKS_OAUTH_CLIENT_ID, DATABRICKS_OAUTH_CLIENT_SECRET, and "
            "DATABRICKS_OAUTH_INTEGRATION_ID before rerunning."
        )

    created = request(
        "POST",
        base,
        token,
        {
            "name": OAUTH_INTEGRATION_NAME,
            "redirect_urls": [redirect_url],
            "confidential": True,
            "scopes": ["genie", "offline_access"],
            "token_access_policy": {
                "access_token_ttl_in_minutes": 60,
                "refresh_token_ttl_in_minutes": 10080,
            },
        },
    )
    client_id = created["client_id"]
    client_secret = created["client_secret"]
    integration_id = created["integration_id"]
    azd_set("DATABRICKS_OAUTH_CLIENT_ID", client_id)
    azd_set("DATABRICKS_OAUTH_CLIENT_SECRET", client_secret)
    azd_set("DATABRICKS_OAUTH_INTEGRATION_ID", integration_id)
    print("Created the Databricks custom OAuth integration.")
    return client_id, client_secret, integration_id


def ensure_warehouse(token: str, workspace_url: str) -> str:
    warehouses_url = f"{workspace_url}/api/2.0/sql/warehouses"
    warehouses = list_values(request("GET", warehouses_url, token), "warehouses")
    existing = next((item for item in warehouses if item.get("name") == WAREHOUSE_NAME), None)
    if existing:
        warehouse_id = str(existing["id"])
        if existing.get("enable_serverless_compute"):
            request(
                "POST",
                f"{warehouses_url}/{warehouse_id}/edit",
                token,
                {"enable_serverless_compute": False},
            )
            print(f"Changed SQL warehouse {warehouse_id} to classic VNet-injected compute.")
        else:
            print(f"Reusing classic SQL warehouse {warehouse_id}.")
        return warehouse_id

    body = {
        "name": WAREHOUSE_NAME,
        "warehouse_type": "PRO",
        "enable_serverless_compute": False,
        "cluster_size": "2X-Small",
        "auto_stop_mins": 10,
        "min_num_clusters": 1,
        "max_num_clusters": 1,
        "enable_photon": True,
    }
    created = request("POST", warehouses_url, token, body)
    warehouse_id = str(created["id"])
    print(f"Created SQL warehouse {warehouse_id}.")
    return warehouse_id


def execute_sql(token: str, workspace_url: str, warehouse_id: str, statement: str) -> None:
    statements_url = f"{workspace_url}/api/2.0/sql/statements"
    response = request(
        "POST",
        statements_url,
        token,
        {
            "warehouse_id": warehouse_id,
            "statement": statement,
            "wait_timeout": "30s",
        },
    )
    statement_id = response.get("statement_id")
    status = (response.get("status") or {}).get("state")
    while statement_id and status in {"PENDING", "RUNNING"}:
        time.sleep(3)
        response = request("GET", f"{statements_url}/{statement_id}", token)
        status = (response.get("status") or {}).get("state")
    if status != "SUCCEEDED":
        raise RuntimeError(
            f"Databricks SQL statement failed with status {status}: "
            f"{json.dumps(response.get('status') or response)}"
        )


def ensure_managed_storage(
    token: str,
    workspace_url: str,
    access_connector_id: str,
    storage_url: str,
) -> None:
    credentials_url = f"{workspace_url}/api/2.1/unity-catalog/storage-credentials"
    credentials = list_values(
        request("GET", credentials_url, token),
        "storage_credentials",
    )
    if not any(item.get("name") == STORAGE_CREDENTIAL_NAME for item in credentials):
        request(
            "POST",
            credentials_url,
            token,
            {
                "name": STORAGE_CREDENTIAL_NAME,
                "comment": "Managed identity for the Foundry Genie demonstration data",
                "azure_managed_identity": {
                    "access_connector_id": access_connector_id,
                },
            },
        )
        print("Created the Unity Catalog storage credential.")
    else:
        print("Reusing the Unity Catalog storage credential.")

    locations_url = f"{workspace_url}/api/2.1/unity-catalog/external-locations"
    locations = list_values(
        request("GET", locations_url, token),
        "external_locations",
    )
    if not any(item.get("name") == EXTERNAL_LOCATION_NAME for item in locations):
        for attempt in range(1, 7):
            try:
                request(
                    "POST",
                    locations_url,
                    token,
                    {
                        "name": EXTERNAL_LOCATION_NAME,
                        "url": storage_url,
                        "credential_name": STORAGE_CREDENTIAL_NAME,
                        "comment": "Managed location for the Foundry Genie demonstration data",
                    },
                )
                break
            except RuntimeError:
                if attempt == 6:
                    raise
                print("Waiting for Azure storage RBAC propagation.")
                time.sleep(10)
        print("Created the Unity Catalog external location.")
    else:
        print("Reusing the Unity Catalog external location.")


def configure_sample_data(
    token: str,
    workspace_url: str,
    warehouse_id: str,
    service_principal_app_id: str | None,
    managed_storage_url: str,
) -> None:
    statements = [
        (
            "CREATE CATALOG IF NOT EXISTS genie_demo "
            f"MANAGED LOCATION '{managed_storage_url}/genie_demo' "
            "COMMENT 'Foundry Genie demonstration data'"
        ),
        "CREATE SCHEMA IF NOT EXISTS genie_demo.sales COMMENT 'Sales analytics sample'",
        """
        CREATE OR REPLACE TABLE genie_demo.sales.orders (
          order_id BIGINT NOT NULL,
          order_date DATE,
          region STRING COMMENT 'Sales region',
          product STRING COMMENT 'Product sold',
          quantity INT,
          amount DECIMAL(18,2) COMMENT 'Order revenue in US dollars'
        ) USING DELTA
        COMMENT 'Synthetic sales orders used by the Foundry Genie sample'
        """,
        """
        INSERT INTO genie_demo.sales.orders VALUES
          (1, DATE '2026-01-15', 'West', 'Widget A', 10, 1500.00),
          (2, DATE '2026-01-22', 'East', 'Widget B', 5, 750.00),
          (3, DATE '2026-02-03', 'Central', 'Widget A', 12, 1800.00),
          (4, DATE '2026-02-18', 'West', 'Widget C', 3, 1200.00),
          (5, DATE '2026-03-07', 'East', 'Widget A', 20, 3000.00),
          (6, DATE '2026-03-21', 'Central', 'Widget B', 8, 1200.00)
        """,
    ]
    if service_principal_app_id:
        statements.extend(
            [
                f"GRANT USE CATALOG ON CATALOG genie_demo TO `{service_principal_app_id}`",
                f"GRANT USE SCHEMA ON SCHEMA genie_demo.sales TO `{service_principal_app_id}`",
                f"GRANT SELECT ON TABLE genie_demo.sales.orders TO `{service_principal_app_id}`",
            ]
        )
    for statement in statements:
        if statement.startswith("GRANT "):
            for attempt in range(1, 7):
                try:
                    execute_sql(token, workspace_url, warehouse_id, statement)
                    break
                except RuntimeError:
                    if attempt == 6:
                        raise
                    print("Waiting for Databricks service-principal propagation before GRANT.")
                    time.sleep(10)
        else:
            execute_sql(token, workspace_url, warehouse_id, statement)
    if service_principal_app_id:
        print("Created sample data and granted read access to the service principal.")
    else:
        print("Created Unity Catalog sample data; service-principal grants are pending account registration.")


def ensure_genie_space(token: str, workspace_url: str, warehouse_id: str) -> str:
    spaces_url = f"{workspace_url}/api/2.0/genie/spaces"
    spaces = list_values(request("GET", spaces_url, token), "spaces")
    existing = next((item for item in spaces if item.get("title") == GENIE_SPACE_TITLE), None)
    if existing:
        space_id = str(existing.get("space_id") or existing.get("id"))
        print(f"Reusing Genie Agent {space_id}.")
        return space_id

    me = request("GET", f"{workspace_url}/api/2.0/preview/scim/v2/Me", token)
    parent_path = f"/Workspace/Users/{me['userName']}"
    serialized_space = {
        "version": 2,
        "config": {
            "sample_questions": [
                {
                    "id": "00000000000000000000000000000001",
                    "question": ["Which region generated the most revenue?"],
                },
                {
                    "id": "00000000000000000000000000000002",
                    "question": ["Show monthly revenue by product."],
                },
            ]
        },
        "data_sources": {
            "tables": [
                {
                    "identifier": "genie_demo.sales.orders",
                    "description": ["Synthetic sales order data for the Foundry sample."],
                    "column_configs": [
                        {
                            "column_name": "amount",
                            "description": ["Order revenue in US dollars."],
                        },
                        {"column_name": "product", "enable_entity_matching": True},
                        {"column_name": "region", "enable_entity_matching": True},
                    ],
                }
            ]
        },
        "instructions": {
            "text_instructions": [
                {
                    "id": "00000000000000000000000000000003",
                    "content": [
                        "Use the amount column for revenue and round currency values to two decimals."
                    ],
                }
            ],
            "example_question_sqls": [
                {
                    "id": "00000000000000000000000000000004",
                    "question": ["Show revenue by region."],
                    "sql": [
                        "SELECT region, SUM(amount) AS revenue FROM genie_demo.sales.orders GROUP BY region ORDER BY revenue DESC"
                    ],
                }
            ],
        },
    }
    created = request(
        "POST",
        spaces_url,
        token,
        {
            "title": GENIE_SPACE_TITLE,
            "description": "Answers questions about the synthetic sales order dataset.",
            "warehouse_id": warehouse_id,
            "parent_path": parent_path,
            "serialized_space": json.dumps(serialized_space, separators=(",", ":")),
        },
    )
    space_id = str(created.get("space_id") or created["id"])
    print(f"Created Genie Agent {space_id}.")
    return space_id


def create_foundry_connection(
    project_endpoint: str,
    workspace_url: str,
    genie_one_url: str,
    client_id: str,
    client_secret: str,
) -> None:
    run(
        "azd",
        "ai",
        "connection",
        "create",
        "databricks-genie-one",
        "--project-endpoint",
        project_endpoint,
        "--kind",
        "remote-tool",
        "--target",
        genie_one_url,
        "--auth-type",
        "oauth2",
        "--authorization-url",
        f"{workspace_url}/oidc/v1/authorize",
        "--token-url",
        f"{workspace_url}/oidc/v1/token",
        "--refresh-url",
        f"{workspace_url}/oidc/v1/token",
        "--client-id",
        client_id,
        "--client-secret",
        client_secret,
        "--scopes",
        "genie,offline_access",
        "--force",
        "--no-prompt",
        capture=False,
    )
    print("Created or updated the Foundry Databricks Genie One connection.")


def main() -> None:
    workspace_url = required_env("DATABRICKS_WORKSPACE_URL").rstrip("/")
    workspace_id = required_env("DATABRICKS_WORKSPACE_ID")
    access_connector_id = required_env("DATABRICKS_ACCESS_CONNECTOR_ID")
    managed_storage_url = required_env("DATABRICKS_MANAGED_STORAGE_URL")
    project_endpoint = required_env("FOUNDRY_PROJECT_CONNECTION_STRING")
    subscription_id = required_env("AZURE_SUBSCRIPTION_ID")
    resource_group = required_env("AZURE_RESOURCE_GROUP")
    foundry_name = required_env("FOUNDRY_NAME")
    project_name = required_env("FOUNDRY_PROJECT_NAME")
    genie_one_url = required_env("DATABRICKS_GENIE_ONE_MCP_URL")
    automation_app_id = setting("DATABRICKS_AUTOMATION_CLIENT_ID")
    if not automation_app_id:
        raise RuntimeError("Missing DATABRICKS_AUTOMATION_CLIENT_ID in the azd environment.")
    account_id = setting("DATABRICKS_ACCOUNT_ID")
    token = access_token()

    if account_id:
        ensure_account_service_principal(
            token,
            account_id,
            workspace_id,
            automation_app_id,
        )
        verify_service_principal_access(workspace_url)
        oauth_client_id, oauth_client_secret, _ = ensure_oauth_integration(token, account_id)
    else:
        print(
            "DATABRICKS_ACCOUNT_ID is not set. Account-level service-principal "
            "registration and OAuth app creation are skipped."
        )
        oauth_client_id = azd_get("DATABRICKS_OAUTH_CLIENT_ID")
        oauth_client_secret = azd_get("DATABRICKS_OAUTH_CLIENT_SECRET")

    warehouse_id = ensure_warehouse(token, workspace_url)
    azd_set("DATABRICKS_WAREHOUSE_ID", warehouse_id)
    ensure_managed_storage(
        token,
        workspace_url,
        access_connector_id,
        managed_storage_url,
    )

    if account_id:
        grant_principal = automation_app_id
    else:
        grant_principal = None
    configure_sample_data(
        token,
        workspace_url,
        warehouse_id,
        grant_principal,
        managed_storage_url,
    )

    try:
        space_id = ensure_genie_space(token, workspace_url, warehouse_id)
        azd_set("DATABRICKS_GENIE_SPACE_ID", space_id)
        azd_set(
            "DATABRICKS_GENIE_AGENT_MCP_URL",
            f"{workspace_url}/api/2.0/mcp/genie/{space_id}",
        )
    except RuntimeError as error:
        print(f"WARNING: Genie Agent creation was not available: {error}", file=sys.stderr)

    if oauth_client_id and oauth_client_secret:
        create_foundry_connection(
            project_endpoint,
            workspace_url,
            genie_one_url,
            oauth_client_id,
            oauth_client_secret,
        )
        azd_set("DATABRICKS_FOUNDRY_CONNECTION_READY", "true")
    else:
        azd_set("DATABRICKS_FOUNDRY_CONNECTION_READY", "false")
        print("Foundry connection creation is waiting for Databricks OAuth credentials.")

    tenant_id = setting("AZURE_TENANT_ID") or run(
        "az", "account", "show", "--query", "tenantId", "-o", "tsv"
    )
    project_resource_id = (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{foundry_name}"
        f"/projects/{project_name}"
    )
    databricks_previews_url = "https://accounts.azuredatabricks.net/previews"
    if account_id:
        databricks_previews_url += "?" + urllib.parse.urlencode(
            {"account_id": account_id}
        )
    foundry_project_url = (
        "https://ai.azure.com/resource/overview?"
        + urllib.parse.urlencode(
            {
                "tid": tenant_id,
                "wsid": project_resource_id,
            }
        )
    )
    azd_set("DATABRICKS_PREVIEWS_URL", databricks_previews_url)
    azd_set("FOUNDRY_PROJECT_URL", foundry_project_url)
    print("Manual step: enable the Managed MCP Servers preview:")
    print(f"  {databricks_previews_url}")
    print("Foundry project:")
    print(f"  {foundry_project_url}")


if __name__ == "__main__":
    main()

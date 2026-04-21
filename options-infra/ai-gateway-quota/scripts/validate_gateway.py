"""
Validation test for the AI Gateway Quota (JWT Citadel with Priority Routing).
Runs against a live deployment using credentials from azd env.
"""

import json
import subprocess
import sys

import jwt  # PyJWT
import msal
import requests

# --- Read config from azd env ---
TOKEN_AUDIENCE = "https://cognitiveservices.azure.com"


def get_azd_env_values() -> dict[str, str]:
    result = subprocess.run(
        ["azd", "env", "get-values"], capture_output=True, text=True, check=True
    )
    values = {}
    for line in result.stdout.strip().splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip("'\"")
    return values


env = get_azd_env_values()
TENANT_ID = env["TENANT_ID"]
APIM_API_URL = env["APIM_API_URL"]
CONFIG_URL = env.get("APIM_CONFIG_URL", env["APIM_GATEWAY_URL"] + "/gateway/config")

TEAMS = {
    "Team Alpha2": {
        "client_id": env["TEAM_ALPHA_APP_ID"],
        "secret": env["TEAM_ALPHA_SECRET"],
        "priority": 1,
        "models": ["gpt-4.1-mini", "gpt-oss-120b"],
        "denied_model": "gpt-5.1-chat",
    },
    "Team Beta2": {
        "client_id": env["TEAM_BETA2_APP_ID"],
        "secret": env["TEAM_BETA2_SECRET"],
        "priority": 2,
        "models": ["gpt-4.1-mini", "gpt-5.1-chat"],
        "denied_model": "gpt-4.1",
    },
    "Team Gamma2": {
        "client_id": env["TEAM_GAMMA2_APP_ID"],
        "secret": env["TEAM_GAMMA2_SECRET"],
        "priority": 3,
        "models": ["gpt-4.1-mini", "gpt-4.1"],
        "denied_model": "gpt-oss-120b",
    },
}

total = 0
passed = 0
results = []


def test(name, condition, detail=""):
    global total, passed
    total += 1
    status = "PASS" if condition else "FAIL"
    if condition:
        passed += 1
    msg = f"{status} | {name}"
    if detail:
        msg += f" -- {detail}"
    print(msg)
    results.append((name, condition, detail))


def get_token(client_id, secret):
    app = msal.ConfidentialClientApplication(
        client_id,
        authority=f"https://login.microsoftonline.com/{TENANT_ID}",
        client_credential=secret,
    )
    result = app.acquire_token_for_client(scopes=[f"{TOKEN_AUDIENCE}/.default"])
    if "access_token" not in result:
        raise RuntimeError(
            f"Token error: {result.get('error_description', result.get('error'))}"
        )
    return result["access_token"]


def chat_completion(token, model, max_tokens=5):
    url = f"{APIM_API_URL}/deployments/{model}/chat/completions?api-version=2024-12-01-preview"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    body = {
        "messages": [{"role": "user", "content": "Say hello in one word."}],
        "max_completion_tokens": max_tokens,
    }
    return requests.post(url, headers=headers, json=body, timeout=30)


def main():
    print("=" * 70)
    print("AI Gateway Quota -- Validation Tests")
    print("=" * 70)

    # --- Test 1: Config endpoint ---
    print("\n--- Test: Config Endpoint ---")
    try:
        r = requests.get(CONFIG_URL, timeout=10)
        test("Config endpoint exists", r.status_code in [200, 401, 403], f"status={r.status_code}")
    except Exception as e:
        test("Config endpoint exists", False, str(e))

    # --- Test 2: Unauthenticated request -> 401 ---
    print("\n--- Test: Unauthenticated Access ---")
    try:
        r = requests.post(
            f"{APIM_API_URL}/deployments/gpt-4.1-mini/chat/completions?api-version=2024-12-01-preview",
            headers={"Content-Type": "application/json"},
            json={"messages": [{"role": "user", "content": "hi"}], "max_tokens": 5},
            timeout=10,
        )
        test("Unauthenticated -> 401", r.status_code == 401, f"status={r.status_code}")
    except Exception as e:
        test("Unauthenticated -> 401", False, str(e))

    # --- Test per team ---
    for team_name, cfg in TEAMS.items():
        print(f"\n--- Team: {team_name} (Priority {cfg['priority']}) ---")

        # Get token
        try:
            token = get_token(cfg["client_id"], cfg["secret"])
            claims = jwt.decode(token, options={"verify_signature": False})
            test(
                f"{team_name}: Token acquired",
                True,
                f"azp={claims.get('azp', claims.get('appid', '?'))}",
            )
        except Exception as e:
            test(f"{team_name}: Token acquired", False, str(e))
            continue

        # Test first allowed model
        model = cfg["models"][0]
        try:
            r = chat_completion(token, model)
            test(
                f"{team_name}: {model} -> 200",
                r.status_code == 200,
                f"status={r.status_code}",
            )

            if r.status_code != 200:
                print(f"   Response body: {r.text[:500]}")
                continue

            # Check response headers
            h = r.headers
            caller = h.get("x-caller-name", "")
            priority = h.get("x-caller-priority", "")
            route = h.get("x-route-target", "")
            remaining = h.get("x-ratelimit-remaining-tokens", "")

            test(
                f"{team_name}: x-caller-name header",
                bool(caller),
                f'value="{caller}"',
            )
            test(
                f"{team_name}: x-caller-priority header",
                bool(priority),
                f'value="{priority}"',
            )
            test(
                f"{team_name}: x-route-target header",
                route in ["mixed", "payg"],
                f'value="{route}"',
            )
            test(
                f"{team_name}: x-ratelimit-remaining-tokens",
                bool(remaining),
                f'value="{remaining}"',
            )

            # P1 should route to mixed pool (for models with PTU)
            if cfg["priority"] == 1 and model == "gpt-4.1-mini":
                test(
                    f"{team_name}: P1 routes to mixed pool",
                    route == "mixed",
                    f'route="{route}"',
                )
            # P3 should always be PAYG
            if cfg["priority"] == 3:
                test(
                    f"{team_name}: P3 routes to PAYG",
                    route == "payg",
                    f'route="{route}"',
                )

            # Print completion content
            body = r.json()
            content = (
                body.get("choices", [{}])[0].get("message", {}).get("content", "")
            )
            print(f'   Response: "{content}"')

        except Exception as e:
            test(f"{team_name}: {model} -> 200", False, str(e))

        # Test denied model -> should be 403/401/404
        denied = cfg.get("denied_model")
        if denied:
            try:
                r = chat_completion(token, denied)
                test(
                    f"{team_name}: {denied} -> denied",
                    r.status_code in [403, 401, 404, 429],
                    f"status={r.status_code}",
                )
            except Exception as e:
                test(f"{team_name}: {denied} -> denied", False, str(e))

    # --- Test: Second allowed model per team ---
    print("\n--- Test: Additional Models ---")
    for team_name, cfg in TEAMS.items():
        if len(cfg["models"]) > 1:
            model = cfg["models"][1]
            try:
                token = get_token(cfg["client_id"], cfg["secret"])
                r = chat_completion(token, model)
                test(
                    f"{team_name}: {model} -> 200",
                    r.status_code == 200,
                    f"status={r.status_code}",
                )
                if r.status_code != 200:
                    print(f"   Response body: {r.text[:500]}")
            except Exception as e:
                test(f"{team_name}: {model}", False, str(e))

    # --- Summary ---
    print("\n" + "=" * 70)
    print(f"Results: {passed}/{total} passed")
    if passed == total:
        print("All tests passed!")
    else:
        failed = [(n, d) for n, c, d in results if not c]
        print(f"{len(failed)} test(s) failed:")
        for name, detail in failed:
            print(f"   FAIL {name}: {detail}")
    print("=" * 70)

    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()

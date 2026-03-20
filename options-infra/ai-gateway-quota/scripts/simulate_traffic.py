"""
Simulate traffic from multiple application teams to the AI Gateway.

Each team authenticates via Entra ID (MSAL client credentials flow),
and the APIM gateway applies quota limits based on the azp claim → tier mapping.

Usage:
    python simulate_traffic.py --config config.json [--requests-per-team 10] [--model gpt-4.1-mini]
"""

import argparse
import json
import time

import msal
import requests as http_requests


def get_token(tenant_id: str, client_id: str, client_secret: str, audience: str) -> str:
    """Acquire a bearer token using MSAL client credentials flow."""
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    app = msal.ConfidentialClientApplication(
        client_id,
        authority=authority,
        client_credential=client_secret,
    )
    result = app.acquire_token_for_client(scopes=[f"{audience}/.default"])
    if "access_token" in result:
        return result["access_token"]
    raise RuntimeError(
        f"Token error: {result.get('error_description', result.get('error'))}"
    )


def send_chat_request(
    gateway_url: str,
    token: str,
    model: str,
    prompt: str,
    team_name: str,
    api_version: str,
) -> int:
    """Send a single chat completion request and return the HTTP status code."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 50,
    }
    url = (
        f"{gateway_url}/deployments/{model}/chat/completions?api-version={api_version}"
    )

    start = time.time()
    try:
        resp = http_requests.post(url, headers=headers, json=body, timeout=30)
        elapsed = time.time() - start
        status = resp.status_code
        remaining = resp.headers.get("x-ratelimit-remaining-tokens", "N/A")
        tier = resp.headers.get("x-caller-tier", "N/A")

        if status == 200:
            print(
                f"  ✅ [{team_name}] {status} ({elapsed:.1f}s) tier={tier} remaining={remaining}"
            )
        elif status == 429:
            print(
                f"  ⚠️  [{team_name}] {status} RATE LIMITED ({elapsed:.1f}s) tier={tier}"
            )
        elif status == 401:
            print(f"  🔒 [{team_name}] {status} UNAUTHORIZED ({elapsed:.1f}s)")
        elif status == 403:
            print(
                f"  🚫 [{team_name}] {status} FORBIDDEN ({elapsed:.1f}s): {resp.text[:200]}"
            )
        else:
            print(f"  ❌ [{team_name}] {status} ({elapsed:.1f}s): {resp.text[:200]}")
        return status
    except Exception as e:
        print(f"  ❌ [{team_name}] Error: {e}")
        return 0


def main():
    parser = argparse.ArgumentParser(
        description="Simulate multi-team traffic to the AI Gateway with quota tiers"
    )
    parser.add_argument("--config", required=True, help="Path to config JSON file")
    parser.add_argument(
        "--requests-per-team",
        type=int,
        default=5,
        help="Number of requests per team (default: 5)",
    )
    parser.add_argument("--model", default="gpt-4.1-mini", help="Model deployment name")
    parser.add_argument(
        "--prompt", default="Say hello in one word.", help="Prompt to send"
    )
    parser.add_argument(
        "--api-version", default="2024-02-01", help="Azure OpenAI API version"
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.5,
        help="Delay in seconds between requests (default: 0.5)",
    )
    args = parser.parse_args()

    with open(args.config) as f:
        config = json.load(f)

    gateway_url = config["gateway_url"].rstrip("/")
    tenant_id = config["tenant_id"]
    audience = config["audience"]
    teams = config["teams"]

    print("=" * 60)
    print("  AI Gateway Quota - Traffic Simulation")
    print("=" * 60)
    print(f"  🎯 Gateway:  {gateway_url}")
    print(f"  📊 Model:    {args.model}")
    print(f"  🔄 Requests: {args.requests_per_team} per team")
    print(f"  👥 Teams:    {len(teams)}")
    print("=" * 60)
    print()

    # Get tokens for all teams
    team_tokens = {}
    for team in teams:
        name = team["name"]
        tier = team["tier"]
        print(f"🔑 Getting token for {name} ({tier} tier)...")
        try:
            token = get_token(
                tenant_id, team["client_id"], team["client_secret"], audience
            )
            team_tokens[name] = token
            print("   ✅ Token acquired")
        except Exception as e:
            print(f"   ❌ Failed: {e}")
            team_tokens[name] = None
    print()

    # Send requests for each team
    results = {"total": 0, "success": 0, "rate_limited": 0, "forbidden": 0, "errors": 0}

    for team in teams:
        name = team["name"]
        tier = team["tier"]
        token = team_tokens.get(name)

        if token is None:
            print(f"⏭️  Skipping {name} (no token)")
            continue

        print(
            f"📤 Sending {args.requests_per_team} requests as {name} ({tier} tier)..."
        )

        for i in range(args.requests_per_team):
            status = send_chat_request(
                gateway_url, token, args.model, args.prompt, name, args.api_version
            )
            results["total"] += 1
            if status == 200:
                results["success"] += 1
            elif status == 429:
                results["rate_limited"] += 1
            elif status == 403:
                results["forbidden"] += 1
            else:
                results["errors"] += 1
            time.sleep(args.delay)
        print()

    # Summary
    print("=" * 60)
    print("  📊 Results Summary")
    print("=" * 60)
    print(f"  Total requests:   {results['total']}")
    print(f"  ✅ Successful:    {results['success']}")
    print(f"  ⚠️  Rate limited:  {results['rate_limited']}")
    print(f"  🚫 Forbidden:     {results['forbidden']}")
    print(f"  ❌ Errors:        {results['errors']}")
    print("=" * 60)


if __name__ == "__main__":
    main()

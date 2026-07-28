"""
One-time interactive login for the Foundry portal.

Run once:
    uv run python auth_setup.py

Steps performed:
1. Launches a real Chromium window (headed).
2. Navigates to https://ai.azure.com/.
3. YOU sign in as the user under test (e.g. Joe: SimpleJoe@MngEnvMCAP272273.onmicrosoft.com).
4. Press <Enter> in the terminal once you're on the Foundry home / project overview.
5. Storage state is saved to .auth/joe.json — subsequent pytest runs reuse it.

Rerun this any time your session expires (Foundry cookies are typically valid ~1h).
"""
from __future__ import annotations

import pathlib
import sys

from dotenv import load_dotenv
from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).parent
load_dotenv(HERE / ".env")

import os

PORTAL = os.environ.get("FOUNDRY_PORTAL_HOME", "https://ai.azure.com/")
STATE = HERE / os.environ.get("STORAGE_STATE_PATH", ".auth/joe.json")
STATE.parent.mkdir(parents=True, exist_ok=True)


def main() -> int:
    print(f"Opening {PORTAL} — please sign in as the user under test.")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False, args=["--start-maximized"])
        context = browser.new_context(no_viewport=True)
        page = context.new_page()
        page.goto(PORTAL, wait_until="domcontentloaded")

        print()
        print("=" * 72)
        print("Sign in in the browser window that just opened.")
        print("When you land on the Foundry home page (or your project), come back")
        print("to this terminal and press <Enter> to save the auth state.")
        print("=" * 72)
        try:
            input("Press <Enter> when you are signed in: ")
        except KeyboardInterrupt:
            print("Aborted.")
            return 1

        context.storage_state(path=str(STATE))
        print(f"\nStorage state saved to {STATE}")
        browser.close()
    print("Done. Run `uv run pytest` to execute the UI test suite.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

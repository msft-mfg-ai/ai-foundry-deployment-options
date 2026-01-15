"""CLI entry point for the subscription manager."""

import uvicorn

from app.config import get_settings


def main():
    """Start the application server."""
    settings = get_settings()
    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        reload=settings.debug,
    )


if __name__ == "__main__":
    main()

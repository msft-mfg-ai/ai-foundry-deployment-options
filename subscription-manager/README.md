# Subscription Manager

A web application for managing Azure API Management subscriptions for LLM access. Track token usage, set limits, and enable/disable subscriptions.

## Features

- 📊 **Token Usage Tracking**: View token usage per subscription over time
- 🔒 **Subscription Limits**: Set and manage token limits for each subscription
- ⚡ **Enable/Disable**: Quickly toggle subscription status
- 📈 **Analytics Dashboard**: Visualize usage patterns with charts

## Tech Stack

- **Backend**: Python 3.11+ with FastAPI
- **Frontend**: Server-side rendered HTML with HTMX + Tailwind CSS
- **Charts**: Chart.js for usage visualization
- **Azure**: Azure API Management SDK, Azure Monitor for metrics

## Prerequisites

- Python 3.11 or higher
- Azure subscription with API Management instance
- Azure CLI (for authentication)

## Quick Start

1. **Clone and setup**:
   ```bash
   cd subscription-manager
   python -m venv .venv
   source .venv/bin/activate  # On Windows: .venv\Scripts\activate
   pip install -e .
   ```

2. **Configure environment**:
   ```bash
   cp .env.example .env
   # Edit .env with your Azure settings
   ```

3. **Login to Azure**:
   ```bash
   az login
   ```

4. **Run the application**:
   ```bash
   python -m uvicorn app.main:app --reload
   ```

5. Open http://localhost:8000 in your browser

## Project Structure

```
subscription-manager/
├── app/
│   ├── main.py              # FastAPI application entry
│   ├── config.py            # Configuration settings
│   ├── models/              # Pydantic models
│   ├── services/            # Business logic & Azure integration
│   ├── routers/             # API routes
│   ├── templates/           # Jinja2 HTML templates
│   └── static/              # CSS, JS assets
├── tests/                   # Test files
├── pyproject.toml           # Project dependencies
└── README.md
```

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID | Yes |
| `AZURE_RESOURCE_GROUP` | Resource group containing APIM | Yes |
| `APIM_SERVICE_NAME` | API Management service name | Yes |
| `USE_MOCK_DATA` | Use mock data for development | No |

## Development

```bash
# Install dev dependencies
pip install -e ".[dev]"

# Run tests
pytest

# Run linter
ruff check .

# Format code
ruff format .
```

## License

MIT

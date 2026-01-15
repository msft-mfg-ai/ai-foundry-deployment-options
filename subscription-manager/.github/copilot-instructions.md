# Subscription Manager - Agent Instructions

## Project Overview

This is an **API Management Subscription Manager** web application for managing Azure APIM subscriptions that provide access to LLM/AI services. The app tracks token usage, enforces limits, and allows enabling/disabling subscriptions.

## Tech Stack

- **Runtime**: Python 3.11+
- **Package Manager**: `uv` (preferred) or pip
- **Web Framework**: FastAPI with Jinja2 server-side templates
- **Frontend**: HTMX for dynamic updates, Tailwind CSS (CDN), Chart.js for visualizations
- **Azure SDKs**: azure-identity, azure-mgmt-apimanagement (v4.0.0), azure-monitor-query
- **Data Validation**: Pydantic v2 with pydantic-settings
- **Testing**: pytest + pytest-playwright for E2E tests
- **Build System**: hatchling

## Project Structure

```
subscription-manager/
├── app/
│   ├── main.py              # FastAPI app entry point, mounts routers
│   ├── cli.py               # CLI entry point for `uv run start`
│   ├── config.py            # Settings class (pydantic-settings)
│   ├── models/
│   │   ├── subscription.py  # Subscription, TokenLimit, SubscriptionState models
│   │   └── usage.py         # UsageStats, DailyUsageSummary models
│   ├── services/
│   │   ├── apim_service.py  # Azure APIM integration + mock data
│   │   └── usage_service.py # Token usage tracking + mock data
│   ├── routers/
│   │   ├── subscriptions.py # /api/subscriptions endpoints
│   │   └── usage.py         # /api/usage endpoints
│   ├── templates/           # Jinja2 HTML templates
│   │   ├── base.html        # Base layout with nav
│   │   ├── index.html       # Dashboard page
│   │   ├── subscriptions.html
│   │   ├── subscription_detail.html
│   │   └── partials/        # HTMX partial templates
│   └── static/              # Static assets (if any)
├── tests/
│   ├── test_api.py          # Unit tests (17 tests)
│   └── test_e2e.py          # Playwright E2E tests (19 tests)
├── pyproject.toml           # Project config, dependencies, scripts
├── .env.example             # Environment variable template
└── Dockerfile               # Container deployment
```

## Key Commands

```bash
# Install dependencies
uv sync

# Start the application (uses mock data by default in dev)
uv run start
# Or with explicit mock mode:
USE_MOCK_DATA=true uv run start

# Run all tests (unit + E2E)
uv run test

# Run only unit tests
uv run pytest tests/test_api.py

# Run E2E tests with visible browser
uv run pytest tests/test_e2e.py --headed

# Install Playwright browser (required for E2E tests)
uv run playwright install chromium
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID | Required for Azure mode |
| `AZURE_RESOURCE_GROUP` | Resource group with APIM | Required for Azure mode |
| `APIM_SERVICE_NAME` | API Management service name | Required for Azure mode |
| `USE_MOCK_DATA` | Use mock data instead of Azure | `false` |
| `LOG_WORKSPACE_ID` | Log Analytics workspace ID | Optional |
| `HOST` | Server host | `0.0.0.0` |
| `PORT` | Server port | `8000` |

## Architecture Patterns

### HTMX Integration
- Templates return HTML fragments for HTMX requests
- Use `hx-get`, `hx-post`, `hx-swap` attributes for dynamic updates
- Check `HX-Request` header to differentiate full page vs partial requests
- Partials are in `templates/partials/` directory

### Mock Data Mode
- Set `USE_MOCK_DATA=true` to run without Azure connection
- Mock data is defined in `services/apim_service.py` and `services/usage_service.py`
- Useful for local development and testing

### Pydantic Models
- All data models use Pydantic v2 with `model_config = ConfigDict(...)`
- Field named `usage_date` (not `date`) to avoid Pydantic reserved word collision
- Use `Field(alias="...")` for API response mapping

### API Endpoints

**Subscriptions** (`/api/subscriptions`):
- `GET /` - List all subscriptions (JSON)
- `GET /recent` - Recent subscriptions (HTML partial for dashboard)
- `GET /{id}` - Get subscription detail
- `POST /{id}/toggle` - Enable/disable subscription
- `POST /{id}/limit` - Update token limit

**Usage** (`/api/usage`):
- `GET /` - Get overall usage stats
- `GET /chart-data` - Get chart data for dashboard
- `GET /{subscription_id}` - Get usage for specific subscription
- `GET /{subscription_id}/chart-data` - Chart data for subscription
- `GET /{subscription_id}/daily` - Daily usage breakdown (HTML partial)

**Pages**:
- `GET /` - Dashboard
- `GET /subscriptions` - Subscriptions list
- `GET /subscriptions/{id}` - Subscription detail

## Testing Guidelines

### Unit Tests (`test_api.py`)
- Use FastAPI `TestClient` for API testing
- Tests run with `USE_MOCK_DATA=true` (configured in pyproject.toml)
- Cover models, endpoints, and service methods

### E2E Tests (`test_e2e.py`)
- Use Playwright with pytest-playwright
- Tests marked with `@pytest.mark.e2e`
- Server starts automatically via `live_server` fixture
- Test user flows: navigation, subscriptions, usage charts

## Code Style

- **Formatting**: ruff format (line-length 120)
- **Linting**: ruff with E, F, I, UP rules
- **Templates**: Jinja2 with `.html` extension, VS Code configured for `jinja-html`
- **Type Hints**: Use Python type hints throughout

## Common Tasks

### Adding a New Endpoint
1. Create/update router in `app/routers/`
2. Add Pydantic models in `app/models/` if needed
3. Implement service logic in `app/services/`
4. Add template in `app/templates/` or `templates/partials/`
5. Add unit tests in `tests/test_api.py`
6. Add E2E tests if it affects user flows

### Adding Mock Data
- Subscription mocks: `app/services/apim_service.py` → `_generate_mock_subscriptions()`
- Usage mocks: `app/services/usage_service.py` → `_generate_mock_usage()`

### Modifying Templates
- Base layout: `templates/base.html`
- Use HTMX attributes for dynamic behavior
- Chart.js for visualizations (see `partials/usage_chart.html`)
- Tailwind CSS classes for styling (loaded via CDN)

## Troubleshooting

### "Module not found" errors
```bash
uv sync  # Reinstall dependencies
```

### E2E tests fail with browser error
```bash
uv run playwright install chromium
```

### VS Code shows errors in HTML templates
- Install "Better Jinja" extension (`samuelcolvin.jinjahtml`)
- `.vscode/settings.json` already configured for jinja-html

### Mock data not loading
- Ensure `USE_MOCK_DATA=true` in `.env` or environment
- Check `app/config.py` Settings class

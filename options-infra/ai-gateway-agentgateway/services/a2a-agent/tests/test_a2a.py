from __future__ import annotations

from starlette.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_and_agent_card() -> None:
    assert client.get("/health").text == "ok"

    card = client.get("/.well-known/agent.json").json()
    assert card["protocolVersion"] == "0.3.0"
    assert card["preferredTransport"] == "JSONRPC"
    assert card["capabilities"]["streaming"] is False
    assert card["skills"] == [
        {
            "id": "acknowledge",
            "name": "Acknowledge text",
            "description": "Returns a deterministic acknowledgement of supplied text.",
            "tags": ["sample", "deterministic"],
            "examples": ["hello agent"],
        }
    ]


def test_message_send_is_deterministic() -> None:
    request = {
        "jsonrpc": "2.0",
        "id": "smoke-1",
        "method": "message/send",
        "params": {
            "message": {
                "kind": "message",
                "messageId": "user-1",
                "role": "user",
                "parts": [{"kind": "text", "text": "hello agent"}],
            }
        },
    }

    first = client.post("/", json=request)
    second = client.post("/a2a", json=request)

    assert first.status_code == 200
    assert first.json() == second.json()
    assert first.json()["result"]["parts"][0]["text"] == (
        "Agentgateway sample agent acknowledged: hello agent"
    )


def test_reports_jsonrpc_errors() -> None:
    response = client.post(
        "/",
        json={"jsonrpc": "2.0", "id": 7, "method": "unknown", "params": {}},
    )
    assert response.status_code == 200
    assert response.json()["error"] == {"code": -32601, "message": "Method not found"}


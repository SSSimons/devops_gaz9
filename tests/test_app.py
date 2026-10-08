import asyncio
from unittest.mock import AsyncMock, Mock

import pytest
from fastapi.testclient import TestClient

from app import main

client = TestClient(main.app)


def test_hello_with_correct_header():
    response = client.post("/", headers={"Test": "Hello"})
    assert response.status_code == 200
    assert response.text == "Hello, World!"
    assert response.headers["content-type"].startswith("text/plain")


@pytest.mark.parametrize("headers", [{}, {"Test": "hello"}, {"Test": ""}, {"Other": "Hello"}])
def test_hello_rejects_wrong_header(headers):
    assert client.post("/", headers=headers).status_code == 403


def test_header_name_is_case_insensitive():
    assert client.post("/", headers={"test": "Hello"}).status_code == 200


def test_get_hello_is_not_post():
    assert client.get("/").status_code == 405


@pytest.mark.parametrize("success, status, text", [
    (True, 200, "OK"), (False, 503, "Service Unavailable")
])
def test_health_result(monkeypatch, success, status, text):
    monkeypatch.setattr(main, "ping", AsyncMock(return_value=success))
    response = client.get("/health")
    assert (response.status_code, response.text) == (status, text)


@pytest.mark.parametrize("code, expected", [(0, True), (1, False), (2, False)])
def test_real_ping_command(monkeypatch, code, expected):
    process = Mock()
    process.wait = AsyncMock(return_value=code)
    create = AsyncMock(return_value=process)
    monkeypatch.setattr(main.asyncio, "create_subprocess_exec", create)
    assert asyncio.run(main.ping()) is expected
    assert create.call_args.args == (
        "/usr/bin/ping", "-n", "-c", "1", "-W", "2", "77.88.8.8"
    )


def test_missing_ping_returns_false(monkeypatch):
    monkeypatch.setattr(
        main.asyncio, "create_subprocess_exec", AsyncMock(side_effect=FileNotFoundError)
    )
    assert asyncio.run(main.ping()) is False


def test_ping_timeout_kills_and_reaps_child(monkeypatch):
    process = Mock(returncode=None)
    process.wait = AsyncMock(side_effect=[asyncio.TimeoutError, 0])
    monkeypatch.setattr(main.asyncio, "create_subprocess_exec", AsyncMock(return_value=process))
    assert asyncio.run(main.ping()) is False
    process.kill.assert_called_once()
    assert process.wait.await_count == 2


def test_ping_cancellation_kills_child_and_propagates(monkeypatch):
    process = Mock(returncode=None)
    process.wait = AsyncMock(side_effect=[asyncio.CancelledError, 0])
    monkeypatch.setattr(main.asyncio, "create_subprocess_exec", AsyncMock(return_value=process))
    with pytest.raises(asyncio.CancelledError):
        asyncio.run(main.ping())
    process.kill.assert_called_once()


def test_metrics_are_exported():
    client.post("/", headers={"Test": "Hello"})
    response = client.get("/metrics")
    assert response.status_code == 200
    assert 'app_http_requests_total{method="POST",path="/",status="200"}' in response.text
    assert "app_ping_success" in response.text


def test_unknown_paths_have_bounded_metric_labels():
    client.get("/random-123")
    client.get("/random-456")
    metrics = client.get("/metrics").text
    assert 'path="other"' in metrics
    assert "random-123" not in metrics
    assert "random-456" not in metrics


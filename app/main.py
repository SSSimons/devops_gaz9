"""ТЗ: проверка заголовка, ping и метрики."""
import asyncio
import logging
import os
import time

from fastapi import FastAPI, Request
from fastapi.responses import PlainTextResponse, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

PING_ADDRESS = "77.88.8.8"

logger = logging.getLogger(__name__)
app = FastAPI(title="Service Lab", docs_url=None, redoc_url=None, openapi_url=None)

registry = CollectorRegistry()
requests_total = Counter(
    "app_http_requests_total",
    "Количество HTTP-запросов",
    ["method", "path", "status"],
    registry=registry,
)
request_duration = Histogram(
    "app_http_request_duration_seconds",
    "Время обработки HTTP-запроса",
    ["method", "path"],
    registry=registry,
)
ping_success = Gauge(
    "app_ping_success",
    "Результат ping: 1 - ответ есть, 0 - ответа нет, -1 - ещё не проверяли",
    registry=registry,
)
ping_success.set(-1)


@app.middleware("http")
async def collect_metrics(request: Request, call_next):
    # Запросы к самим метрикам не считаем.
    if request.url.path == "/metrics":
        return await call_next(request)

    path = request.url.path
    method = request.method

    # Для неизвестных адресов одна метка, чтобы не плодить метрики.
    if path not in {"/", "/health"}:
        path = "other"
    if method not in {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"}:
        method = "other"

    start_time = time.monotonic()
    status_code = 500

    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        requests_total.labels(method, path, str(status_code)).inc()
        request_duration.labels(method, path).observe(time.monotonic() - start_time)


async def ping() -> bool:
    """Проверяем ответ от 77.88.8.8. На весь процесс даём 3 секунды."""
    try:
        process = await asyncio.create_subprocess_exec(
            "/usr/bin/ping", "-n", "-c", "1", "-W", "2", PING_ADDRESS,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except OSError:
        logger.exception("Не удалось запустить ping")
        return False

    try:
        return_code = await asyncio.wait_for(process.wait(), timeout=3)
        return return_code == 0
    except asyncio.TimeoutError:
        return False
    finally:
        # При таймауте или отмене запроса завершаем оставшийся процесс.
        if process.returncode is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            await process.wait()


@app.post("/", response_class=PlainTextResponse)
async def hello(request: Request):
    if request.headers.get("Test") != "Hello":
        return PlainTextResponse("Forbidden", status_code=403)

    return PlainTextResponse("Hello, World!")


@app.get("/health", response_class=PlainTextResponse)
async def health():
    success = await ping()
    ping_success.set(int(success))

    if success:
        return PlainTextResponse("OK", status_code=200)

    return PlainTextResponse("Service Unavailable", status_code=503)


@app.get("/metrics", include_in_schema=False)
async def metrics():
    return Response(
        generate_latest(registry),
        headers={"Content-Type": CONTENT_TYPE_LATEST},
    )


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port)

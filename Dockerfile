# ---- Stage 1: builder ----
# 의존성 설치에 필요한 도구(uv)는 이 단계에만 존재합니다.
# 베이스 이미지는 digest(@sha256:...)로 고정: 태그는 같아도 내용이 바뀔 수 있으므로.
# 갱신은 Dependabot이 PR로 제안합니다.
FROM python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS builder
COPY --from=ghcr.io/astral-sh/uv:0.6.14@sha256:3362a526af7eca2fcd8604e6a07e873fb6e4286d8837cb753503558ce1213664 /uv /bin/uv

WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy

# 1) lock 파일만 먼저 복사 → 코드만 바뀌면 이 레이어는 캐시 재사용
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# 2) 그다음 소스 복사
COPY app ./app

# ---- Stage 2: runtime ----
# 최종 이미지에는 가상환경과 소스만 들어갑니다 (uv, 빌드 캐시 없음).
FROM python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90
WORKDIR /app

# 실행에 필요 없는 pip 제거 (pip이 내장한 라이브러리의 취약점까지 함께 제거됨)
RUN python -m pip uninstall -y pip \
 && useradd --create-home --uid 10001 appuser
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/app /app/app

ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1
USER appuser
EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# 01. 예제 앱과 로컬 품질 게이트

## 왜 이 단계가 먼저인가?
CI 서버는 **사람이 정해 둔 검사를 대신 실행해 줄 뿐**입니다. 자동화된 테스트와 lint가 없으면
CI는 "빌드가 되긴 하네"밖에 알려 주지 못합니다. 그래서 CI를 붙이기 전에 로컬에서 한 명령으로
돌릴 수 있는 검사부터 만듭니다.

> 원칙: **CI에서 돌리는 명령 = 로컬에서 돌리는 명령.** 그래야 CI 실패를 로컬에서 그대로 재현할 수 있습니다.

## 구성
| 파일 | 역할 |
|---|---|
| `app/main.py` | FastAPI 앱 (`/health`, `/items`) |
| `tests/test_main.py` | pytest 테스트 4개 |
| `pyproject.toml` | 의존성, ruff/pytest 설정 |
| `uv.lock` | 의존성 버전 고정 → 어디서 설치해도 같은 버전 (재현성) |

## 로컬에서 실행
```bash
uv sync                    # 의존성 설치 (.venv 생성)
uv run ruff check .        # lint: 버그 가능성, import 정렬 등
uv run ruff format --check .  # 포맷 검사 (고치려면 --check 빼기)
uv run pytest              # 테스트
uv run uvicorn app.main:app --reload   # 앱 실행 → http://localhost:8000/docs
```

## 품질 게이트의 종류 (빠른 것 → 느린 것)
1. **포맷/lint**: 몇 초. 스타일과 단순 실수
2. **Unit test**: 몇 초~몇 분. 함수 단위 동작
3. **Integration test**: DB나 외부 서비스와 함께
4. **E2E test**: 배포된 환경에서 사용자 흐름

## 해 볼 것
- `app/main.py`에서 `/health`의 `"ok"`를 `"OK"`로 바꾸고 `uv run pytest` → 실패 확인 후 되돌리기
- `import os`를 추가하고 `uv run ruff check .` → F401(unused import) 확인

## 확인 질문
1. `uv.lock` 같은 lock 파일이 CI에서 왜 중요한가요?
2. lock 파일이 없으면 "어제는 통과했는데 오늘은 실패"하는 일이 어떻게 생길 수 있나요?
3. 테스트에서 `clear_items` fixture가 없으면 어떤 문제가 생길까요? (힌트: 테스트 순서)

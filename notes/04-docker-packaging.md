# 04. 패키징: Docker 이미지 (로컬 파트)

> 2~3단계(GitHub Actions)는 GitHub 저장소를 연결한 뒤 진행합니다. 이 노트는 Docker 이미지를 로컬에서 만들고 돌려 보는 부분입니다.
> GHCR에 push하는 부분은 2단계 이후 Actions에서 자동화합니다.

## 왜 컨테이너 이미지가 산출물인가?
- 앱과 런타임(Python 버전, 의존성, OS 라이브러리)을 **하나로 묶은 불변 산출물**입니다.
- dev, stage, prod에 **같은 이미지**를 배포하므로 "빌드는 한 번, 배포는 여러 번"이 가능합니다 (00 노트 참고).
- Kubernetes는 이미지를 받아서 실행하는 것이 기본 단위입니다 (6~7단계).

## Dockerfile 포인트 ([../Dockerfile](../Dockerfile))
| 기법 | 이유 |
|---|---|
| **멀티스테이지** (builder → runtime) | 빌드 도구(uv)를 최종 이미지에서 빼서 크기와 공격 면적을 줄임 |
| **lock 파일 먼저 COPY → 의존성 설치 → 소스 COPY** | 레이어 캐시. 코드만 바뀌면 의존성 설치 레이어를 재사용해 빌드가 빨라짐 |
| `uv sync --frozen` | lock 파일과 다르면 실패 → 재현 가능한 빌드 |
| `--no-dev` | pytest, ruff 같은 개발 도구는 운영 이미지에서 제외 |
| 베이스 이미지와 uv 버전 고정 | 재현성. `latest`는 시간이 지나면 다른 이미지가 됨 |
| **non-root 사용자** (`appuser`) | 컨테이너가 탈취되더라도 피해를 줄임 (5단계 보안과 연결) |
| `.dockerignore` | `.venv`, `.git`, `tests` 등을 빌드 컨텍스트에서 제외 → 빠르고 깨끗한 빌드 |

## 실행해 보기
```bash
docker build -t cicd-study:local .
docker run --rm -p 18080:8000 cicd-study:local
curl localhost:18080/health          # {"status":"ok"}
```
검증 결과: `/health`와 `/items`가 정상 응답, `whoami` = `appuser`, 이미지 크기 약 160MB.

## 태그 전략 (Actions에서 적용 예정)
| 태그 | 용도 |
|---|---|
| `sha-<git SHA>` | **배포에 쓰는 태그.** 불변이며, 어떤 커밋인지 바로 추적 가능 |
| `v1.2.3` (semver) | 사람이 읽기 위한 릴리스 버전 |
| `latest` | 편의용. **배포에는 쓰지 않음** (무엇이 들어 있는지 시점마다 다름) |

## 해 볼 것
- `app/main.py`만 수정하고 다시 `docker build` → 로그에서 의존성 설치 단계가 `CACHED`로 나오는지 확인
- `pyproject.toml`에 의존성을 추가하고 다시 빌드 → 캐시가 깨지는 지점 확인
- `docker history cicd-study:local`로 레이어별 크기 보기

## 확인 질문
1. `COPY . .`을 맨 위에 한 번만 쓰면 빌드 캐시에 어떤 문제가 생기나요?
2. 멀티스테이지를 쓰지 않으면 최종 이미지에 무엇이 더 들어가나요?
3. `latest` 태그로 배포했다가 롤백해야 할 때 어떤 어려움이 있나요?
4. 컨테이너를 root로 실행하면 왜 위험한가요?

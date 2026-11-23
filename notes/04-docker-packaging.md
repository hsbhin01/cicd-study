# 04. 패키징: Docker 이미지

> 앞부분은 로컬에서 이미지를 만들고 돌려 본 내용, 뒷부분("GHCR에 자동 push" 이후)은 GitHub Actions로 자동화한 내용입니다.

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

## 실행해 보기 (로컬)
```bash
docker build -t cicd-study:local .   # -t: 이미지 이름(저장소:태그). Dockerfile이 아니라 빌드 명령에서 정함
docker run --rm -p 18080:8000 cicd-study:local
curl localhost:18080/health          # {"status":"ok"}
```
검증 결과: `/health`와 `/items`가 정상 응답, `whoami` = `appuser`, 이미지 크기 약 160MB.

### 이미지 이름의 구조
```
[레지스트리/][네임스페이스/]저장소:태그
cicd-study:local                         = docker.io/library/cicd-study:local (생략된 기본값)
ghcr.io/hsbhin01/cicd-study:sha-c727f66  = GHCR / 계정 / 저장소 : 태그
```

## GHCR에 자동 push (CD 워크플로우)
[../.github/workflows/cd.yml](../.github/workflows/cd.yml)

### 흐름
```
PR 머지 → main에 push
  ├─ CI (ci.yml): lint, test, coverage     ← 동시에 실행
  └─ CD (cd.yml): checkout → QEMU → Buildx → GHCR 로그인 → 태그 계산 → 빌드 & push
```
- **PR에서는 CD가 실행되지 않습니다** (`on: push: branches: [main]`). PR에서 CI만 돌고, 머지된 뒤에 이미지를 만듭니다.
- main에 들어온 코드는 branch protection 때문에 이미 PR에서 CI를 통과한 상태입니다.
- `workflow_dispatch`: Actions 화면에서 수동 실행 버튼.

### 핵심 설정
| 설정 | 의미 |
|---|---|
| `permissions: packages: write` | 워크플로우 토큰에 GHCR push 권한 부여. 나머지는 읽기만 |
| `docker/login-action` + `secrets.GITHUB_TOKEN` | 별도 비밀번호 없이, 워크플로우마다 자동 발급되는 임시 토큰으로 로그인 |
| `docker/metadata-action` | 태그와 라벨 계산 (아래) |
| `docker/build-push-action` | 빌드 + push. `cache-from/to: type=gha`로 레이어 캐시 재사용 |

## 태그 전략 (적용됨)
| 태그 | 용도 | 예 |
|---|---|---|
| `sha-<7자리 SHA>` | **배포에 쓰는 태그.** 불변이며, 어떤 커밋인지 바로 추적 가능 | `sha-c727f66` |
| `latest` | 편의용. **배포에는 쓰지 않음** (무엇이 들어 있는지 시점마다 다름) | 가장 최근 main |
| `v1.2.3` (semver) | 사람이 읽기 위한 릴리스 버전. git 태그를 붙일 때 추가 (미적용) | |

SHA는 **머지 커밋**의 SHA입니다. PR #10의 머지 커밋 `c727f66` → `sha-c727f66`.

### 이미지 라벨: 이미지만 보고 출처 추적
metadata-action이 OCI 표준 라벨을 자동으로 붙입니다.
```bash
docker image inspect ghcr.io/hsbhin01/cicd-study:sha-0608abe \
  --format '{{index .Config.Labels "org.opencontainers.image.source"}} {{index .Config.Labels "org.opencontainers.image.revision"}}'
# https://github.com/hsbhin01/cicd-study 0608abecfaf4f057d96ea1eb7f2bab4261535222
```
- `source`: 어느 저장소에서 왔나 → GHCR 패키지가 저장소와 자동 연결됨
- `revision`: 어느 커밋에서 빌드됐나

### 공개 여부
공개 저장소에서 push한 패키지라 **로그인 없이 pull**됩니다. 6단계에서 kind가 이미지를 받을 때 인증 설정이 필요 없습니다.
(비공개라면 Kubernetes에 `imagePullSecret`을 설정해야 합니다.)

## 문제와 해결: CPU 아키텍처
### 증상
```
$ docker pull ghcr.io/hsbhin01/cicd-study:sha-0608abe     # Apple Silicon 맥에서
no matching manifest for linux/arm64/v8 in the manifest list entries
```

### 원인
| | CPU | 결과 |
|---|---|---|
| GitHub runner (`ubuntu-latest`) | **amd64** (x86_64) | `docker build`는 빌드하는 컴퓨터의 CPU용 이미지를 만듦 → amd64 이미지만 생김 |
| Apple Silicon 맥, kind 노드 | **arm64** (aarch64) | 맞는 이미지가 없음 |

- Python 코드는 CPU와 무관하지만, 이미지 안의 Python 실행 파일과 OS 라이브러리는 CPU별 기계어 → 이미지가 CPU에 묶임
- runner의 CPU는 로그에도 보였음: 캐시 키 `setup-uv-1-x86_64-unknown-linux-gnu-...`
- 로컬에서 직접 빌드한 `cicd-study:local`은 맥(arm64)에서 빌드해서 문제가 없었음
- 임시 확인: `--platform linux/amd64`로 에뮬레이션 실행하면 동작은 함 (느림)

### 해결: 멀티 아키텍처 이미지 (PR #10)
```yaml
- uses: docker/setup-qemu-action@v3        # amd64 runner에서 arm64 에뮬레이션
...
  platforms: linux/amd64,linux/arm64       # 두 아키텍처를 한 태그로
```
결과: 태그 하나가 **이미지 목록(index)**을 가리킴
```
$ docker buildx imagetools inspect ghcr.io/hsbhin01/cicd-study:sha-c727f66
MediaType: application/vnd.oci.image.index.v1+json
  Platform:  linux/amd64
  Platform:  linux/arm64
  Platform:  unknown/unknown   ← 빌드 출처 증명서(provenance attestation) × 2
```
`docker pull`하는 컴퓨터가 자기 CPU에 맞는 것을 자동으로 골라 받음 → 맥에서 옵션 없이 pull 시 `arch=arm64`, 정상 실행.

### 대가와 대안
| | 빌드와 push | CD 전체 |
|---|---|---|
| amd64만 | 24초 | 약 45초 |
| amd64 + arm64 (QEMU) | 40초 | 63초 |

- 에뮬레이션이라 arm64 빌드가 느림. 작은 프로젝트라 허용.
- 빌드가 수 분 이상 걸리면: arm64 runner(`ubuntu-24.04-arm`)에서 따로 빌드한 뒤 합치는 방식 검토.

## 해 볼 것
- `app/main.py`만 수정하고 다시 `docker build` → 로그에서 의존성 설치 단계가 `CACHED`로 나오는지 확인
- `pyproject.toml`에 의존성을 추가하고 다시 빌드 → 캐시가 깨지는 지점 확인
- `docker history cicd-study:local`로 레이어별 크기 보기
- `docker buildx imagetools inspect ghcr.io/hsbhin01/cicd-study:latest`로 아키텍처 목록 보기
- Actions의 CD 실행 화면 Summary에서 push된 태그 확인

## 확인 질문
1. `COPY . .`을 맨 위에 한 번만 쓰면 빌드 캐시에 어떤 문제가 생기나요?
2. 멀티스테이지를 쓰지 않으면 최종 이미지에 무엇이 더 들어가나요?
3. `latest` 태그로 배포했다가 롤백해야 할 때 어떤 어려움이 있나요?
4. 컨테이너를 root로 실행하면 왜 위험한가요?
5. CD를 `pull_request`에서도 실행해 이미지를 push하면 어떤 문제가 생길 수 있나요?
6. 이미지 태그에 PR 브랜치의 커밋 SHA가 아니라 **머지 커밋**의 SHA가 붙는 이유는 무엇인가요?
7. amd64 이미지만 있는 상태에서 Apple Silicon 맥이 그 이미지를 실행하려면 어떻게 해야 하고, 그 대가는 무엇인가요?

# 05. 시크릿과 보안 (공급망 보안)

## 한 줄 요약
파이프라인이 **가져다 쓰는 모든 것**(베이스 이미지, 패키지, Action)과 **파이프라인이 가진 권한**이 공격 경로가 될 수 있습니다.
"무엇이 들어 있는지 알고(스캔), 바뀌지 않게 고정하고(pin), 고정한 것을 안전하게 갱신하고(Dependabot), 권한은 최소로" 가 핵심입니다.

```
           ┌──────────── 우리가 가져다 쓰는 것 ────────────┐
           │ 베이스 이미지   Python 패키지   GitHub Actions │
           └──────┬──────────────┬───────────────┬────────┘
     digest 고정 ─┘   uv.lock ───┘   SHA 고정 ────┘      ← 1) 고정 (바뀌지 않게)
                     Dependabot이 갱신 PR 생성            ← 2) 안전한 갱신
                     PR에서 CI + Trivy 스캔               ← 3) 검증
                     최소 권한 토큰으로 빌드/배포          ← 4) 피해 범위 제한
```

## 1. 이미지 취약점 스캔 (Trivy)

### 어디서, 어떻게
CI에 `image-scan` job 추가 ([../.github/workflows/ci.yml](../.github/workflows/ci.yml)). **PR 단계**에서 실행해 머지 전에 결과를 봅니다.
```
이미지 빌드(push 안 함, load: true) → Trivy 리포트(HIGH, CRITICAL) → Trivy 관문(CRITICAL이면 실패)
```
| 설정 | 의미 |
|---|---|
| `ignore-unfixed: true` | 고친 버전이 아직 없는 취약점은 제외. 지금 할 수 있는 조치가 없으므로 |
| 리포트 `exit-code: 0` | HIGH와 CRITICAL을 보여 주기만 함 |
| 관문 `severity: CRITICAL`, `exit-code: 1` | 고칠 수 있는 CRITICAL이 있으면 job 실패 |

- `image-scan`은 아직 **필수 체크가 아닙니다**. 실패해도 머지는 가능합니다. 팀 합의 후 필수로 올리는 것이 일반적입니다.
- 로컬(회사 네트워크)에서는 Trivy가 취약점 DB를 받지 못했습니다 (인증서 검증 실패, 보안 프록시 추정). 인증서 검증을 끄는 우회는 하지 않고 runner에서 실행했습니다.

### 스캔 결과와 조치
| 발견 | 위치 | 원인 | 조치 | 결과 |
|---|---|---|---|---|
| HIGH 5건: msgpack 2, urllib3 2, setuptools 1 | `pip/_vendor` | 베이스 이미지의 **pip이 내장한** 라이브러리 | 실행 이미지에서 pip 제거 | **해결** |
| HIGH 1건: zlib1g | Debian 패키지 | 베이스 이미지 `python:3.13-slim` | 베이스 이미지 갱신 대기 (Dependabot) | 남음 |

**교훈 1: 쓰지 않는 것은 빼라.** 앱은 uv로 설치하므로 실행 시 pip이 필요 없었습니다. 도구 하나를 빼서 취약점 5건이 사라졌습니다.
```dockerfile
RUN python -m pip uninstall -y pip \
 && useradd --create-home --uid 10001 appuser
```
**교훈 2: 취약점의 주인을 찾아라.** "msgpack 취약점"이라고 앱 의존성을 뒤질 게 아니라, 이미지 안 어디에 있는지부터 확인합니다.
```bash
docker run --rm --entrypoint sh <image> -c 'cat /usr/local/lib/python3.13/site-packages/pip/_vendor/vendor.txt'
```

## 2. 고정 (pinning)

### 왜: 태그는 움직인다
`actions/checkout@v4`, `python:3.13-slim`은 **이름표**입니다. 작성자(또는 계정을 탈취한 공격자)가 다른 내용으로 옮길 수 있습니다.
실제로 인기 Action의 태그가 악성 커밋으로 옮겨져, 그 Action을 쓰던 수많은 저장소의 시크릿이 유출된 사고가 있었습니다.
SHA/digest는 **내용 자체의 해시**라서, 내용이 바뀌면 값이 바뀝니다. 같은 값이면 같은 내용입니다.

| 대상 | 이전 | 이후 |
|---|---|---|
| GitHub Actions | `actions/checkout@v4` | `actions/checkout@3d3c42e5...  # v7.0.1` |
| 베이스 이미지 | `python:3.13-slim` | `python:3.13-slim@sha256:e48f59cd...` |
| uv 이미지 | `ghcr.io/astral-sh/uv:0.6.14` | `ghcr.io/astral-sh/uv:0.6.14@sha256:3362a526...` |
| Python 패키지 | (이미) `uv.lock` | 그대로 |

- 뒤의 `# v7.0.1` 주석은 사람이 읽는 용도이자, Dependabot이 버전을 판단하는 단서입니다.
- 태그와 digest를 함께 쓰면(`3.13-slim@sha256:...`) digest가 우선합니다. 태그는 사람이 읽는 용도가 됩니다.
- Docker 이미지 태그에 `latest` 대신 git SHA를 쓰는 것(04 노트)과 같은 원리입니다.

## 3. Dependabot: 고정한 것을 안전하게 갱신

### 고정의 대가
고정하면 보안 패치도 자동으로 들어오지 않습니다. 그래서 **갱신을 자동으로 제안**하는 도구가 짝으로 필요합니다.

### 설정 ([../.github/dependabot.yml](../.github/dependabot.yml))
| 생태계 | 감시 대상 | 설정 |
|---|---|---|
| `uv` | `pyproject.toml`, `uv.lock` | 마이너/패치는 PR 하나로 묶음 (group) |
| `github-actions` | 워크플로우의 `uses:` SHA와 주석 | 마이너/패치는 묶음 |
| `docker` | Dockerfile의 `FROM` | `python` 버전 업은 무시, **3.13-slim의 digest 갱신만** |

### 실제로 일어난 일
설정을 main에 머지하자마자 Dependabot이 PR 7개를 만들었습니다.
| PR | 내용 | CI | 처리 | 이유 |
|---|---|---|---|---|
| #20 | ruff 0.17.5 → 0.17.6 (python 그룹) | ✅ | **머지** | 패치, 테스트 통과 |
| #15~#19 | docker 계열 4개, setup-uv **메이저** 업데이트 | ✅ | 하나로 묶어 #21로 **직접 처리** → Dependabot이 스스로 닫음 | 아래 참고 |
| #14 | python 3.13-slim → **3.15-slim** | ✅ | **닫음** | 아래 참고 |

**판단 1: CI 통과 ≠ 안전**
- `login-action`, `metadata-action`, `setup-qemu-action`은 **CD에서만** 쓰입니다. PR의 CI는 이들을 실행하지 않으므로 CI 통과는 아무것도 검증하지 않았습니다.
- 메이저 업데이트는 릴리스 노트의 breaking changes를 확인했습니다. 대부분 "Node 24 런타임" (GitHub 제공 runner는 영향 없음)과 우리가 쓰지 않는 입력값 제거였습니다.
- setup-uv는 v10에서 캐시 기본값이 바뀌었지만, PR #6에서 **설정을 명시해 둔 덕분에** 영향이 없었습니다.
- 머지 후 CD 실행이 성공하고 멀티 아키텍처 이미지가 push된 것까지 확인했습니다.

**판단 2: 묶어서 처리**
- "최신 main 반영 필수" 규칙 때문에 Action PR을 하나씩 머지하면 나머지를 매번 다시 갱신하고 CI를 다시 기다려야 합니다.
- 한 PR(#21)에서 8개 Action을 모두 올렸고, Dependabot은 main이 이미 최신인 것을 보고 #15~#19를 자동으로 닫았습니다.
- 생태계마다 열린 PR은 기본 5개로 제한돼서, checkout과 qemu는 PR이 아직 오지 않은 상태였습니다. #21에 함께 포함했습니다.

**판단 3: Python 버전 업은 자동으로 받지 않는다**
- CI 테스트는 setup-uv로 받은 **Python 3.13**에서 돕니다. #14는 이미지 빌드와 스캔만 통과했고, 앱이 3.15에서 실행된 적은 없습니다.
- 받으면 개발(3.13)과 운영(3.15)의 Python이 어긋납니다. 게다가 3.15-slim 스캔에서도 zlib 취약점은 그대로였습니다.
- Python 버전 업은 CI의 `python-version`, Dockerfile, 로컬 환경을 **함께** 바꾸는 별도 작업으로 해야 합니다.

## 4. 권한 최소화 (점검)
| 워크플로우 | 권한 | 이유 |
|---|---|---|
| CI | `contents: read` | 코드 읽기만. PR 코드가 무엇을 하든 저장소에 쓸 수 없음 |
| CD | `contents: read`, `packages: write` | 이미지 push에 필요한 것만 추가 |

- 시크릿을 따로 등록하지 않았습니다. GHCR 로그인은 워크플로우마다 자동 발급되고 실행이 끝나면 만료되는 `GITHUB_TOKEN`을 씁니다. **오래 사는 비밀번호를 저장하지 않는 것**이 가장 좋은 시크릿 관리입니다.
- Dependabot이 만든 PR의 워크플로우는 읽기 전용 토큰을 받고, 저장소 시크릿에 접근할 수 없습니다. 외부 fork에서 온 PR도 마찬가지입니다.
- 추가로 할 수 있는 것 (미적용): checkout에 `persist-credentials: false`를 주면 토큰이 작업 폴더의 git 설정에 남지 않습니다. 이후 step이 git push를 하지 않는 워크플로우라면 켜는 것이 좋습니다.

## 5. 기타 확인
- **`paths-ignore` 동작 확인:** 이 노트 PR은 문서만 바꾸므로, 머지 후 CI만 돌고 CD는 건너뛰어야 합니다.
- **CI 이벤트 누락:** 5단계 중에도 PR #11에서 한 번 더 발생했고, PR을 닫았다 다시 열어 해결했습니다 (03 노트 참고).

## 확인 질문
1. `actions/checkout@v4`를 그대로 쓰면, Action 작성자의 계정이 탈취됐을 때 어떤 일이 생길 수 있나요? SHA 고정은 이를 어떻게 막나요?
2. 고정(pinning)만 하고 Dependabot을 쓰지 않으면 어떤 문제가 생기나요?
3. Trivy에서 `ignore-unfixed: true`를 쓰는 이유는 무엇인가요? 이 옵션의 위험은 무엇일까요?
4. Dependabot PR의 CI가 통과했는데도 바로 머지하면 안 되는 경우를 이번 실습에서 찾아 설명해 보세요.
5. 이미지에서 pip을 제거하면 취약점이 줄어드는 이유는 무엇인가요? 같은 원리로 더 뺄 수 있는 것이 있을까요?
6. GHCR 로그인에 개인 토큰(PAT)을 시크릿으로 저장해 쓰는 것과 `GITHUB_TOKEN`을 쓰는 것은 무엇이 다른가요?

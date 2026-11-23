# 02. GitHub Actions 기초 (CI)

## 한 줄 요약
코드가 바뀔 때마다 **GitHub이 빌려주는 깨끗한 컴퓨터**에서, 로컬과 똑같은 lint와 test를 자동으로 실행합니다.
PR 단계에서 실행되므로 **main에 머지되기 전에** 문제를 잡습니다.

## 용어
| 용어 | 뜻 | 이 저장소에서 |
|---|---|---|
| **Workflow** | 자동화 하나. `.github/workflows/*.yml` 파일 1개 | [ci.yml](../.github/workflows/ci.yml) (`name: CI`) |
| **Event (트리거)** | 워크플로우를 시작시키는 사건 | `push`(main), `pull_request`(main 대상) |
| **Job** | 한 runner에서 실행되는 작업 단위. 여러 job은 기본적으로 병렬 | `lint-and-test` |
| **Runner** | job을 실행하는 컴퓨터. 매번 새로 만들어지고 끝나면 버려짐 | `ubuntu-latest` |
| **Step** | job 안에서 순서대로 실행되는 단계. 하나라도 실패하면 이후 step은 건너뜀 | Checkout → … → Test |
| **Action** | 재사용 가능한 step 묶음. `uses:`로 호출하고 `with:`로 입력을 넘김 | `actions/checkout@v4`, `astral-sh/setup-uv@v5` |
| **Run** | 워크플로우가 한 번 실행된 기록 (로그, 결과) | Actions 탭의 각 항목 |

```
Event(push / pull_request)
  └─ Workflow (ci.yml)
       └─ Job: lint-and-test  ── runs-on: ubuntu-latest (새 VM)
            ├─ Step: Checkout            (uses: Action)
            ├─ Step: Set up uv           (uses: Action + with)
            ├─ Step: Install dependencies (run: 셸 명령)
            ├─ Step: Lint
            ├─ Step: Format check
            └─ Step: Test
```

## 두 트리거의 차이
| 트리거 | 언제 | 무엇을 검사하나 | 목적 |
|---|---|---|---|
| `pull_request` | PR을 열거나, PR에 커밋을 추가할 때 | **main에 머지했다고 가정한 결과** (`refs/pull/N/merge`) | 머지 **전에** 차단 |
| `push` (main) | 머지 등으로 main이 바뀔 때 | main의 실제 최신 커밋 | main이 정상인지 최종 확인 |

- PR의 워크플로우는 main이 아니라 **PR 코드 안의** ci.yml을 씁니다. 그래서 ci.yml을 처음 추가하는 PR에서도 실행됩니다.
- 실제 기록: PR #1에서 `pull_request`로 1번 → 머지 후 `push`로 1번, 둘 다 성공.

## 실습 기록: 깨진 PR (PR #2)
1. `/health` 응답을 `"ok"` → `"OK"`로 바꿔 PR을 올림
2. CI 실패. step별 결과:
   ```
   success  Checkout / Set up uv / Install dependencies / Lint / Format check
   failure  Test
   ```
3. 로그에서 원인 찾기:
   ```
   FAILED tests/test_main.py::test_health
   E  AssertionError: assert {'status': 'OK'} == {'status': 'ok'}
   1 failed, 3 passed
   ```
4. 같은 PR에 수정 커밋을 push → CI가 **자동으로 다시 실행**되어 통과
5. 머지하지 않고 PR을 닫음

### 발견: 실패해도 머지 버튼은 눌린다
CI가 실패한 상태의 PR #2는 `mergeable=MERGEABLE`, `mergeStateStatus=UNSTABLE`이었습니다.
CI는 **알려 줄 뿐 막지는 않습니다.** 실제로 막으려면 **branch protection**에서 이 체크를 필수(required)로 지정해야 합니다 → 3단계.

## 로그 읽는 순서
1. PR 화면 또는 Actions 탭에서 빨간 X가 붙은 **job**을 엽니다.
2. 빨간 X가 붙은 **첫 번째 step**을 펼칩니다. 그 뒤 step은 건너뛴 것이라 볼 필요가 없습니다.
3. 아래에서부터 위로 읽습니다. pytest라면 `FAILED` 줄과 `E` 로 시작하는 줄이 핵심입니다.
4. 로컬에서 같은 명령(`uv run pytest`)으로 재현합니다. CI 명령 = 로컬 명령이기 때문에 가능합니다.

CLI로 보려면:
```bash
gh run list --limit 5                 # 최근 실행 목록
gh run view <run-id> --log-failed     # 실패한 step 로그만
gh pr checks <PR번호> --watch         # PR 체크 결과를 끝날 때까지 지켜보기
```

## 설계 포인트 (ci.yml)
- `permissions: contents: read`: 워크플로우가 받는 토큰 권한을 읽기로 제한 (5단계 보안과 연결)
- `uv sync --frozen`: lock 파일과 다르면 실패 → "어제는 됐는데 오늘은 실패" 방지
- uv 버전과 Python 버전 고정: 로컬과 같은 환경
- 버전 문자열에 따옴표: YAML에서 `3.10`은 숫자 `3.1`로 해석됨

## 확인 질문
1. `Checkout` step을 지우면 어느 step에서, 어떤 에러로 실패할까요?
2. PR #2에서 `Lint`가 실패했다면 `Test` step은 실행됐을까요? 그게 좋은 설계일까요, 나쁜 설계일까요?
3. `pull_request` 트리거만 있고 `push` 트리거가 없다면 어떤 상황을 놓칠 수 있나요? (힌트: PR 두 개가 각각은 통과했는데 둘 다 머지되면)
4. CI가 실패한 PR이 머지되는 것을 막으려면 무엇이 필요한가요?

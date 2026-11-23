# 03. CI 심화: branch protection, 캐시, 커버리지

> matrix(여러 Python 버전 동시 테스트)는 건너뛰었습니다. 맨 아래 "건너뛴 것"에 핵심만 적어 둡니다.

## 1. Branch protection (Ruleset)

### 왜 필요한가
CI는 **알려 줄 뿐 막지는 않습니다.** 02 노트의 PR #2는 CI가 실패했는데도 머지할 수 있었습니다 (`UNSTABLE`).
또 누구나 `git merge` 후 `git push origin main`으로 PR과 CI를 건너뛸 수 있었습니다.

### 설정 (`protect-main`, Settings → Rules → Rulesets)
| 규칙 | 효과 |
|---|---|
| Target: 기본 브랜치 | main에 적용 |
| Bypass list: 없음 | 관리자도 예외 없음 |
| Restrict deletions | main 삭제 금지 |
| Block force pushes | 히스토리 덮어쓰기 금지 |
| Require a pull request (승인 0명) | main 직접 push 금지. 혼자 쓰는 저장소라 승인은 0 |
| Require status checks: `lint-and-test` | CI 통과해야 머지 가능 |
| Require branches to be up to date | 최신 main을 반영한 상태에서 통과해야 함 |

함께 켠 설정: Settings → General → **Automatically delete head branches** (머지 후 원격 브랜치 자동 삭제)

### 처음 설정할 때 놓친 것
화면에서 만든 직후 **Target branches**와 **필수 체크 목록**이 비어 있었습니다. 규칙은 Active였지만 어느 브랜치에도, 어떤 체크에도 적용되지 않는 상태였습니다.
→ 규칙을 만든 뒤에는 **실제로 적용됐는지 확인**합니다.
```bash
gh api repos/<owner>/<repo>/rules/branches/main --jq '[.[].type]'
# ["deletion","non_fast_forward","pull_request","required_status_checks"]
```

### 실습 결과
**main 직접 push → 거부**
```
remote: - Changes must be made through a pull request.
remote: - Required status check "lint-and-test" is expected.
 ! [remote rejected] main -> main (push declined due to repository rule violations)
```

**PR의 머지 상태 변화**
| 상태 | 뜻 | 본 곳 |
|---|---|---|
| `UNSTABLE` | 체크 실패, 하지만 필수가 아니라 머지 가능 | PR #2 (보호 전) |
| `BLOCKED` | 필수 조건 미충족, 머지 불가 | PR #4, #5 (CI 실패) |
| `CLEAN` | 모든 조건 충족, 머지 가능 | PR #5 (수정 후), #6, #7 |

### 바뀐 작업 방식
```
브랜치 → 커밋 → push → PR → CI 통과 → 머지 (GitHub 버튼 / gh pr merge)
→ 로컬: git switch main && git pull && git fetch --prune
```

### 주의: job 이름과 필수 체크
필수 체크는 **job 이름**(`lint-and-test`)으로 연결됩니다. job 이름을 바꾸거나 matrix로 이름이 `lint-and-test (3.13)`처럼 바뀌면,
필수 체크가 영원히 "대기 중"이 되어 모든 PR이 막힙니다. job 이름을 바꿀 때는 ruleset도 함께 바꿔야 합니다.
(step 이름은 상관없습니다. 이번에 `Test` → `Test (with coverage)`로 바꿨지만 문제 없었습니다.)

## 2. 의존성 캐시

### 조사 결과: 이미 켜져 있었다
- `astral-sh/setup-uv@v5`의 기본값은 `enable-cache: auto`. GitHub 제공 runner에서는 자동으로 캐시를 씁니다.
- PR #1 첫 실행: `No GitHub Actions cache found` → `Saving cache`. 이후 실행은 모두 `Cache hit`.
- 그래서 "캐시 적용 전" 기준값이라고 잰 것도 사실은 캐시가 켜진 상태였습니다. **측정 전에 현재 상태부터 확인**해야 합니다.
- PR #6은 설정을 ci.yml에 **명시**만 했고, 동작 변화는 없습니다.

### 캐시 동작
```
캐시 키 = setup-uv-1-<OS>-<Python 버전>-<uv.lock 해시>
첫 실행: miss → 작업 끝에 저장(save)
다음 실행: 같은 키 → hit → 복원(restore), 저장 생략
uv.lock 변경 → 키가 바뀜 → miss → 새 캐시
```
- 캐시는 브랜치(ref)별로 저장됩니다 (`refs/heads/main`, `refs/pull/1/merge`). PR은 main의 캐시를 가져다 쓸 수 있습니다.
- 저장된 캐시는 약 1KB: setup-uv가 미리 빌드된 wheel은 다시 받는 게 빠르다고 보고 정리(prune)하기 때문.

### 교훈
- 이 프로젝트는 의존성 설치가 0~1초라 캐시 효과가 거의 없습니다.
- 캐시는 설치가 **느릴 때** 의미가 있습니다: 무거운 의존성, 직접 컴파일, npm/Maven처럼 받을 게 많을 때.
- **측정 먼저, 최적화는 그다음.**

## 3. 커버리지

### 설정
`pyproject.toml`:
```toml
[tool.coverage.run]
source = ["app"]          # 측정 대상: 앱 코드만

[tool.coverage.report]
show_missing = true       # 실행 안 된 줄 번호 표시
fail_under = 90           # 90% 미만이면 실패
```
`ci.yml`:
```yaml
- name: Test (with coverage)
  run: uv run pytest -v --cov
- name: Coverage summary          # 실행 화면 Summary 탭에 표 표시
  if: always()
  run: uv run coverage report --format=markdown >> "$GITHUB_STEP_SUMMARY"
```

### 실습 결과 (PR #7)
| 커밋 | 커버리지 | 놓친 줄 |
|---|---|---|
| 측정만 추가 | 96% | `app/main.py:22`: `GET /items`에 테스트가 없었음 |
| `test_list_items` 추가 | 100% | 없음 |

### 커버리지가 알려 주는 것 / 알려 주지 않는 것
- 알려 줌: 테스트 중 **한 번도 실행되지 않은** 코드 (이번처럼 테스트 없는 API 발견)
- 알려 주지 않음: 실행된 코드가 **올바르게 검증됐는지**. assert 없이 호출만 해도 100%.
- `fail_under`는 커버리지를 "올리는" 도구가 아니라 "떨어지는 것을 막는" 안전장치. 실무에서는 80~90%를 기준선으로 많이 씁니다.

## 문제 해결 기록: PR을 올렸는데 CI가 안 돌았다 (PR #7)
- 증상: PR에 체크가 하나도 없음 (`no checks reported`), 실행 기록 0건
- 확인한 것: YAML 문법 정상, 트리거(`push`, `pull_request`) 정상, 워크플로우 상태 active, 머지 충돌 없음
- 판단: GitHub이 `pull_request` 이벤트를 놓침
- 해결: PR을 닫았다가 다시 열기 (`reopened` 이벤트 발생). 빈 커밋 push도 방법

## 건너뛴 것: matrix
```yaml
strategy:
  matrix:
    python-version: ["3.12", "3.13"]
# with: python-version: ${{ matrix.python-version }}
```
- 같은 job을 버전별로 복제해 **병렬** 실행. 라이브러리처럼 여러 환경을 지원해야 할 때 사용.
- 체크 이름이 `lint-and-test (3.12)`처럼 바뀌므로 필수 체크도 함께 바꿔야 함 (위 "주의" 참고).

## 확인 질문
1. Ruleset이 Active인데도 main에 직접 push가 됐다면 무엇부터 확인해야 할까요?
2. 필수 체크가 `lint-and-test`인데 job 이름을 `test`로 바꾸는 PR을 올리면 어떻게 될까요? 어떻게 해결하나요?
3. 캐시 키에 `uv.lock`의 해시가 들어가는 이유는 무엇인가요? 해시 없이 고정된 키를 쓰면 어떤 문제가 생길까요?
4. 커버리지 100%인데도 버그가 있을 수 있는 예를 하나 들어 보세요.
5. `fail_under = 90`인 상태에서 테스트 없는 함수를 추가한 PR은 어떻게 처리되나요? (branch protection과 연결해서)

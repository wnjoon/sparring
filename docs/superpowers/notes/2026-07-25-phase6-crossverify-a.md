# Phase 6 Codex 어댑터 설계 — 세 가지 결정 검증

- 대상: `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md` @ `129d570` (브랜치 `wnjoon/verify-a-260725`, 내용은 `docs/phase6-codex-adapter`와 동일 커밋)
- 방법: 코드 정독 + `codex-cli 0.144.1` 실측 2건 + `stop-hook.sh` 격리 실행 2건 (레포는 수정하지 않음, 실험은 scratchpad에서 수행)
- 실측 환경 주의: 이 머신의 `CODEX_HOME`은 Orca가 관리하는 홈(`~/Library/Application Support/orca/codex-accounts/.../home`)으로 치환돼 있고, 그 안에 이미 사용자 스코프 `hooks.json`이 존재한다. 아래 실측 중 스코프 관련 결과는 이 조건에 영향을 받는다(§검증 완료 선언에 명시).

## 판정 표

| # | 결정 | 판정 | 근거 (파일:라인) | 조건 또는 위험 | 심각도 |
|---|---|---|---|---|---|
| 1 | §2 게이트키퍼 한 벌을 두 호스트가 공유 | **조건부 동의** | 표준입력은 진짜로 버려짐 — `HOOK_INPUT`은 `stop-hook.sh:130` 한 곳에서만 등장하고 아무 곳에서도 읽히지 않음. 차단 JSON도 이식 가능 — Codex 바이너리의 hook decision enum에 `approve`/`block`이 모두 있고(`approveblock`), 출력 와이어에 `systemMessage`/`stopReason`/`suppressOutput`이 존재. `command -v "$REVIEWER"`(`stop-hook.sh:793`)는 호스트 중립 | 아래 1-A~1-F 조건을 모두 명시·해결해야 성립 | high |
| 1-A | 필수 조건: `CLAUDE_PLUGIN_ROOT` 주입 | — | `stop-hook.sh:40-45,503,548,652,676` | 이 변수가 없으면 첫 Stop에서 조용히 열림. **실측**: 변수 미설정 + `phase: task` 상태로 훅 실행 → `template missing: /shared/prompts/reviewer.md` 로그 후 `{"decision":"approve"}`, 상태 파일 삭제, outcome 파일 없음. 즉 "활성화한 것처럼 보이다가 첫 정지에서 자멸"한다. Codex의 `HookHandlerConfig::Command` 필드는 `command`/`commandWindows`/`timeout`/`async`/`statusMessage`(+`description`/`matcher`)뿐 — **`env` 필드가 없다**. 다만 Codex는 `command` 문자열을 셸로 평가한다(이 머신의 사용자 스코프 `hooks.json`이 `if [ -f ... ]; then /bin/sh '...'; fi` 복합문이며 실제로 발화함). → 등록 형태를 `CLAUDE_PLUGIN_ROOT=/abs/path /abs/path/hooks/<hook>.sh`로 못박고, 훅 스스로도 변수 부재를 감지해 "차단 + 설치 오류 보고"로 처리하도록 바꿔야 한다(현재는 fail-open이라 침묵) | high |
| 1-B | 스펙이 지목한 진입점이 틀렸다 | — | `plugins/spar/hooks/hooks.json:21` vs 스펙 §2 표 | Claude 쪽 Stop에 등록된 파일은 `stop-hook.sh`가 아니라 **`stop-fight.sh`**다. 후자가 전자를 in-process로 감싸고(`stop-fight.sh:15,28`) 플랜 진행·체크박스·태스크별 커밋(`stop-fight.sh:56-61,80-94`)을 담당한다. 스펙대로 Codex에 `stop-hook.sh`를 직접 등록하면 `/spar:ready`→`/spar:fight` 플랜 모드가 Codex 좌석에서 통째로 사라진다. "게이트키퍼 한 벌"은 라운드 엔진에만 해당하는 말이며, 스펙은 `stop-fight.sh`를 한 번도 언급하지 않는다 | high |
| 1-C | 최종 sweep은 family 추상화 밖에 있다 | — | `stop-hook.sh:495`(`claude -p --safe-mode`), `:884`(`command -v claude`), `:440`(주석 "author-family Claude"), `shared/policy.md:72` | 스펙 §2는 "reviewer/judge/matcher/sweep 모두 family 해석으로 이미 추상화됨"이라 단정하지만 sweep은 `claude` 하드코딩이다. §2가 원하는 "sweep = `codex exec --sandbox read-only`"를 만들려면 공유 훅을 고쳐야 하고, 그러면 §7의 "`tests/test_stop_hook.sh`는 Codex용 추가가 필요 없다"와 비목표 "Claude 쪽 동작 불변"이 동시에 깨진다. 게다가 Codex 좌석 기본값(`reviewer: claude`)을 그대로 두면 sweep도 claude가 되어 "다른 모델·무맥락" 축이 사라진다 | medium |
| 1-D | Claude 전용 안내 문구가 Codex 좌석에서 거짓이 된다 | — | `stop-hook.sh:834-835` | `reviewer=claude`이면 "same-model review … Install the Codex CLI for cross-model review" 문구를 붙인다. Codex 좌석에서 `reviewer: claude`는 오히려 **교차 모델** 구성인데, 저자에게 동일 모델 리뷰라고 잘못 알린다. 문구를 저자 호스트 기준으로 분기해야 한다 | medium |
| 1-E | 강제 수단 경로가 위험 경로 목록에서 빠져 있다 | — | `commands/spar-classify-change.sh:66` | 위험 경로 패턴이 `*/.claude/hooks/*`, `*/hooks.json/*`만 잡고 `.codex/hooks.json`·`.codex/hooks/`는 잡지 않는다. Codex 좌석에서 강제 등록 파일 자체를 고치는 변경이 "위험하지 않은 작은 변경"으로 분류되어 Phase 4 안전 스킵(`stop-hook.sh:810-823`)을 타거나 sweep을 못 트리거할 수 있다. §2의 "그 외 전부 그대로 재사용"이 조용히 약해지는 지점 | medium |
| 1-F | 모든 상태 경로가 cwd 상대 | — | `stop-hook.sh:7-49` | 호스트가 훅을 레포 루트 cwd로 실행해야 성립한다. Claude Code는 보장하지만 Codex 쪽은 스파이크의 상대경로 명령이 동작했다는 간접 증거뿐이고, 내 환경에서는 프로젝트 스코프 훅 자체가 발화하지 않아 직접 측정하지 못했다. 설치 시 `cd`를 명령에 포함시키거나 payload의 `cwd`를 쓰도록 조건을 명시할 것 | low |
| 2 | §4 훅은 한 번만 설치하고 스스로 비활성 | **조건부 동의** | (a) **실측 확인**: 상태 파일 없는 빈 git 레포에서 훅 실행 → `{"decision":"approve"}`, rc 0, 파일시스템 변화 0건. 코드 근거 `stop-hook.sh:130-132`(`log()`는 그 전에 호출되지 않으므로 `.claude/`도 만들지 않음). (b) **확인**: 활성/취소 흐름은 상태 파일만 만지고 `hooks.json`을 건드리는 곳이 없다 — `commands/fight.md:86-107`, `commands/cancel.md:8-21`, 저장소 전체에 런타임에 `hooks.json`을 쓰는 코드 없음 | (a)(b)는 성립. (c)와 아래 2-A~2-C가 미해결 | high |
| 2-C | §6의 "훅이 살아 있는지 확인하고 아니면 거부" 의무는 **정적 점검으로는 구현 불가** | — | 실측: `codex doctor`/`codex doctor --json`은 훅을 보고하지 않음(hook 관련 행 없음), `codex hooks` 서브커맨드 없음, 훅 조회는 app-server의 `hooks/list` 메서드로만 존재(바이너리 문자열 `hooks/list failed in TUI`). 그리고 TUI 문자열에 `Continue without trusting (hooks won't run)` / `Trust all and continue` / `Hooks can run outside the sandbox after you trust them` | 신뢰는 **세션 단위 선택**이다. 사용자가 시작 시 "신뢰하지 않고 계속"을 누르면 파일의 `trustStatus`가 trusted여도 이 세션에서는 훅이 안 돈다. 따라서 파일 해시·trust 상태를 읽는 어떤 점검도 "이 세션이 실제로 강제되는가"를 증명하지 못한다. 구현 가능한 유일한 형태는 **훅이 발화한 사실을 관찰하는 것** — 같은 `hooks.json`(=같은 trust 소스)에 `SessionStart`(또는 `UserPromptSubmit`) 항목을 추가해 payload의 `session_id`로 마커 파일을 남기고, 활성화 단계가 "이 세션 id 마커가 없으면 거부"하게 한다. 스펙은 의무만 부과하고 메커니즘이 없으므로 이대로는 §6이 지켜질 수 없다. (마커가 스킬 실행 전에 기록되는지는 한 번 확인 필요) | high |
| 2-A | 설치 1회 + 사용자 스코프 = 무관한 세션 납치 | — | `stop-hook.sh:132,142`(상태 파일 존재만 보고 참여), `:830-831`(`prepare_round 1`, `set_state review 1`로 상태를 **변경**) | 사용자 스코프에 한 번 등록하면 모든 디렉터리의 모든 Codex 세션에서 훅이 돈다. 훅은 "이 런의 저자가 누구인지"를 구분하지 않으므로, Claude 쪽 루프가 활성인 레포에서 무관한 Codex 세션을 열어 정지하면 그 Codex 세션이 남의 런에 끌려 들어가 상태 기계를 전진시킨다. 상태 파일에 `host`/`owner_session` 필드를 넣고 불일치 시 즉시 승인하도록 조건을 붙일 것 | medium |
| 2-B | "프로젝트 스코프는 검증됐다"는 §4의 대체안이 재확인 필요 | — | 실측 3회 | 프로젝트 `.codex/hooks.json`에 Stop 훅(절대경로/셸형/상대경로 3종)을 등록하고 `--dangerously-bypass-hook-trust`로, 그리고 `-c projects."<path>".trust_level="trusted"`까지 준 상태로 `codex exec`를 돌렸지만 내 훅은 한 번도 발화하지 않았다(로그 파일 미생성). 같은 실행에서 사용자 스코프 훅은 발화했다(`hook: Stop Completed`). 원인은 분리하지 못했다 — 0.144.1에서 프로젝트 스코프 미탐색 / 사용자 스코프 우선(병합 아님) / Orca 관리 홈 제약 중 하나. 반대로 **사용자 스코프는 실제로 동작함이 확인됐다**(§4의 선호안이 맞다) | medium |
| 2-D | 스파이크가 trust 경로를 우회했다 | — | `docs/superpowers/notes/codex-hooks-spike.md:66` | 두 스파이크 모두 `--dangerously-bypass-hook-trust`로 실행됐다. 따라서 §4의 "설치 후 첫 실행에서 한 번 신뢰를 묻는다"와 §6의 "Codex는 신뢰되지 않은 훅을 실행하지 않는다"는 측정 결과가 아니라 추론이다(바이너리 문자열은 이를 지지하지만, 실행 경로는 미측정). 스펙에 "미측정"으로 표시할 것 | low |
| 3 | §5 루프 상태를 `.claude/`에 그대로 둔다 | **동의** | (a) 실제 영향 범위: 코드 19개 파일 351곳(`plugins`+`tests`), 문서 21개 파일 399곳 — 총 750곳. 다만 스펙의 "19개 테스트 스위트"는 과장이다. `.claude/`를 참조하는 테스트는 19개 중 **7개**(`test_stop_hook.sh` 178곳, `test_stop_fight.sh` 19, `test_harvest_intent.sh` 16, `test_record_outcome.sh` 11, `test_spar_report.sh` 7, `test_fight_launch.sh` 6, `test_fight_dispatch.sh` 1). 훅 크기도 45KB가 아니라 46,283 bytes(1,194줄) | (b) 정확성 문제 없음(아래 상세). (c) Phase 6 선행 조건 아님 — 미뤄도 된다 | low |
| 3-A | 개명이 기계적 치환이 아니라는 점을 §5에 적어둘 가치 | — | `commands/spar-harvest-intent.sh:123,140`(`.claude/rules`), `commands/spar-classify-change.sh:66`(`.claude/hooks/`), `commands/spar-report.sh:327`(`.claude/` 접두 스킵), `shared/policy.md:37` | 이 참조들은 Claude Code가 소유한 입력이므로 **개명 대상이 아니다**. 여기에 git 제외/pathspec 3종(`commands/fight.md:80`, `commands/ready.md:46`, `hooks/stop-fight.sh:60`, `hooks/stop-hook.sh:485`)까지 얽혀 있어, 일괄 sed는 intent 하베스터와 sweep 스냅샷 제외를 깨뜨린다. "미관 개선인데 비용이 크다"는 §5의 결론은 오히려 강화된다 | low |
| 3-B | 호스트가 `.claude/`를 읽어 간섭할 가능성 — 현재는 없음, 잠재 위험만 | — | 실측: `codex features list` → `external_migration  removed  false`. 바이너리의 `external_agent_config`는 `.claude` + `settings.json` + `hooks.json` + `CLAUDE.md` + `AGENTS.md` + `commands`/`subagents`/`skills`를 읽지만, 어디에도 `.claude/spar*`는 없다 | 0.144.1에서 그 임포터의 기능 플래그가 `removed`이므로 **지금은 `.claude/`를 읽지 않는다**. 되살아난다면 위험은 루프 상태 오염이 아니라 **Claude 쪽 spar 훅 등록이 Codex로 임포트되어 Stop 훅이 두 번 등록되는 것**(설치 1회 + 사용자 스코프와 결합 시 매 정지마다 `stop-fight.sh`가 두 번 실행). 상태 경로 개명으로는 막히지 않는 문제이므로 결정 3과는 독립이다. 스펙에 한 줄 기록만 권함 | low |
| D-1 | §7 테스트 계획이 §2의 요구와 모순 | 결함 | 스펙 §7 "Reuse: `tests/test_stop_hook.sh` … needs no Codex-specific additions" vs 1-A/1-C | 1-A(변수 부재 시 침묵 fail-open 대신 명시적 거부)와 1-C(family 인식 sweep)는 공유 훅 수정을 요구하므로 `test_stop_hook.sh`에 새 케이스가 필요하다. 스펙이 "추가 불필요"로 못박아 두면 그 회귀가 CI에서 잡히지 않는다 | medium |
| D-2 | SessionStart 훅이 이식 계획에 없다 | 결함 | `plugins/spar/hooks/hooks.json:4-15`, `hooks/session-start.sh` | Claude 쪽은 SessionStart로 unattended 런의 미결 설계 결정(`reviews/spar-pending.md`)을 알린다. Codex 이벤트 집합에 `sessionStart`가 있는데도 스펙 §2 표는 `Stop`만 등록한다. 결과적으로 Codex 좌석에서는 parked 결정이 아무에게도 surface되지 않는다 — "미완료를 완료로 보고하지 않음" 불변식의 사용자 대면 절반이 사라진다. 2-C의 라이브니스 마커를 SessionStart로 구현하면 같은 항목으로 함께 해결된다 | medium |

## 결정별 상세

### 결정 1 — 조건부 동의

"틀렸다면 무엇이 사실이어야 하는가"에서 출발했다. 이 결정이 성립하려면 `stop-hook.sh`가 (i) 표준입력 내용을 쓰지 않고, (ii) 외부 환경에서 오는 값에 의존하지 않고, (iii) 출력 스키마가 두 호스트에서 같은 의미이며, (iv) 특정 CLI를 전제하지 않고, (v) 경로 가정이 없어야 한다.

(i)과 (iii)은 통과다. (iv)는 reviewer/judge/matcher까지만 통과하고 sweep에서 깨진다(1-C). (ii)는 깨진다 — 그리고 그 깨짐이 조용하다는 점이 핵심이다. 실측한 EXP2에서 `CLAUDE_PLUGIN_ROOT`만 빼고 정상 활성 상태로 훅을 돌렸더니, 훅은 프롬프트 템플릿을 못 찾고 `finish_approve error-bypass`로 갔다(`stop-hook.sh:549-550`). 그 경로는 outcome writer 역시 `/commands/...`로 해석돼 실패하므로(`:63-68`) **durable outcome도 남지 않는다**. 저자가 보는 결과는 "그냥 세션이 끝남"이고, 흔적은 `.claude/spar.log` 한 줄뿐이다. §6이 걱정한 "조용한 무강제 상태"의 세 번째 모드이며, 스펙에 없다.

Codex에서 이 변수를 넣는 방법도 확인했다. `HookHandlerConfig::Command`에는 `env` 필드가 없지만 `command` 문자열이 셸로 평가되므로(이 머신의 사용자 스코프 훅이 `if … then /bin/sh '…' ; fi` 형태로 실제 발화) `VAR=... /abs/path/hook.sh` 형태가 가능하다. 다만 바이너리 문자열 테이블에 `PLUGIN_ROOT`/`CLAUDE_PLUGIN_ROOT`/`PLUGIN_DATA`/`CLAUDE_PLUGIN_DATA`가 훅 설정 스키마 문자열과 같은 구역에 함께 들어 있어, Codex가 플러그인 출처 훅에는 이 변수를 스스로 채워줄 여지도 있다. 확정하지 못했으므로 설치 스크립트는 스스로 주입하는 쪽으로 가야 한다.

### 결정 2 — 조건부 동의

(a)와 (b)는 실측·코드 양쪽에서 확인됐다. 문제는 (c)다. 스펙은 §4에서 "런마다 쓰지 않는다"는 좋은 결정을 내린 대가로 §6에 "훅이 살아 있는지 확인하고 아니면 거부"라는 새 의무를 만들었는데, Codex 0.144.1에는 그걸 CLI에서 물어볼 창구가 없다. 더 나쁜 것은, 창구가 있더라도 소용이 없다는 점이다 — 신뢰 결정이 세션 단위여서(`Continue without trusting (hooks won't run)`) 파일 상태는 이 세션의 강제 여부를 말해주지 않는다. 그래서 이 의무는 "정적 점검"으로는 원리적으로 불가능하고, "훅이 이 세션에서 실제로 발화했다는 관찰"로만 구현 가능하다. 스펙은 이 구분을 하지 않으므로 그대로 계획에 넘기면 구현자가 `trustStatus`를 읽는 무의미한 점검을 만들 위험이 크다.

### 결정 3 — 동의

개명의 실제 비용은 스펙이 말한 것보다 오히려 크다(코드 351곳 + 문서 399곳, 그리고 개명해선 안 되는 `.claude/rules`·`.claude/hooks/` 참조와 git 제외 패턴이 섞여 있어 일괄 치환이 불가). 정확성 문제는 찾지 못했다. Codex가 `.claude/`를 읽는 유일한 경로인 `external_agent_config` 임포터는 0.144.1에서 기능 플래그가 `removed`이고, 읽는 대상 목록에 `spar*` 상태 파일이 없다. 루프 자신의 intent 채널도 `.claude/rules`만 훑으므로(`spar-harvest-intent.sh:123,140`) 상태 파일이 리뷰어 프롬프트로 새지 않는다. 따라서 개명은 Phase 6의 선행 조건이 아니고, 미뤄도 무해하다. 단 §5의 근거를 "미관"에서 "간섭 없음을 확인했다"로 바꿔 적으면 나중에 재론될 여지가 줄어든다.

## 검증 완료 선언

읽은 파일:

- `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md` (전문)
- `docs/superpowers/notes/codex-hooks-spike.md` (전문)
- `plugins/spar/hooks/stop-hook.sh` (전문 1,194줄), `plugins/spar/hooks/stop-fight.sh` (전문), `plugins/spar/hooks/hooks.json`, `plugins/spar/hooks/session-start.sh`
- `plugins/spar/commands/fight.md`, `cancel.md` (전문), `plugins/spar/shared/policy.md` (전문)
- 부분 확인: `plugins/spar/commands/spar-classify-change.sh:55-80`, `spar-harvest-intent.sh:123,140`, `spar-report.sh:320-332`, `commands/ready.md:45-46`
- 참조 개수 산정: `plugins/`, `tests/`, `bench/`, `docs/`, `README.md` 전체 grep

실행한 실측:

1. `codex features list` → `hooks stable true`, `plugin_hooks removed false`, `external_migration removed false`
2. `codex doctor` / `codex doctor --json` → 훅 관련 보고 없음; `codex hooks` 서브커맨드 없음
3. Codex 0.144.1 바이너리 문자열: `HookHandlerConfig::Command` 필드 집합, hook decision enum(`approveblock`), 출력 와이어(`stopReason`/`suppressOutput`/`systemMessage`), TUI 신뢰 프롬프트 문구, `external_agent_config`가 읽는 파일 목록
4. `codex exec`로 프로젝트 스코프 `.codex/hooks.json` Stop 훅 발화 시도 3회 — 모두 미발화(사용자 스코프 훅은 같은 실행에서 발화)
5. `stop-hook.sh` 격리 실행 2건 — (EXP1) 상태 파일 없음 → approve, 부작용 0 / (EXP2) 정상 상태 + `CLAUDE_PLUGIN_ROOT` 미설정 → 침묵 fail-open, 상태 파일 삭제, outcome 미기록

확인하지 못한 것:

- 프로젝트 스코프 `.codex/hooks.json`이 **깨끗한** `~/.codex` 홈에서는 발화하는지. 내 환경은 Orca 관리 홈이고 사용자 스코프 `hooks.json`이 이미 있어, 미발화의 원인을 "미지원 / 우선순위 / 관리 홈 제약" 중 하나로 좁히지 못했다. 사용자 스코프가 동작한다는 사실만 확정.
- Codex가 훅 프로세스에 `CLAUDE_PLUGIN_ROOT`를 스스로 넣어주는 경우가 있는지(바이너리에 식별자는 있으나 플러그인 훅은 `removed`라 확인 불가).
- Codex가 훅을 실행할 때의 cwd가 레포 루트인지(내 프로젝트 스코프 훅이 발화하지 않아 직접 측정 불가).
- `{"decision":"approve"}`를 Codex가 실제 런타임에서 수용하는지(enum에 `approve`가 있다는 정적 근거만 확보, 실행 미측정).
- `stop-hook.sh`를 Codex Stop 훅으로 붙인 실제 종단 동작(라운드 진행·차단 반복). 이 검증에서는 모델 크레딧이 드는 종단 시나리오를 돌리지 않았다.
- `SessionStart` 훅이 Codex 스킬 첫 동작보다 먼저 실행되는지(2-C 라이브니스 마커의 전제).

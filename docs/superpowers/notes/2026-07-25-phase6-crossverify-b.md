# Phase 6 Codex 어댑터 설계 검증

| # | 결정 | 판정(동의/조건부/반대) | 근거 (파일:라인) | 조건 또는 위험 | 심각도(high/med/low) |
|---|---|---|---|---|---|
| 1 | 게이트키퍼 한 벌을 두 호스트가 공유 | 조건부 | `plugins/spar/hooks/stop-hook.sh:130-132`, `plugins/spar/hooks/stop-hook.sh:40-45`, `plugins/spar/hooks/stop-hook.sh:366-435`, `plugins/spar/hooks/stop-hook.sh:440-495`, `plugins/spar/hooks/stop-hook.sh:834-835`, `plugins/spar/hooks/stop-hook.sh:884-885`; payload 호환 실측은 `docs/superpowers/notes/codex-hooks-spike.md:109-120` | stdin은 전부 소비한 뒤 사용하지 않고, 상태가 없으면 승인한다. `decision`/`reason`은 양쪽 호스트에서 성립하지만 `systemMessage`는 Codex spike에서 검증되지 않았다. 더 큰 문제는 reviewer/judge/matcher만 `reviewer`로 분기하고 최종 sweep은 Claude로 하드코딩됐다는 점이다. Codex 저자 + Claude reviewer에서는 sweep을 fresh Codex로 선택하도록 `author_family`(또는 동등한 호스트 정보)를 상태/어댑터에서 제공해야 하며, line 834의 “same-model” 판단도 함께 고쳐야 한다. 또한 모든 상태·산출물 경로가 상대경로이므로 Codex가 훅을 저장소 루트 cwd에서 실행한다는 조건을 설치/E2E 테스트로 고정해야 한다. `CLAUDE_PLUGIN_ROOT`는 절대경로로 export되어야 보조 스크립트가 동작한다. | high |
| 2 | 훅은 한 번 설치하고 상태 파일로 self-disable | 조건부 | `plugins/spar/hooks/stop-hook.sh:130-132`, `tests/test_stop_hook.sh:55-59`, `plugins/spar/commands/fight.md:13-17`, `plugins/spar/commands/fight.md:84-109`, `plugins/spar/commands/cancel.md:8-21`, `docs/superpowers/notes/codex-hooks-spike.md:37-41`, `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md:101-115`, `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md:144-150` | (a) 상태가 없으면 stdin을 한 번 읽는 것 외에는 로그/파일을 만들지 않고 즉시 approve한다. (b) 현재 fight/cancel은 상태만 생성·삭제하며 런마다 hooks.json을 설치·제거하지 않는다. 따라서 install-once 자체는 맞다. (c) 그러나 0.144.1의 공개 CLI help/doctor에는 현재 세션의 hook trust/policy 실행 여부를 질의하는 인터페이스가 없고, 스펙도 검증 프로토콜을 제시하지 않는다. 스크립트를 직접 실행하는 검사는 “등록되고 신뢰되어 Codex가 호출한다”를 증명하지 못하며, Stop 시 sentinel을 쓰는 handshake도 훅이 죽어 있으면 세션이 그냥 끝나므로 “활성화가 거부”되지 않는다. 공개적인 trust/managed-policy introspection을 먼저 실증하거나, 설치 시 별도 검증과 명시적 미보장 UX로 의무를 재설계해야 한다. | high |
| 3 | 루프 상태 경로를 `.claude/`에 유지 | 동의 | `plugins/spar/hooks/stop-hook.sh:7-29`, `plugins/spar/commands/fight.md:65-82`, `plugins/spar/commands/ready.md:43-51`, `docs/superpowers/notes/codex-hooks-spike.md:135-142` | 현재 트리에서 `.claude/spar` 문자열은 제품 코드 9파일/104회, 테스트 6파일/216회(합계 15파일/320회), 저장소 전체는 35파일/707회다. 19개 테스트 “suite” 전체를 실행할 필요는 있어도 실제 경로 치환이 필요한 테스트 파일은 6개다. Codex의 external-agent importer가 읽는 것은 `.claude/settings.json`, `CLAUDE.md`, commands/subagents/hooks/skills이고 `spar*.local.md`나 생성 runner는 그 예약 경로가 아니다. 현재 정확성 간섭 근거가 없으므로 Phase 6 선행조건이 아니며, 호스트 중립화는 별도 마이그레이션으로 미뤄도 된다. | low |
| 4 | 스펙 외 결함: Codex Stop 등록 대상 | 반대 | `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md:69`, `plugins/spar/hooks/hooks.json:16-23`, `plugins/spar/hooks/stop-fight.sh:27-41`, `plugins/spar/hooks/stop-fight.sh:53-100`, `tests/test_hooks_json.sh:8-12`, `plugins/spar/commands/fight.md:29-57` | 스펙은 Codex에 `stop-hook.sh`를 직접 등록하지만 현재 Claude 어댑터의 단일 Stop 훅은 `stop-fight.sh`다. 후자는 본체 결정을 보존하면서 plan outcome을 읽어 다음 task를 launch하는 dispatcher다. Codex skill이 fight.md와 같은 plan-aware 진입점을 제공하면서 본체만 등록하면 `/spar:ready` 계획은 첫 task 뒤 진행/종료되지 않는다. Codex도 dispatcher를 등록하거나, Codex skill에서 plan 기능을 명시적으로 제외하고 문서·테스트를 분리해야 한다. | high |

## 판단 요약

- 결정 1의 “같은 파일 재사용” 방향은 맞지만, 현재 파일은 저자 호스트를 전혀 모델링하지 않아 좌석을 뒤집은 최종 sweep을 올바르게 만들 수 없다. 파일 복제 대신 작은 host/author-family 입력을 추가하는 것이 불변식과 공유 목표를 함께 지키는 수정이다.
- 결정 2의 install-once/self-disable 방식은 코드로 확인된다. 결함은 self-disable이 아니라 “현재 Codex 세션이 실제로 이 훅을 신뢰해 실행한다”를 activation 단계에서 판별할 수 있다고 가정한 부분이다.
- 결정 3은 유지해도 정확성 문제가 없다. 경로 개명은 생각보다 넓지만 “19개 테스트 파일 수정”은 아니며, Phase 6 이후의 독립 마이그레이션으로 처리할 수 있다.

## 검증 완료 선언

읽은 파일:

- `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md`
- `docs/superpowers/notes/codex-hooks-spike.md`
- `plugins/spar/hooks/stop-hook.sh`
- `plugins/spar/hooks/stop-fight.sh`
- `plugins/spar/hooks/hooks.json`
- `plugins/spar/commands/fight.md`
- `plugins/spar/commands/cancel.md`
- `plugins/spar/commands/ready.md`
- `plugins/spar/shared/policy.md`
- `tests/test_stop_hook.sh`
- `tests/test_stop_fight.sh`
- `tests/test_hooks_json.sh`

추가로 Codex CLI 0.144.1의 `--help`, `doctor --help`, `debug --help`, `features list`를 로컬에서 확인했고, 전체 저장소의 `.claude/spar` 참조를 검색해 위 개수를 산정했다.

확인하지 못한 부분:

- user-scope `~/.codex/hooks.json` 지원 여부는 스펙 자체가 구현 시 확인할 open question으로 남겨 두었고, 이번 읽기 전용 검증에서도 실측하지 않았다.
- Codex가 `systemMessage` 출력 필드를 의미 있게 처리하는지는 spike가 입증하지 않는다. 핵심 차단 계약인 `decision:block` + non-empty `reason`만 입증돼 있다.
- 실제 managed policy 환경에서 `allowManagedHooksOnly`를 켠 E2E와, 신뢰되지 않은 훅을 현재 세션 안에서 감지하는 방법은 확인하지 못했다.
- Codex 어댑터 파일(`adapters/codex/*`)은 아직 설계 산출물에만 존재하므로 설치 병합·idempotency·절대경로 export는 구현 코드로 검증할 수 없었다.

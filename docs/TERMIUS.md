# Termius UI/UX 분석 — Muxi 참고 자료

> Termius는 iOS/Android/Desktop을 지원하는 크로스플랫폼 SSH 클라이언트로, 모바일 터미널 UX의 업계 기준점.
> Muxi 개발 시 참고할 수 있는 UI/UX 패턴을 정리한 문서.

---

## 1. 네비게이션 구조

### iPhone (Bottom Tab Bar)
- **하단 탭 바**: Vault, Connections, Profile 3개 탭
- 터미널 세션 활성화 시 탭 바 위에 열린 연결 목록 표시
- SFTP 전송 진행 상황을 탭 바 우측 코너에 브라우저 다운로드 UI처럼 표시

### iPad (Desktop-like Layout)
- **상단 탭 바**: 데스크톱 스타일, Vault와 활성 연결 간 전환
- 사이드바 + 메인 영역 구조
- iPadOS Split View/Stage Manager 멀티태스킹 지원

### 공통 사이드바 (터미널 내)
터미널 내 사이드바는 4개 탭으로 구성:
1. **Snippets** — 저장된 명령어 목록, 탭 한 번으로 실행
2. **History** — 명령어 히스토리, 입력 중 자동완성과 연동
3. **Keyboard** — iOS 키보드에 없는 특수 키 (Esc, F1-F12 등)
4. **Themes** — 현재 호스트의 터미널 테마 변경

> **Muxi 시사점**: tmux pane 기반이므로 사이드바에 pane 목록 + 빠른 명령 + 키보드 확장을 배치할 수 있음

---

## 2. 터미널 키보드 UX

### Extra Keys Strip (키보드 상단 바)
- iOS 기본 키보드 위에 **추가 키 스트립** 표시
- 기본 제공 키: `Ctrl`, `Alt`, `Tab`, `Esc`, 방향키, `PgUp/PgDn`, `Home/End`
- **커스터마이징 가능**:
  - `...` 버튼 → `⚙` 설정 진입
  - 키 그룹 드래그로 순서 변경
  - `+Add key group`으로 최대 4개 키 묶음 생성
  - 기본값 복원 가능

### 확장 키보드 (Extended Keyboard)
- 이모지/스티커 키보드와 유사한 UI로 전체 특수 키 접근
- F1-F12, 시그널 키 (^C, ^Z, ^D 등), 특수 문자 포함
- 확장 키보드 내에서 Snippets, Shell History, 외관 설정도 접근 가능

### 하드웨어 키보드 지원
- Bluetooth/Smart Keyboard 완전 지원
- CJK (한중일) 입력 지원 (하드웨어 키보드 사용 시)
- `Shift+Tab` 바인딩 지원 (Claude Code 등 CLI 에이전트 호환)
- 볼륨 버튼에 `Shift+Tab` 바인딩 옵션

### Sudo 비밀번호 편의 기능
- 키보드 상단에 "Paste stored password" 버튼
- sudo 프롬프트 감지 시 저장된 비밀번호 원탭 입력

> **Muxi 시사점**: tmux 모드에서 pane 전환, 세션 관리 등의 tmux 단축키를 strip에 배치하면 효율적

---

## 3. 터치 제스처

### 방향키 에뮬레이션
- **Space 홀드 + 손가락 이동**: 상하좌우 방향키 입력
- 손가락을 계속 누르면 해당 방향으로 연속 키 입력
- 커서 속도 설정에 따라 제스처 트리거 빈도 조절
- **터미널 롱프레스 + 이동**으로도 동일 동작

### 텍스트 선택 & 복사/붙여넣기
- **단어 탭 + 홀드 (1초)** → 손가락 떼면 선택 모드
- "Select" 탭 후 선택 범위 조절
- **터미널 아무 곳 탭 + 홀드** → "Paste" 옵션 표시
- ANSI OSC 52 지원 (원격 서버에서 클립보드 직접 접근)

### SFTP 제스처
- **좌로 스와이프**: 파일 옵션 (복사, 이름 변경, 권한, 삭제)
- 폴더 탭으로 디렉토리 탐색, 하단 경로 탭으로 상위 이동

### 기기 흔들기
- 디바이스 흔들기로 Tab, 방향키, PgUp/Down, Home, End 에뮬레이션 (접근성)

> **Muxi 시사점**: Space 홀드 방향키 패턴은 tmux pane 내 탐색에 매우 유용. 롱프레스로 tmux 복사 모드 진입도 고려

---

## 4. 멀티세션 관리

### 탭 시스템
- 브라우저 스타일 탭으로 다중 SSH/SFTP 세션 관리
- 탭 간 빠른 전환 (데스크톱: `Cmd+J` / `Ctrl+J`)
- 새 연결: `Cmd+T` / `Ctrl+T`

### Split View (분할 화면)
- 하나의 탭에 최대 **16개 pane** 배치 가능
- 수직/수평 분할 커스텀 레이아웃
- 탭을 다른 탭 위로 드래그하여 Split View 생성
- pane 별 독립적 세션

### Workspaces
- 여러 탭을 하나의 Workspace로 그룹화
- 프로젝트/환경별 작업 공간 분리
- Workspace 간 전환으로 컨텍스트 스위칭

### Broadcast Input (동시 입력)
- Split View 상태에서 Broadcast Input 활성화
- 한 번 입력하면 **모든 활성 pane에 동시 전송**
- 여러 서버에 동일 명령 실행 시 유용
- Snippets와 연동하여 자동완성 + 동시 실행

> **Muxi 시사점**: tmux의 `synchronize-panes`와 유사. Muxi는 tmux 네이티브 pane 분할을 그대로 활용하므로, UI에서 split view를 tmux 레이아웃과 매핑하면 자연스러움

---

## 5. 호스트 관리 & 연결

### 호스트 구조
```
Vault (최상위, E2E 암호화)
 └── Group (논리적 호스트 그룹)
      └── Host (개별 서버)
           ├── Address (IP/hostname)
           ├── Port
           ├── Identity (자격증명 세트)
           └── Tags (검색용 라벨)
```

### Identity (자격증명)
- Username + Password + SSH Key를 하나의 Identity로 묶음
- 호스트/그룹에 연결하여 재사용
- Username 필드에서 Identity 자동완성
- 중복 자격증명 입력 방지

### Tags
- 호스트에 태그 부여 (예: "Ubuntu", "Production", "Client-A")
- 호스트 목록 화면에서 호스트명 옆에 표시
- 대량 호스트 검색/필터링에 활용

### Quick Connect
- 호스트 목록에서 탭 한 번으로 즉시 연결
- 새 탭에서 호스트명 입력 시작하면 바로 검색 (Command Palette 불필요)
- 호스트 정보 자동 저장 (수동 저장 불필요)

### Command Palette
- `Cmd+K` / `Ctrl+K`로 호출
- 모든 탭, 호스트, 명령 통합 검색
- 호스트가 검색 결과 상단에 표시
- 긴 호스트명도 표시할 수 있는 넓은 레이아웃

> **Muxi 시사점**: SwiftData 서버 모델에 Group/Tag 구조 반영. tmux 세션은 서버 연결 후 자동이므로, 호스트 관리 UX에 집중

---

## 6. 터미널 커스터마이징

### 테마
- 내장 테마: Night Owl, Light Owl, Aura, Dracula, Nord Light/Dark, Monokai
- Kanagawa 시리즈: Wave, Dragon, Lotus
- Hacker 시리즈: Blue, Green, Red
- 호스트별 개별 테마 설정 가능
- 사이드바 Themes 탭에서 실시간 전환

### 폰트
- Nerd Fonts 내장: Fira Code, JetBrains Mono, Meslo
- 추가 폰트: Source Code Pro, DejaVu Sans Mono, Ubuntu Mono, Cascadia Code
- 폰트 크기 조절 (+/- 버튼)
- 호스트별 개별 폰트 설정

### 터미널 에뮬레이션
- xterm-256color 지원
- "linux" 터미널 에뮬레이션 타입 추가 (크로스플랫폼 일관성)
- 증가된 Scrollback buffer 크기

> **Muxi 시사점**: Muxi는 이미 5개 테마 (Catppuccin 기반) 구현. 호스트별 테마/폰트 설정은 향후 고려. Nerd Fonts는 Sarasa Gothic Mono NF로 이미 계획됨

---

## 7. AI & 자동완성

### Autocomplete (Helium)
- 경로 자동완성 (파일/폴더)
- 히스토리 명령어 자동완성
- Snippets 제안
- 비밀번호 자동 입력
- 입력 중 호버 리스트로 매칭 명령 표시

### AI 명령 생성
- 자연어로 명령 설명 → 셸 명령 자동 생성
- 호스트 OS, 셸 타입, 태그 등 컨텍스트 반영
- 음성 입력(Dictation) 지원
- 무료 사용 가능 (Settings > Terminal에서 활성화)

### AI Agent
- ChatGPT/Claude와 유사한 인프라 관리 AI
- 인프라 정보 접근 가능
- 여러 터미널에서 동시 명령 실행
- 결과 처리 및 후속 조치

### AI Widget
- 키보드 위에 AI 위젯 배치
- 여러 명령을 위젯 전환 없이 연속 실행
- CLI 코딩 에이전트 (Claude Code 등) 통합 개선

> **Muxi 시사점**: v1에서는 AI 불필요. 하지만 tmux send-keys 기반 명령 전송 구조는 자연어→명령 변환 파이프라인 추가에 적합

---

## 8. 보안 & 인증

### 생체 인증 SSH
- **Face ID / Touch ID**로 SSH 키 인증
- Apple Secure Enclave (SEP)에 키 저장
- SEP 키는 외부 접근 불가 — 생체 인증 필수
- SSH.id: 디바이스 바운드, 생체 보호 SSH 키를 핸들로 프로비저닝

### Vault 암호화
- E2E 암호화 (클라이언트 사이드 키 파생)
- AES-256 암호화
- libsodium + Botan 암호 라이브러리
- TLS 1.2 전송 암호화
- HTTP Cookie는 iOS Keychain에 저장

### 디바이스 관리
- Devices 섹션에서 계정 접근 디바이스 확인
- 원격 로그아웃 기능

> **Muxi 시사점**: Keychain + 생체 인증은 Muxi 보안 모델과 일치. SEP 키 생성은 고급 기능으로 향후 고려

---

## 9. 파일 전송 (SFTP)

### 이중 패널 구조
- 좌/우 2개 패널로 파일 브라우저 구성
- 로컬 ↔ 원격, 원격 ↔ 원격 전송 가능
- 터미널 탭과 나란히 SFTP 탭 운영

### 파일 관리
- 스와이프로 파일 옵션 (복사, 이름 변경, 권한, 삭제)
- 경로 탭으로 디렉토리 탐색
- 전송 진행률 탭 바에 표시
- 항목 정렬 순서 저장

### 전송 기능
- 다중 SFTP 세션 동시 운영
- 드래그 & 드롭 (iPad)
- 백그라운드 전송

> **Muxi 시사점**: v1에서는 tmux에 집중, SFTP는 후순위. 하지만 UI 구조는 tmux pane 브라우저와 유사하게 설계 가능

---

## 10. 프로토콜 지원

| 프로토콜 | 설명 |
|----------|------|
| SSH | 기본, 비밀번호/키/인증서 인증 |
| Mosh | 모바일 최적화 셸 (로밍/단절 복구) |
| Telnet | 레거시 지원 |
| SFTP | 파일 전송 |
| Port Forwarding | Local/Remote/Dynamic 포트 포워딩 |

### Port Forwarding
- 단계별 위저드로 유형 선택 가이드
- Local: 원격 포트를 로컬처럼 접근
- Remote: 로컬 포트를 원격에서 접근
- Dynamic: SOCKS 프록시 (여러 서비스 접근)

> **Muxi 시사점**: Mosh 지원은 모바일 특성상 매우 유용 (네트워크 전환 시 세션 유지). 향후 고려

---

## 11. 크로스플랫폼 동기화

### Vault Sync
- 호스트, 그룹, 키, Snippets, 포트 포워딩 규칙, Known Hosts 동기화
- E2E 암호화 상태로 클라우드 동기화
- 실시간 동기화 — 한 기기 변경 즉시 반영
- 비밀번호 매니저와 유사한 UX

### 지원 플랫폼
- iOS, iPadOS, Android, macOS, Windows, Linux
- 모든 플랫폼에서 동일한 호스트/자격증명 접근

> **Muxi 시사점**: iCloud sync 계획과 일맥상통. SwiftData + CloudKit으로 서버 목록 동기화 구현 가능

---

## 12. 가격 정책 & 기능 티어

| 티어 | 가격 | 주요 기능 |
|------|------|----------|
| **Starter** (무료) | $0 | 로컬 Vault, AI 자동완성, 포트 포워딩, SSH/Mosh |
| **Pro** | $10/월 (연간) | + 클라우드 Vault 동기화, Snippets 자동화 |
| **Team** | $20/사용자/월 | + 팀 Vault 공유, RBAC |
| **Business** | 문의 | + SSO, 감사 로그, 엔터프라이즈 보안 |

> **Muxi 시사점**: 무료 티어에서 핵심 기능 제공 + 동기화/고급기능 프리미엄 모델. Muxi도 유사 전략 고려 가능

---

## 13. 최근 주요 업데이트 (2024-2025)

| 버전 | 날짜 | 주요 변경 |
|------|------|----------|
| 6.3.1 | 2025.09 | Shift+Tab 볼륨 버튼 바인딩, AI Widget 설정 이동, PQC 키 교환 |
| 6.2.0 | 2025.07 | 터미널 세션 로그 자동 수집, 디바이스 간 로그 동기화 |
| 6.x | 2025 | SSH.id (디바이스 바운드 생체 SSH 키), OpenSSH 인증서 지원 |
| 5.x | 2024 | 새 바텀 탭 바, SFTP 탭, AI 명령 생성, CJK 하드웨어 키보드 지원 |
| 5.x | 2024 | Split View 최대 16 pane, 커스텀 레이아웃 (수직/수평) |
| 4.x | 2023 | Broadcast Input, Workspaces, 새 터미널 테마 다수 |

---

## 14. Muxi에 적용할 핵심 패턴 요약

### 즉시 적용 가능
1. **Extra Keys Strip** — tmux 키 (Ctrl+B, 방향키, Esc) 커스터마이징 가능한 상단 바
2. **Space 홀드 방향키** — 터미널 내 커서 이동 제스처
3. **호스트별 테마** — 서버 구분을 위한 시각적 차별화
4. **Quick Connect** — 최소 탭으로 즉시 SSH 연결
5. **사이드바 4탭 구조** — Snippets, History, 특수키, 테마

### 중기 적용
6. **Split View + tmux 레이아웃 매핑** — tmux pane을 iOS Split View로 렌더링
7. **Broadcast Input** — tmux `synchronize-panes` UI 래퍼
8. **Identity 시스템** — 자격증명 재사용 구조
9. **SFTP 이중 패널** — 파일 관리 UI
10. **Command Palette** — 호스트/명령 통합 검색

### 장기 고려
11. **AI 명령 생성** — 자연어 → tmux/셸 명령
12. **Mosh 프로토콜** — 모바일 네트워크 복원력
13. **Vault Sync** — iCloud 기반 E2E 암호화 동기화
14. **생체 SSH 키** — Secure Enclave 활용

---

## 참고 소스

- [Termius iOS App Store](https://apps.apple.com/us/app/termius-modern-ssh-client/id549039908)
- [New Touch Terminal on iOS](https://termius.com/blog/new-touch-terminal-on-ios)
- [Termius for iOS: New Navigation and SFTP](https://termius.com/blog/termius-for-ios-new-navigation-and-sftp)
- [Termius Desktop Reimagined](https://termius.com/blog/termius-x)
- [Workspaces: Manage Multiple Connections](https://termius.com/blog/workspaces)
- [Broadcast Input](https://termius.com/blog/broadcast-input)
- [AI Terminal Features](https://termius.com/blog/boost-your-terminal-experience-with-ai)
- [Keyboard Customization](https://support.termius.com/hc/en-us/articles/4403035505689)
- [Groups & Tags](https://docs.termius.com/termius-handbook/groups-and-tags)
- [Termius Security](https://termius.com/security)
- [iOS Changelog](https://termius.com/changelog/ios-changelog)
- [Termius Pricing](https://termius.com/pricing)
- [Podfeet Review](https://www.podfeet.com/blog/2024/08/termius/)
- [Beginner's Guide (DEV)](https://dev.to/rishitashaw/a-beginners-guide-to-termius-the-ultimate-terminal-555i)
- [G2 Reviews](https://www.g2.com/products/termius/reviews)

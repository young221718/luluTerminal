# 엔진과 의존성

전체 Ghostty 렌더러/PTY/폰트/입력 경로를 유지한 `libghostty-spm` 공개 패키지를 사용한다.
Ghostty 프로젝트가 보장하는 안정적인 외부 전체 임베딩 API는 아니며, 패키지의 유지보수와 호환성 검증이 필요하다.

| 의존성 | 고정 버전/출처 | 라이선스 |
| --- | --- | --- |
| libghostty-spm | https://github.com/Lakr233/libghostty-spm/tree/42bacd1339f323a693ddbca779295f4f77e5a697 | MIT |
| Ghostty 소스 | 1e9e14af5df14211892f5fc15fd21a49c7d94868 + 위 패키지의 공개 patch stack | MIT |
| Ghostty 바이너리 | https://github.com/Lakr233/libghostty-spm/releases/tag/upstream.1e9e14af5df1-3 | MIT |
| DisplayLink | 3.0.1, Package.resolved의 정확한 커밋 | MIT |

Ghostty XCFramework ZIP SHA-256: `0bf7e5e13f8e42ffca040a6cef7e985fc30bcaa81ff513bd2a93eb097398c6d8`.
SwiftPM이 다운로드 시 이 체크섬을 검사한다. 저장소는 바이너리를 Git에 넣지 않는다.

패키지는 upstream native app shell, Sentry, custom shaders, inspector를 제외한 빌드다.
앱은 `GhosttyTerminal` 제품만 사용하며 ShellCraftKit 또는 테마 모음은 링크하지 않는다.
Swift 패키지·DisplayLink·Ghostty의 MIT 고지와 패키지 내 bash-preexec 고지를 앱에 포함한다.

# Ghostty 1.4 빌드

기본 의존성은 Ghostty 1.4.0에서 직접 빌드한 로컬 패키지다. 준비된 패키지가 없으면 앱·Bridge 빌드는 준비 명령을 안내하고 실패한다. 이전 원격 엔진으로 자동 전환하지 않는다. Core 전용 검사는 엔진 없이 실행할 수 있다.

## 준비

전체 Xcode와 macOS SDK·Metal Toolchain, Zig 0.17.0이 필요하다. 도구 설치와 Apple 약관 확인은 별도다. `DEVELOPER_DIR`가 없으면 현재 `xcode-select` 설정을 사용하며 시스템 선택을 변경하지 않는다.

```bash
bash scripts/prepare-ghostty14.sh .cache/ghostty14 /path/to/zig-0.17.0
```

준비 스크립트는 새 출력 폴더만 사용하며 이미 존재하는 폴더를 덮어쓰지 않는다. 재빌드하려면 새 경로를 선택하고 `LULU_GHOSTTY_PACKAGE=<새 경로>/libghostty-spm`을 테스트·빌드·라이선스 검사에 동일하게 설정한다. 생성 바이너리·소스 checkout·캐시는 Git에 넣지 않는다.

## 후보 검토와 승인

준비 명령만으로 앱 패키징 승인이 완료되지는 않는다. 새 빌드의 `manifest-ghostty14.candidate.json`과 `libghostty-spm/BinaryTarget/ghostty-build-provenance.json`을 검토해야 한다. 현재 저장소가 승인한 기록과 다르면 라이선스 검사는 실패한다.

1. 아래 고정 커밋·패치·빌드 설정과 후보의 `local_build_policy`, `local_wrapper_files`를 대조한다. 예상하지 않은 입력 차이는 새 변경으로 검토하며 후보 전체를 승인 파일 위에 복사하지 않는다.
2. 두 CPU 아카이브와 헤더의 실제 파일 해시·아키텍처·최소 macOS 버전·라이선스 고지, 해당 빌드의 검사 결과를 확인한다. 생성 기록만 읽는 것으로 바이너리 검증을 대신하지 않는다.
3. 같은 고정 입력의 정상 재빌드임을 확인한 뒤 `docs/licenses/manifest-ghostty14.json`의 `local_provenance_sha256`만 후보의 값으로 명시적으로 갱신한다. 다른 정책 필드가 달라지면 해당 차이도 별도로 검토해야 한다. 스크립트는 이 승인을 자동 수행하지 않는다.
4. 승인한 패키지로 다음 검사를 실행한다. 기록·실제 파일·고지의 불일치를 고친다는 이유로 검사를 끄거나 통과 조건을 낮추지 않는다.

```bash
python3 scripts/check-licenses.py
bash scripts/test.sh
APP_VERSION=0.1.0 APP_BUILD_NUMBER=1 bash scripts/build-app.sh
```

앱 버전은 숫자 `주.부.패치`, 빌드 번호는 양의 정수다. 생략하면 `0.1.0`·`1`을 사용한다. `v0.1.0` 태그에 대응하는 앱 버전은 `0.1.0`이며 빌드 스크립트는 Info.plist의 실제 값을 서명 전에 대조한다.

## 고정 입력과 검증

- wrapper: `5b9cb63d83e687b4a66d6c3a3c2a840341c576d9`
- 엔진: Ghostty 1.4.0, `83fb95624b0439ee660c2679b43b38c8b63769cd`
- 추가 패치: `third-party/ghostty14/`의 엔진 연동 포트와 AppKit 드롭 입력 확인
- 정책: `docs/licenses/manifest-ghostty14.json`의 소스·패치·빌드 입력 해시
- 생성 기록: 로컬 패키지의 `BinaryTarget/ghostty-build-provenance.json`

엔진과 wrapper를 위 커밋에서 복제하고 패치를 적용한 뒤 macOS arm64·x86_64 아카이브를 생성한다. 라이선스 검사기는 실제 헤더·바이너리 전체 파일과 CPU별 아카이브 해시, 실제 최소 실행 버전, libintl 정의 심볼 부재를 검사한다. 생성 기록의 입력은 저장소 정책과 대조하므로 생성된 기록만 바꿔 검사를 통과시키지 못한다.

`manifest-ghostty14.candidate.json`은 입력 정책을 재검토할 때 쓰는 후보이며 자동으로 저장소 정책을 덮어쓰지 않는다. 같은 입력으로 다시 빌드한 바이너리가 바이트 단위로 동일하다고 가정하지 않는다. 정상 재빌드에서도 소스 정책은 유지하되 새 산출물과 빌드 기록을 검토한 뒤 후보의 `local_provenance_sha256`을 승인해야 패키징할 수 있다. 스크립트는 승인된 기록의 해시를 자동 갱신하지 않는다.

이 검사는 로컬 준비 과정에서 생성한 산출물의 일관성을 확인한다. 독립적인 재현 빌드 증명, 모든 의존성의 완전한 SBOM, Intel 실기기·모든 macOS 버전·실서버·한국어 IME 수락을 대신하지 않는다. 기존 원격 엔진 고정값과 고지는 이전 빌드 이력으로 보존한다.

# 오픈소스 라이선스와 고지

luluTerminal은 Ghostty 기반 터미널 엔진과 아래 오픈소스 구성 요소를 사용합니다.
이 문서는 해당 구성 요소의 저작권·재배포 조건을 설명하며, luluTerminal 전체에 새 라이선스를 부여하지 않습니다.
이 문서는 기본 로컬 Ghostty 1.4 빌드용입니다. 패키지 기본 경로는 `.cache/ghostty14/libghostty-spm`이며 `LULU_GHOSTTY_PACKAGE`로 다른 준비 경로를 선택할 수 있습니다. 확인 기준은 `docs/licenses/manifest-ghostty14.json`과 `BinaryTarget/ghostty-build-provenance.json`이며, 마지막 검토일은 2026-10-28입니다.

## 고정한 엔진과 Swift 패키지

| 구성 요소 | 정확한 버전·출처 | 고지 원문 |
| --- | --- | --- |
| libghostty-spm · GhosttyTerminal · GhosttyKit · MIT 셸 통합 | [5b9cb63d83e687b4a66d6c3a3c2a840341c576d9](https://github.com/Lakr233/libghostty-spm/tree/5b9cb63d83e687b4a66d6c3a3c2a840341c576d9), MIT | `libghostty-spm.txt` |
| Ghostty | [83fb95624b0439ee660c2679b43b38c8b63769cd](https://github.com/ghostty-org/ghostty/tree/83fb95624b0439ee660c2679b43b38c8b63769cd) + 위 패키지의 공개 patch stack, MIT | `Ghostty.txt` |
| Ghostty XCFramework | Ghostty 1.4.0과 고정한 연동 패치에서 로컬 생성, 아래 개별 의존성의 조건 포함 | 아래 표 참조 |
| DisplayLink | [3.0.1 · 41bea2661e04bebcb1c4f15fc0b6197850100fdd](https://github.com/Lakr233/DisplayLink/tree/41bea2661e04bebcb1c4f15fc0b6197850100fdd), MIT | `DisplayLink.txt` |
| bash-preexec | 위 패키지에 포함된 Ryan Caloras 및 contributors의 MIT 고지 | `bash-preexec.txt` |

로컬 바이너리의 전체 파일과 두 CPU 아카이브의 SHA-256, 소스·패치·도구 버전은 `ghostty-build-provenance.json`에 기록합니다. 앱 라이선스 검사기가 실제 파일과 대조하며, 바이너리는 Git에 포함하지 않습니다. 이 기록은 다른 Mac에서 바이트 단위로 동일하게 재빌드된다는 보증은 아닙니다.
전체 Ghostty 렌더러·PTY·폰트·입력 경로를 사용하지만, Ghostty 프로젝트가 보장하는 안정적인 외부 전체 임베딩 API는 아닙니다.

## 네이티브 의존성과 내장 폰트

아래 버전은 위 Ghostty 커밋의 `build.zig.zon`, `pkg/*/build.zig.zon`, vendored 소스에서 확인했습니다.
macOS 정적 아카이브의 구성 파일도 확인했으며, 순수 Zig 라이브러리는 링크 후 제거될 수 있는 의존성 고지까지 보존합니다.
원문 출처와 파일별 SHA-256은 `docs/licenses/manifest.json`에 기록합니다.

| 구성 요소 | 버전 · 적용 조건 | 고지 원문 |
| --- | --- | --- |
| FreeType | 2.13.2, FreeType License 선택; BDF/PCF·해시·HarfBuzz 유래 부분·내부 zlib 고지 포함 | `FreeType.txt` |
| libpng | 1.6.43, PNG Reference Library License | `libpng.txt` |
| zlib | 1.3.1, zlib License | `zlib.txt` |
| Oniguruma | 6.9.9, BSD 계열 | `oniguruma.txt` |
| Highway | 66486a10623fa0d72fe91260f96c892e41aceb06, Apache 2.0 / BSD 3-Clause 원문 보존 | `Highway.txt` |
| simdutf | vendored 헤더의 실제 버전 9.0.0; MIT / Apache 2.0 및 포함된 BSD 고지 | `simdutf.txt` |
| Wuffs | Ghostty mirror의 7411f488fe2e2c205c3d3b3d28638b7356522930, MIT / Apache 2.0 원문 보존 | `Wuffs.txt` |
| stb_image · stb_image_resize | 위 Ghostty 커밋의 vendored 소스, MIT 선택 | `stb.txt` |
| libxev · Zap 유래 ThreadPool | 819ffa180ca20e31c7eded74e2e1aceb1eab557f, MIT | `libxev.txt` |
| zig-objc | 3352c12a868f8787ab71bf2ca6eab9fcfb635c52, MIT | `zig_objc.txt` |
| zf | 87153bb86b75d21fbac897b738f316d449f5d0c9, MIT | `zf.txt` |
| libvaxis · zigimg | 6fd944a27fb3d6f596e981076381a3131f2448b4 · c701c9f99779d7ddf594dcc6da8f858fd277d61f, MIT | `libvaxis.txt` |
| uucode · Unicode 데이터·UTF-8·폭 테이블 고지 | ea62149739404a73c202b48a33bf6dd2af4bd9b0, MIT · Unicode 및 각 원문의 조건 | `uucode.txt` |
| z2d · 포함된 Cairo/Pixman 등 고지 | 40af3e84a4e15a9f31d126b3f281f23ce6a3dae5, MPL 2.0 및 각 원문의 조건 | `z2d.txt` |
| JetBrains Mono | 2.304, SIL Open Font License 1.1 | `JetBrainsMono.txt` |
| Nerd Fonts Symbols Only | 3.4.0, 실제 Ghostty font archive의 MIT 고지 | `NerdFontsSymbolsOnly.txt` |
| Zig 런타임 | 아카이브의 `compiler_rt.o`; Zig contributors의 MIT 고지 | `Zig.txt` |

FreeType 사용 고지: Portions of this software are copyright © 2023 The FreeType Project (www.freetype.org). All rights reserved.
Ghostty의 simdutf 패키지 메타데이터에는 5.2.8이 남아 있으나, 실제 포함된 `simdutf.h`는 `SIMDUTF_VERSION "9.0.0"`입니다.

## 재배포 시 유지할 조건

- MIT/BSD/Unicode 등의 저작권·허가·면책 고지를 원문과 함께 배포합니다. 원저작자의 보증이나 제품 후원을 암시하지 않습니다.
- FreeType은 FTL을 선택하며, 위 FreeType 사용 고지와 원문을 함께 제공합니다.
- Apache 2.0 원문과 해당 구성 요소에 포함된 저작권·추가 고지를 보존합니다. 수정 시 변경 사실을 표시해야 합니다.
- JetBrains Mono는 OFL 원문·저작권 고지를 포함합니다. 폰트 자체만 따로 판매하지 않으며, 수정 폰트에는 원문의 Reserved Font Name 조건을 적용합니다.
- z2d의 MPL 적용 소스와 수정 사항은 MPL 조건으로 취득할 수 있어야 합니다. 현재 패키지 patch stack은 z2d 파일을 수정하지 않습니다. 정확한 소스는 [이 커밋](https://github.com/vancluever/z2d/tree/40af3e84a4e15a9f31d126b3f281f23ce6a3dae5)과 [소스 아카이브](https://codeload.github.com/vancluever/z2d/tar.gz/40af3e84a4e15a9f31d126b3f281f23ce6a3dae5)에서 받을 수 있습니다. 원문과 소스 취득 안내는 `z2d.txt`에도 포함합니다. 배포자는 이 소스 경로의 접근 가능성을 유지하고, z2d 수정 시 해당 수정 소스도 제공해야 합니다. MPL 2.0의 larger-work 조항은 다른 파일에 별도 조건을 적용하는 것을 허용합니다.

앱이 사용하는 제품은 `GhosttyTerminal`입니다. `ShellCraftKit`과 `GhosttyTheme`의 테마 모음은 사용하지 않습니다.
고정한 패키지의 셸 통합은 MIT로 새로 작성된 bash/zsh 스크립트와 MIT bash-preexec이며, upstream Ghostty/Kitty의 GPL 셸 스크립트를 복사하지 않습니다.
패키지 빌드는 native app shell, Sentry, custom shaders, inspector, i18n을 제외합니다.
특히 patch `0021-no-libintl.sh`와 `-Di18n=false`가 GNU libintl을 제외하며, 검토한 macOS arm64·x86_64 아카이브에서 `libintl_` 정의 심볼이 없음을 확인했습니다.
이 기록은 모든 플랫폼·향후 버전에 대한 보증이 아니므로, 패키지·바이너리·리소스를 교체하면 다시 검토해야 합니다.

## 앱에서 확인하기와 빌드 검사

설정 → 일반 → 오픈소스 라이선스에서 번들에 포함된 전체 고지를 읽고 선택·복사할 수 있습니다.
빌드 스크립트는 이 문서, 개별 원문, 통합한 `THIRD_PARTY_NOTICES.txt`를 앱의 `Contents/Resources/Licenses/`에 넣습니다.

```bash
python3 scripts/check-licenses.py
python3 scripts/check-licenses.py --app "dist/Infra Terminal.app"
```

검사는 고정 패키지·바이너리 식별자, 고지 원문 해시·목록, 실제 앱에 복사한 원문과 통합 고지, bash-preexec 리소스 고지를 대조합니다.
이는 알려진 의존성의 누락·패키징 회귀 검사이며, 독립적인 바이너리 전체 SBOM이나 법률 검토를 대신하지 않습니다.

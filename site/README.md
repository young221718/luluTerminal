# luluTerminal product site

Buildless Korean product introduction. Serve `dist/` with any static web server; no package installation or build is needed.

```sh
python3 scripts/check_site.py
node scripts/check_interactions.mjs
python3 -m http.server 8091 --directory dist
```

The browser demo uses fixed fictional server names, accounts and metrics. It does not connect to SSH, run a terminal, collect resources, submit forms or use an API. Theme and font controls affect only the demo and reset on reload.

## Source and assets

Product contracts were checked against the app repository's `README.md`, `docs/SPEC.md`, `docs/THIRD_PARTY.ghostty14.md`, `Package.swift`, and native panel/connection source on 2026-10-28. `dist/assets/app-icon.png` is copied unchanged from the app's `Resources/AppIcon.png`. Source links point to the public luluTerminal repository. Release links target the first `v0.1.0` prerelease. The advertised Universal download contains Apple Silicon and Intel executables for macOS 14 or later, signed ad-hoc without Apple notarization. Runtime acceptance was performed on Apple Silicon; Intel hardware acceptance and a full-app MIT license are not implied. Confirm that the release and its assets are published before deploying this site update.

The app is based on Ghostty. The repository notices cover Ghostty and its open-source libraries and fonts, including transitive licenses; these are not all represented as MIT. App code and owl assets currently have no separate reuse license.

## Validation boundary

`check_site.py` validates local asset references, fragment targets, unique IDs, external link safety, required demo controls, JavaScript syntax, and byte equality of the copied icon when the app source is present. `node scripts/check_interactions.mjs` runs the real JavaScript event handlers with a minimal DOM stand-in and checks desktop pane toggles, pointer/keyboard resize, settings, themes/fonts, fictional server states, tabs, and mobile focus/panel state. This does not replace browser visual QA, real pointer/keyboard behavior, responsive layout checks, or accessibility acceptance. Live link verification, registration, source synchronization and publication are the integrating agent's responsibility.

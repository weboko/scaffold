# Logos ↔ Dokieli Integration Feasibility Research

**Date:** 2026-05-09
**Scope:** Bidirectional integration feasibility between the Logos storage stack and the Dokieli decentralised editor.
**Status:** Research / no code or PoC.

---

## Executive Summary

- **Logos Basecamp** (cloned head `b44a5cf`) is a Qt6/QML desktop application shell. It loads native C++/QML plugins in-process via `QPluginLoader`, with QML running inside a deny-all-network sandbox (`src/PluginLoader.cpp:285-315`). It is explicitly experimental (`README.md:233-236`). It has **no first-class concept of a "web app" plugin**, **no embedded HTTP server**, **no user/identity model**, and no Chromium/Electron/CEF/Tauri runtime — only Qt's bundled QtWebView (WebKitGTK on Linux) is available via the optional external `logos-webview-app` plugin (`flake.nix:17,122,141,151`).
- **Logos storage** is split across two repos. `logos-storage-nim` (head `cf2f40f`, README labelled **pre-alpha**, `README.md:5`) is a rebrand-fork of `nim-codex` with HTTP REST + libp2p, content-addressed by CIDs, **no application-level auth** (`openapi.yaml:8-9`), default-bound to `127.0.0.1:8080` (`storage/conf.nim:208`), and CORS disabled unless explicitly enabled with `--api-cors-origin` (`storage/conf.nim:220-227`). `logos-storage-module` (head `b1d82a3`) is a Qt6 C++ plugin that links `libstorage` directly via FFI rather than HTTP.
- **No browser-side SDK exists for Logos storage.** No `.js`/`.ts`/`.wasm` build target in either repo. A browser can only reach Logos storage via the HTTP REST API, against a user-controlled local node with CORS opened.
- **Dokieli** (head `3a907bd`) is browser-only (`webpack.config.cjs:17-32`), shipped as both a static SPA and a WebExtension (`manifest.json`). It has **already been refactored to a pluggable storage abstraction** (`src/storage/backend.js:37-805`) with three working backends: `SolidStorage`, `HttpStorage`, `GitForgeStorage`. All callers go through `Config.Storage.<verb>(…)` set up in `src/init.js:73-103`. This is a major and recent boon for any custom-backend integration.
- **Direction A (Logos as Dokieli backend) is moderate effort.** The clean seam exists (one new `LogosStorage extends StorageBackend` class plus router wiring). The genuine mismatches are not in the abstraction: they are (1) CID vs hierarchical-URL addressing, leaking into `createImmutableResource`/`createMutableResource` in `src/doc.js:2189-2342`; (2) WAC-ACL writes (`src/fetcher.js:663-706`) which are Solid-specific and would be a no-op on Logos; (3) PATCH/SPARQL semantics on a content-addressed immutable store; (4) browser CORS reach into a libp2p node.
- **Direction B (Dokieli as a Basecamp app) is hard, possibly blocked, without modifying Basecamp itself.** Basecamp recognises only `ui_qml` and legacy Qt plugin types (`src/PluginLoader.cpp:111-118`); there is no `ui_web` enum value. Routing Dokieli's storage traffic through Basecamp would require the WebView's network stack to terminate on a Logos C++ binding (likely via a `qrc:`/custom URL scheme handler) since QML's NAM is deny-all and there is no HTTP loopback exposed.
- **Recommendation: Direction A is the lower-risk first step.** It surfaces the protocol-level mismatches (CID/path, immutability, ACL) early, can be validated end-to-end in a vanilla browser, and exercises Logos storage from real client traffic before any UI shell work begins. Direction B should follow once Direction A has hardened a `LogosStorage` backend that can be reused inside an embedded WebView later.
- **Open blockers for a confident answer:** (1) does QtWebView/WebKitGTK render Dokieli's modern toolchain (ProseMirror, ES module bundle, WebExtension assumptions absent) without crashes or feature gaps — needs runtime verification; (2) does the Logos storage HTTP API support range GETs cleanly enough for partial reads from a browser; (3) what is the intended Logos identity story — there is no DID/wallet/WebID concept anywhere in the storage repos today; (4) is it acceptable to require users to run a local Logos storage daemon with CORS opened.
- **License compatibility is fine:** both Logos storage repos and Logos Basecamp dual-license MIT/Apache-2; Dokieli is Apache-2.0 (`/home/user/research/dokieli/LICENSE`).
- **Maturity caveats to flag now:** `logos-storage-nim` self-declares pre-alpha and inherits ~1400 PRs of Codex history that has been partially renamed (lingering `codexdht` imports in `storage/discovery.nim:21`, `storage/rest/api.nim:26`); `logos-storage-module` is small (~30 PRs) but actively developed; Basecamp has known limits (no workspace persistence, no module updates — `docs/project.md:638-640`); Dokieli depends on `@uvdsl/solid-oidc-client-browser` (a community client, not Inrupt).

---

## 1. Logos Basecamp Functionality Assessment

### 1.1 What Basecamp does and how it is structured

Basecamp is a Qt6/QML desktop application shell that hosts Logos modules and UI apps as a unified workspace. `CLAUDE.md:1-3` describes it as "a Qt/QML desktop application with a plugin-based architecture. It uses Nix for builds and has an MCP-based QML inspector for UI automation." `docs/spec.md:5` confirms it is "a desktop application shell for the Logos modular platform."

It is simultaneously a Nix flake (`flake.nix:1-2: description = "Logos App - Qt application with UI plugins"`) and a native Qt application; Nix is the recommended build/packaging path producing AppImages, .app bundles, and DMGs (`README.md:33-37`). Languages: C++17 + QML (`docs/project.md:80-86`); build via CMake + Ninja (`README.md:217-220`).

Top-level layout:

| Path | Purpose |
|---|---|
| `app/` | Main executable. `app/main.cpp:59-240` initialises Qt, sets module dirs via `logos_core_*` C-API, auto-loads `package_manager`, instantiates `Window`. `app/interfaces/IComponent.h:9-17` defines the C++ plugin interface (`IComponent_iid = "com.logos.component.IComponent"`). |
| `src/` | The `main_ui` Qt plugin — actual UI. Key files: `MainUIBackend.cpp` (QML-facing facade), `CoreModuleManager.cpp` (logos_core wrapper), `UIPluginManager.cpp` (~765 lines), `PackageCoordinator.cpp` (~694 lines, IPC with `package_manager`), `PluginLoader.cpp` (~375 lines, async load of QML/C++ plugins). QML in `src/qml/{panels,views,controls}/`. `src/restricted/` holds the network sandbox (`DenyAllNAMFactory`, `RestrictedUrlInterceptor`). |
| `qt-ios/` | Experimental iOS port (`docs/project.md:67`, `docs/spec.md:342`). |
| `assets/` | One Linux desktop entry. |
| `scripts/` | macOS DMG/sign-and-notarize helpers. |
| `nix/` | Decomposed flake: `app.nix` (344 lines), `main-ui.nix`, `smoke-test.nix`, `integration-test.nix`, `build-info.nix`. |
| `ci/` | Jenkinsfiles + GitHub Actions in `.github/workflows/build.yml`. |
| `tests/` | `ui-tests.mjs` — Node-driven MCP UI tests. |

Build/launch: `nix build '.#app'` then `./result/bin/LogosBasecamp` (`README.md:15-17`); dev hot-reload via `./run-dev.sh` which exports QML paths and disables disk cache (`run-dev.sh:8-55`). Flake outputs include `app`, `portable`, `bin-bundle-dir`, `bin-appimage`, `bin-macos-app`, `smoke-test`, `integration-test`, `logos-qt-mcp` (`flake.nix:230-256`).

### 1.2 Limitations

**Pre-alpha indicators.** No `VERSION` file (`flake.nix:48-50` falls back to empty string with comment "VERSION is only present on release branches"). Explicit disclaimer at `README.md:233-236`: "This repository forms part of an experimental development environment and is not intended for production use." `docs/project.md:638-640` enumerates known limits: no workspace persistence, no module updates, QML inspector disabled in release builds.

**Hardcoded extensibility limits.**
- QML import allowlist hardcoded to three modules: `kAllowedLogosModules = { "Theme", "Controls", "Icons" }` (`src/PluginLoader.cpp:294-298`), with a `TODO(security)` admitting all of Qt's default QML paths are still allowed today (`src/PluginLoader.cpp:305-307`).
- Only one module auto-loaded: `logos_core_load_module("package_manager")` (`app/main.cpp:137`).
- Plugin type discriminator recognises **only** `ui_qml` and legacy Qt C++ types (`src/PluginLoader.cpp:111-118`, `src/UIPluginManager.cpp:96-101`). No `ui_web` / `ui_html` enum value.
- Single-process Qt model: UI plugins loaded in-process via `QPluginLoader` / `QQuickWidget` (`src/PluginLoader.cpp:144,266`); only Logos *Modules* run in `logos_host` subprocesses (`docs/spec.md:18`).
- Workspace not persisted across restarts (`docs/project.md:638`).

**Identity / auth.** Token-based **inter-module capabilities only**, not user identity. `app/main.cpp:158-164` prints token keys from `logosAPI.getTokenManager()`. Capability tokens are issued by `logos-capability-module`. Grep returns zero meaningful matches for `webid`, `did:`, `wallet`, `keypair` (the one `wallet_ui` reference in `src/UIPluginManager.cpp:681-684` is an example comment about a different plugin). **Basecamp itself has no concept of a logged-in user**, no OAuth, no signing key.

**Networking.** UI plugins are **explicitly blocked** from networking: `src/PluginLoader.cpp:285` installs `DenyAllNAMFactory` on each plugin's `QQmlEngine`. All networking goes through Logos Modules running in `logos_host` subprocesses, which carry their own peer-to-peer transports (waku/mix per `README.md:128-159`). No embedded HTTP server in Basecamp itself (zero matches for `QHttpServer`/`QTcpServer::listen` in `app/` or `src/`). The QML inspector listens on `localhost:3768` (`CLAUDE.md:105`, `app/main.cpp:183`).

**Platforms.** Officially Linux (x86_64, aarch64) and macOS (x86_64, aarch64) — `docs/project.md:632-634`, `flake.nix:39`. iOS is experimental. **No Windows.** Nix recommended; CMake-direct path also documented (`README.md:214-231`).

### 1.3 Application/extension model

Two distinct extension types, captured at `docs/spec.md:18-19` and `docs/project.md:103-118`:

1. **Logos Modules** — process-isolated shared libs managed by `liblogos_core`. Discovered from two module directories set in `app/main.cpp:122-127`. Shared libs (`.so/.dylib/.dll`).
2. **UI Apps** — Qt plugins loaded in-process. Discovered via the `package_manager` Logos Module (`docs/project.md:454-456`). Metadata fields: `name`, `view`, `type`, `mainFilePath`, `dependencies`, `installDir` (`src/UIPluginManager.cpp:86-103`). Type ∈ {`ui_qml`, legacy} (`src/PluginLoader.cpp:111-118`).

**Package format:** LGX archives. `package_manager.installPluginAsync(filePath, false, callback)` (`docs/project.md:170-173,401`). Built via `nix bundle --bundler github:logos-co/nix-bundle-lgx ...` (`README.md:23-31`).

**Sandbox.** Per-plugin `QQmlEngine` with `DenyAllNAMFactory` and `RestrictedUrlInterceptor` (`src/PluginLoader.cpp:285-315`). Allowed file roots: plugin's `installDir`, QML entry directory, and the three shared QML modules above. Inter-module authorisation uses capability tokens (`app/main.cpp:158-164`).

**Web-app surface.** None natively. The flake bundles `pkgs.qt6.qtwebview` and (Linux) `webkitgtk_4_1` at runtime (`nix/app.nix:18,21-23,113`); the qmlImportPath includes `${pkgs.qt6.qtwebview}/lib/qt-6/qml` (`nix/app.nix:69`). An external `logos-webview-app` plugin already uses this (`flake.nix:17,122,141,151`). But Basecamp's own source contains zero `WebView`/`WebEngine`/`QWebEngine` matches — web rendering exists only inside an opt-in plugin's QML.

---

## 2. Logos Storage Protocol Analysis

### 2.1 `logos-storage-nim` — what it is

A **rebrand-fork of `nim-codex`**. Confirmed by:
- Earliest commit `60861d6 chore: rename codex to logos storage (#1359)` (2025-12-18). PR numbers run 1338→1428, the inherited upstream Codex sequence. Later `ab413bd chore!: Finish renaming Codex to Logos Storage (#1399)`.
- README first line: "Logos Storage Filesharing Client" and points API readers to `https://api.codex.storage` (`README.md:48`).
- Source headers retain `Copyright (c) 2021 Status Research & Development GmbH` (e.g. `storage/storage.nim:2`).
- Lingering `codex` imports: `storage/discovery.nim:21` `import pkg/codexdht/discv5/...`, `storage/rest/api.nim:26`, `storage/rest/json.nim:3-4`, `library/storage_thread_requests/requests/node_info_request.nim:7`.
- DHT submodule at `vendor/logos-storage-nim-dht` → `https://github.com/logos-storage/logos-storage-nim-dht.git` (`.gitmodules`), itself a fork of `codex-storage/nim-codex-dht`.

### 2.2 Protocol surface (HTTP)

Base URL `http://localhost:8080/api/storage/v1` (`openapi.yaml:206-207`). **Security: `security: - {}`** (`openapi.yaml:8-9`) — no auth.

**Addressing:** CIDs (multiformats). Manifest CIDs identify datasets; each manifest holds a `treeCid` (Merkle root), `datasetSize`, `blockSize`, optional `filename`, `mimetype` (`openapi.yaml:153-179`).

Endpoints:
- `GET /data` — list local manifests (`openapi.yaml:253-273`).
- `POST /data` — upload, body `application/octet-stream`; optional `content-type`/`content-disposition` headers; returns CID as `text/plain` (`openapi.yaml:274-309`).
- `GET /data/{cid}` — local-only download (`:311-337`); implementation `storage/rest/api.nim:101-110`.
- `DELETE /data/{cid}` — delete (`:339-357`).
- `POST /data/{cid}/network` — async network fetch (`:359-383`).
- `GET /data/{cid}/network/stream` — sync streaming pull (`:385-410`).
- `GET /data/{cid}/network/manifest` — manifest only (`:412-436`).
- `GET /data/{cid}/exists` — boolean (`:438-464`).
- `GET /space`, `GET /spr`, `GET /peerid`, `GET /connect/{peerId}`, `POST /debug/chronicles/loglevel`, `GET /debug/info` (`:466-548`).

### 2.3 Wire format / transport

HTTP plus libp2p. HTTP REST (Presto framework) bound on `127.0.0.1:8080` by default (`storage/conf.nim:206-218`, `storage/storage.nim:288-298`). **No TLS in the listener** — plain HTTP only.

libp2p stack: Switch with Noise + Yamux + TCP, signed peer record on (`storage/storage.nim:174-185`). Two custom protocols:
- Block exchange `"/storage/blockexc/1.0.0"` (`storage/blockexchange/network/network.nim:35`).
- Manifest protocol `"/storage/manifest/1.0.0"` (`storage/manifest/protocol.nim:32`).

Discovery: discv5 via `pkg/codexdht` (`storage/discovery.nim:21`).

### 2.4 Identity / authentication

**No application-level auth.** OpenAPI: `security: - {}`. Grep across `storage/`, `library/` for `auth|bearer|jwt|wallet|ethereum|marketplace|payment|did:` returns no meaningful hits — only libp2p's `SignedPeerRecord` for peer identity (`storage/storage.nim:183`, `storage/conf.nim:185,350-428`). **No marketplace and no payments** — these upstream Codex features have been stripped.

Identity at the libp2p layer is a libp2p PrivateKey loaded from disk (`storage.nim:91-97`) yielding a PeerID/SPR.

### 2.5 Client bindings

Only first-class non-HTTP client surface is the **C ABI `libstorage`** in `library/`:
- `library/libstorage.h` (~470 lines).
- `library/libstorage.nim` exports the C ABI.
- Functions cover the full HTTP surface plus chunked upload/download: `storage_new`, `storage_start`, `storage_stop`, `storage_destroy`, `storage_upload_init/_chunk/_file/_finalize/_cancel`, `storage_download_init/_stream/_chunk/_cancel`, `storage_download_manifest`, `storage_list`, `storage_space`, `storage_delete` (`library/libstorage.h:59-320+`).
- Model: node-in-process. `storage_new` instantiates a full `StorageServer` on a worker thread; calls are async via `StorageCallback` (`library/libstorage.h:47`, `library/README.md:11-37`).
- README mentions Go bindings (separate repo) and a third-party Rust binding `https://github.com/nipsysdev/storage-rust-bindings` (`README.md:50-67`).

**No JS, no WASM, no browser SDK.** `find` over the repo for `.js`/`.ts`/`.wasm`/`.html` returns nothing outside `vendor/`. No emscripten/wasm target in `Makefile`/`build.nims`.

### 2.6 Maturity

- README warning `README.md:5`: "WARNING: This project is under active development and is considered pre-alpha." Stability badge: experimental.
- Latest tag `v0.3.2`; `storage.nimble:1` declares `version = "0.1.0"` (out of sync with the tag).
- HEAD `cf2f40f` (2026-05-06) "chore: update nim 2.2.10 (#1425)". 89 source `.nim` files in `storage/`, 93 test files in `tests/`. Low TODO/FIXME density (~18 hits across 89 files).
- Default-bound to loopback, no auth, no TLS, marketplace stripped — designed for single-tenant local node use.

### 2.7 `logos-storage-module`

A Qt6 C++ plugin wrapping `libstorage` via FFI. `metadata.json:1-15` declares it `core`/`protocol` module name `storage_module`, main entry point `storage_module_plugin`, bundling `libstorage.{so,dylib,dll}`. CMake invokes a `logos_module(...)` macro from external `LogosModule.cmake` (`CMakeLists.txt:1-19`).

**Three source files only:**
- `src/storage_module_interface.h` (451 lines) — Qt `QObject` abstract interface, `Q_INVOKABLE` virtuals, signals.
- `src/storage_module_plugin.h` — concrete plugin (`Q_PLUGIN_METADATA`, `Q_INTERFACES`).
- `src/storage_module_plugin.cpp` (~41 KB) — direct C-ABI calls into `libstorage`: `storage_new` (`:568`), `storage_start` (`:594`), `storage_stop` (`:612`), `storage_upload_*` (`:879-951`), `storage_download_*` (`:1003-1036`).

**API to Basecamp (ID `org.logos.StorageModuleInterface`, `:449`):** `Q_INVOKABLE` methods including `init(QString)`, `start()`, `stop()`, `destroy()`, `version()`, `dataDir()`, `peerId()`, `spr()`, `connect(...)`, `uploadUrl(QUrl,int)`, `uploadInit/Chunk/Finalize/Cancel`, `downloadToUrl/Chunks/Cancel`, `exists(QString)`, `fetch(QString)`, `remove(QString)`, `space()`, `manifests()`, `downloadManifest(QString)`. Async signal `eventResponse(QString,QVariantList)` carries `storageStart`, `storageStop`, `storageUploadProgress/Done`, `storageDownloadProgress/Done` (`storage_module_plugin.h:46-64`). Synchronous wrappers via wait-for-signal pattern with 1000 ms default (`storage_module_plugin.h:70,139,142-146`).

**Maturity:** `metadata.json:3 "version": "1.0.0"`. Latest commit `b1d82a3` (2026-04-23). Smaller (~30 PRs). Tests with `mock_libstorage.cpp` and `stubs/libstorage.h` to test the wrapper without a real node. Empty `capabilities: []` — host permission system unused.

### 2.8 Cross-cut: browser-side reach

No browser-loadable client exists. CORS is implementable but disabled by default:
- `storage/conf.nim:220-227`: `apiCorsAllowedOrigin {.name: "api-cors-origin".}: Option[string]`, default `string.none`, description `'*' will allow all origins, '' will allow none. Disallow all cross origin requests to download data` (the default).
- When opted in, the server emits `Access-Control-Allow-Origin/Methods/Max-Age` and registers `MethodOptions` preflight handlers (`storage/rest/api.nim:150-189` and matching calls at lines 295,304,311,332,345,370,391,421,439,456,484,507,537,566,599,620). Preflight allows `content-type, content-disposition` for `POST /data`.

A browser served from any HTTPS page cannot reach `http://127.0.0.1:8080` without mixed-content failures; there is no TLS termination in the Nim server. Also: with `security: - {}`, any code that can reach the port has full read/write/delete authority over the user's repo. **No signed-URL/capability-token/WebID auth path exists.**

---

## 3. Dokieli Analysis

### 3.1 What Dokieli is and how it ships

A clientside, browser-resident editor for decentralised article authoring, Web Annotations, and "social Web" interactions (replies, likes, announcements, peer-review, bookmarking). It edits HTML+RDFa documents in place and saves them back over HTTP. Identity by WebID; storage Solid/LDP by default with three working backends today. Spec set (per `README.md:131-147`): WebID, WebID-OIDC, WAC/ACL, LDP, Solid Protocol, LDN, ActivityPub, Web Annotation Model & Vocabulary, ActivityStreams 2.0, ODRL, Memento, Robust Links.

**Build / shipping:** Webpack bundles a single ES module entry `src/dokieli.js` to `scripts/dokieli.js` (`webpack.config.cjs:36-43`). Browser-only — Node fallbacks `fs/tls/net/http/https/crypto/path/stream/os` are all `false` (`webpack.config.cjs:17-32`). Two shipping forms:
- Static SPA (one rebuilt JS, plus `index.html`, `service-worker.js`, CSS/media).
- WebExtension Manifest V2 (`manifest.json:8,29-37`) with `extension-background.js` + `extension-content-script.js` injected into every page; the content script imports the same `scripts/dokieli.js` and CSS, then bootstraps via `DO.U.load()` (`extension-content-script.js:25-44`).

The service worker (`service-worker.js:3-67`) is a thin app-shell cache: same-origin GETs whose pathname is in a fixed allowlist (`/`, `/index.html`, `/docs`, two CSS, the logo, `/scripts/dokieli.js`); everything else passes through. **It does not transform storage I/O.** Conditionally registered only when on the same origin and not in WebExtension mode (`src/init.js:105-119`).

### 3.2 Storage layer (the critical part)

Two layers:

1. **Solid/LDP layer** in `src/fetcher.js` — low-level HTTP with hardcoded LDP semantics.
2. **Pluggable router/abstraction** in `src/storage/backend.js` — `StorageBackend` interface plus three concrete implementations (`HttpStorage`, `SolidStorage`, `GitForgeStorage`).

The unrelated `src/storage.js` only handles device-side IndexedDB (autosave, OIDC token cache, user profile cache via `idb-keyval`) — `src/storage.js:18-46,52-105,263-285`.

**Solid-layer primitives** (`src/fetcher.js`):
- `getResource(url, headers, options)` — `:250-351`.
- `getResourceHead(url, headers, options)` — `:362-366`.
- `getResourceOptions(url, options)` — `:379-416`.
- `putResource(url, data, contentType, links, options)` — `:611-650`.
- `postResource(url, slug, data, contentType, links, options)` — `:541-594`.
- `patchResource(url, data, options)` — `:510-539`.
- `patchResourceGraph(url, patches, options)` — N3 / SPARQL-Update from `{insert,delete,where}` triples (`:439-508`).
- `deleteResource(url, options)` — `:124-151`.
- `copyResource(fromURL, toURL, options)` — read-then-write (`:84-114`).
- `processSave(url, slug, data, options)` — slug present → POST else PUT (`:708-751`).
- `patchResourceWithAcceptPatch` / `putResourceWithAcceptPut` — content-negotiate before writing (`:755-775`).

`authFetch` is bound to a `Config['Session']` from `@uvdsl/solid-oidc-client-browser` (`src/fetcher.js:26-29`); falls back to plain `fetch` with `credentials: 'include'`.

**LDP-specific constants** (`src/fetcher.js:23-24`):
```js
const DEFAULT_CONTENT_TYPE = 'text/html; charset=utf-8'
const LDP_RESOURCE = '<http://www.w3.org/ns/ldp#Resource>; rel="type"'
```

Every PUT/POST sends `Link: <http://www.w3.org/ns/ldp#Resource>; rel="type"`. Containers are detected by RDF type `ldp:Container`/`ldp:BasicContainer` and walked via `ldp:contains` (`src/dialog.js:2036-2044`, `src/activity.js:324-328`, `src/graph.js:1905-1934`). `containerIRI = url.substr(0, url.lastIndexOf('/')+1)` then `containerIRI + uuid` (`src/doc.js:2189,2303`).

**SPARQL/PATCH:** only in `src/fetcher.js`. Default body N3 (Solid `solid:InsertDeletePatch` form, `:482-501`); SPARQL-Update branch at `:462-477`. `getAcceptPatchPreference` chooses `text/html`/`text/n3`/`application/sparql-update` from server's `Accept-Patch` (`:189-211`).

**MIME types** (`Config.MediaTypes.RDF`, `src/config.js:520`): `text/turtle`, `application/ld+json`, `application/activity+json`, `text/html`, `application/rdf+xml`, `application/trig`. Markup at `:526`: `text/html`, `image/svg+xml`, `text/markdown`. Saves default to `text/html; charset=utf-8`.

### 3.3 Authentication / identity

Supported (from `src/auth.js`):
- **Solid-OIDC** via `@uvdsl/solid-oidc-client-browser` (community client; `package.json:43`). Session instantiated at `src/auth.js:46-49`. Login `loginWithIDP`/`signInWithOIDC` (`:458-499`). Session exposes `authFetch`.
- **WebID dereferencing** without auth: `setUserInfo(url)` fetches profile via `getSubjectInfo` (`:311-367,501-514`).
- **GitHub/Forgejo PAT**: `signInWithGitHubPAT`/`signInWithForgejoPAT` (`:398-436`); tokens travel as `Authorization: Bearer …`/`Authorization: token …` (`src/storage/backend.js:432-434`).

**Not** `solid-auth-client`, **not** `@inrupt/solid-client-authn-browser`. No password login, no plain OIDC, no WebID-TLS code path.

**User identity in document metadata.** `Config.User.IRI` set from WebID (Solid) or `user.html_url` (git-forge) — `src/auth.js:379-380`. Rendered as:
- `<dc:creator>${author.name||author.uri}</dc:creator>` (`src/doc.js:206,283`).
- `<dl><dt>Authors</dt><dd><span rel="dcterms:creator">…</span></dd></dl>` (`src/doc.js:561`).
- `<a property="as:actor" href="${Config.User.IRI}">…</a>` (`src/doc.js:373`).
- ACL writes use `acl:agent <…IRI…>` against an ACL turtle template (`src/fetcher.js:687-705`, `src/dialog.js:3017`).

### 3.4 Data model

RDF-first: the document **is** the graph. Serialised as HTML+RDFa, parsed back via `rdfa-streaming-parser` into an `rdf-ext` dataset, operated on with grapoi-style pointer chaining (`src/graph.js:18-19,135-770`). Libraries: `rdf-ext` (`package.json:71`), `rdfa-streaming-parser` (`:72`). **No** `n3`/`jsonld`/`comunica` packages. JSON-LD where used is hand-rolled (`src/storage.js:74-83,308-319`, `src/activity.js:139`).

**Annotations:** Web Annotation broadly compliant — `oa:Annotation`, `oa:hasBody`/`oa:hasTarget`/`oa:hasSource` (`src/graph.js:375-388`, `src/activity.js:653-664,1029-1106`). LDN delivery to `ldp:inbox`/`as:inbox` discovered on the target document (`src/editor/utils/annotation.js:156-171`, `src/dialog.js:2965-2966`). ActivityStreams wrappers: `as:Announce`, `as:Like`, `as:inReplyTo`, `as:Travel` (`src/activity.js:139,1299`, `src/geo.js:300-302`).

**URI assumptions:** http(s) URLs, dereferenceable, content-negotiable. `getResource` short-circuits `file:` (`src/fetcher.js:255-257`). `init` skips local autosave when `DocumentURL.startsWith('blob:')` (`src/init.js:133-135`). Mixed-content `http:` upgraded via `getProxyableIRI` to a configured proxy when running on `https:` (`src/uri.js:85-115`). Memento immutable saves derive new child IRIs by string-stripping after the last `/` (`src/doc.js:2189-2284`).

### 3.5 Runtime assumptions

**Browser-only.** `webpack.config.cjs:17-32` disables every Node module. Only `process.env.*` references are build-time DefinePlugin substitutions.

**CORS.** Strongly cross-origin friendly: every Solid call sets `credentials: 'include'` (`src/fetcher.js:251,276-278,386-388,521-523,612,622-624`). The user's Pod must serve `Access-Control-Allow-Origin` matching the dokieli origin **plus** `Access-Control-Allow-Credentials: true`, `Access-Control-Allow-Methods` covering OPTIONS/PUT/POST/PATCH/DELETE, and `Access-Control-Expose-Headers` for `Location`, `ETag`, `Link`, `WAC-Allow`, `Accept-Patch`, `Accept-Post`, `Accept-Put`. Fallback logic when preflight fails (`src/fetcher.js:303-318`):

```js
else if (error?.status == 401) { /* retry with credentials */ }
else if (!options.noCredentials && options.credentials !== 'omit') {
  options.noCredentials = true; options.credentials = 'omit';
  return getResource(url, headers, options)
}
```
Followed by a proxy retry through `getProxyableIRI(url, {forceProxy:true})` (`:321-334`).

### 3.6 Pluggability

**The clean seam already exists.** This is recent and very favourable for Logos.

`src/storage/backend.js` defines `class StorageBackend` (`:37-97`) with explicit methods `get`, `head`, `options`, `put`, `post`, `patch`, `delete`, `copy`, `getMultiple`, `save`, plus Solid-specific `putWithConneg`, `patchWithConneg`, `getAcceptPost`, and a `supports(cap)` capability flag from `CAPS = { ACL, LDP, PATCH, POST_CONTAINER, CONNEG }`.

Three concrete backends: `HttpStorage` (plain CRUD with optional `authFetch`, `:99-242`), `SolidStorage` (delegates to `fetcher.js`, `:246-302`), `GitForgeStorage` (GitHub/Forgejo Contents API with branch-locking and sha-based optimistic concurrency, `:304-740`).

A `StorageRouter` (`:742-787`) selects a backend per URL using either explicit `options.backend` or host matching (gitforge first, then default). All write/read entry points go through it. The router is created once in `src/init.js:73-103` and frozen onto `Config.Storage`. Application code consistently calls `Config.Storage.<verb>(...)` — 30+ call sites across `doc.js`, `dialog.js`, `sync.js`, `graph.js`, `activity.js`, `geo.js`, `auth.js`, with **no remaining direct calls** to the `fetcher.js` primitives outside `SolidStorage`.

---

## 4. Direction A — Logos Storage as a Dokieli Backend

### 4.1 Clean seam

**Yes, well-shaped.** Add a `LogosStorage extends StorageBackend` class in `src/storage/backend.js`, register it in `src/init.js:73-103`, and Dokieli's existing call sites — already routed through `Config.Storage.<verb>(...)` — pick it up. The `gitforge` backend is a working precedent for "non-LDP, non-Solid backend with the same interface."

Minimum viable surface to implement: `get`, `head`, `put`, `delete`, `save`, `getMultiple`, plus a `supports()` method returning `false` for `CAPS.ACL`, `CAPS.PATCH`, `CAPS.LDP`, `CAPS.POST_CONTAINER`, `CAPS.CONNEG` (initially) so Dokieli's UI gracefully degrades.

### 4.2 Protocol-level mismatches

| Mismatch | Dokieli expects | Logos provides | Impact |
|---|---|---|---|
| **Addressing** | hierarchical, slash-delimited URLs the client can derive child paths in (`src/doc.js:2189-2342`) | content-addressed CIDs returned by the server | The two `createImmutableResource`/`createMutableResource` call sites pre-compute `containerIRI + uuid`. They should be refactored to read the returned `Location` instead of pre-computing — `src/storage/backend.js:237-241` and `src/dialog.js:2929` already read `Location`. |
| **RDF vs opaque blobs** | text/turtle, text/html, application/ld+json bodies | application/octet-stream blobs (CID = hash of bytes) | Functionally compatible (HTML+RDFa is just bytes), but content-negotiation (`getAcceptPostPreference`/`getAcceptPatchPreference`/`getAcceptPutPreference`) breaks. The `LogosStorage` would just declare which content types it accepts; Dokieli already gates on the server's reply. |
| **Mutable updates** | PATCH (N3 / SPARQL-Update) for in-place graph edits | immutable CIDs — every change produces a new root CID | `LogosStorage.patch` would need read-modify-write (download bytes, mutate locally, re-upload, return new CID). The client would also need a names layer, otherwise updates are unreachable by stable URL. **This is the biggest open design question** for the integration. |
| **WAC ACL** | turtle bodies posted to `${url}.acl` (`src/fetcher.js:663-706`) | no ACL concept; full read/write to anyone reaching the port | `LogosStorage.supports(CAPS.ACL) === false` causes Dokieli's ACL editor (`src/dialog.js` ~1200-1290) to be hidden. No code change required if the UI honours `supports()`. |
| **LDP container traversal** | walks `ldp:contains` to list children (`src/dialog.js:2036-2044`, `src/graph.js:1905-1934`) | flat manifest list via `GET /api/storage/v1/data` | `LogosStorage.getMultiple` would synthesise an LDP-shaped JSON-LD listing from the manifest list, or the listing UI is reskinned for a flat view. |
| **LDN inboxes** | POST annotations to `ldp:inbox`/`as:inbox` discovered in document RDFa | needs a target URL the user controls | If the document IRI is a Logos URL and inbox is another Logos URL, this still works: it is plain HTTP POST. |
| **Memento `mem:original`/`mem:timemap`** | string-derived child IRIs (`src/doc.js:2189-2284`) | each version is a fresh CID | After refactor in row 1, Memento mementos become `cid://...` or `https://logos-gateway/cid/<cid>` URLs returned by `put()`. |
| **CORS & origin** | `credentials: 'include'`, expects `Access-Control-Expose-Headers` on `Location`, `ETag`, `Link`, `Accept-Patch`, etc. | CORS opt-in (`storage/conf.nim:220-227`); plain HTTP at `127.0.0.1:8080` | Storage daemon must run with `--api-cors-origin=<dokieli-origin>` or `'*'`. **Mixed-content blocks any HTTPS-hosted Dokieli from talking to `http://127.0.0.1:8080`** unless the user installs a TLS-terminating reverse proxy or runs Dokieli over HTTP locally. |
| **Auth** | OIDC bearer / cookie / PAT | none | A `LogosStorage` would not call `authFetch`; identity in document RDFa would need to use a non-WebID identifier (DID? `did:key:…`? PeerID?). **Open: Logos has no agreed identity scheme yet.** |

### 4.3 Required client bindings for Dokieli

Dokieli runs in a browser. The only way it can reach Logos storage today is the **HTTP REST API**. There is no JS/WASM SDK in either Logos repo, and `libstorage` is a native library.

Concrete fetch matrix the `LogosStorage` would issue against `http://<host>:8080/api/storage/v1`:
- `GET /data` for `getMultiple`/listing.
- `POST /data` with body, `Content-Type` and `Content-Disposition: attachment; filename="…"` headers, returning CID.
- `GET /data/{cid}` for `get`/`head`.
- `GET /data/{cid}/network/stream` for cross-node fetches.
- `DELETE /data/{cid}` for `delete`.

Optional helpers if needed for UX: `GET /data/{cid}/exists`, `GET /space`, `GET /spr`, `GET /peerid`. No HTTPS, no auth headers, no signed URLs.

### 4.4 Effort estimate: **moderate**

- Trivial pieces: the new backend class, the router wiring, `supports()` flags and gracefully hiding ACL/PATCH UI.
- Moderate pieces: the addressing refactor in `src/doc.js:2189-2342` to consume returned `Location`; `LogosStorage.patch` read-modify-write; manifest-list ↔ LDP-listing translation in `getMultiple`.
- Open-ended pieces: identity story (replacing WebID in `Config.User.IRI`); operator UX for running a local Logos node with CORS opened over HTTP without mixed-content drama; resolvable URL scheme for sharing links to versioned documents.

Realistic order-of-magnitude: ~2–3 weeks engineering for a working PoC against a single local node assuming the addressing and identity questions are explicitly punted (e.g. require Dokieli to run over `http://localhost` so mixed content doesn't bite, and use DID-key-style identifiers).

### 4.5 Concrete next steps

1. **Spike `LogosStorage`** as a new file in `src/storage/backend.js` covering only `get`/`put`/`delete`/`getMultiple`/`save` against `POST/GET/DELETE /api/storage/v1/data[/{cid}]`. Wire it into `init.js`. Validate that a non-RDFa HTML page round-trips.
2. **Refactor `createImmutableResource`/`createMutableResource`** in `src/doc.js:2189-2342` to consume the `Location` header from `put()`/`post()` rather than pre-computing slugged URLs. Verify via `gitforge` (which already returns non-predictable URLs) that this refactor does not regress.
3. **Decide identity.** Punt Solid-OIDC entirely for a Logos backend; emit `did:key:…` or `urn:peerid:…` in `dc:creator`/`as:actor`. Confirm with Logos team that `did:key` is acceptable.
4. **Decide PATCH semantics.** For a first cut, return a thrown `Error` with `error.status` from `LogosStorage.patch` to trigger Dokieli's existing PUT fallback (`src/dialog.js:1785-1813`). Read-modify-write can come later.
5. **Operate** a local `logos-storage-nim` node with `--api-cors-origin=http://localhost:3000`. Document the mixed-content constraint (Dokieli must not be served over HTTPS during development).
6. **Annotation distribution test:** verify LDN POST to a Logos-hosted inbox URL works as a vanilla HTTP POST.

---

## 5. Direction B — Dokieli as a Basecamp Application

### 5.1 Does Basecamp's app model accept Dokieli?

**Not natively.** Basecamp recognises `ui_qml` and legacy Qt C++ plugin types only (`src/PluginLoader.cpp:111-118`, `src/UIPluginManager.cpp:96-101`). There is no `ui_web` enum value, no static-HTML hosting, no embedded HTTP server (zero matches for `QHttpServer`/`QTcpServer::listen`).

**Workaround that exists today:** wrap Dokieli inside a `ui_qml` plugin whose root QML imports `QtWebView` and points at a bundled `index.html`. The flake bundles `pkgs.qt6.qtwebview` and (Linux) `webkitgtk_4_1` (`nix/app.nix:18,21-23,113`); the qmlImportPath includes `${pkgs.qt6.qtwebview}/lib/qt-6/qml` (`:69`); and an external `logos-webview-app` plugin already exists for exactly this pattern (`flake.nix:17,122,141,151`). So:

```qml
import QtWebView
WebView { url: "qrc:/dokieli/index.html" }
```

…inside a properly packaged LGX is the practical Direction-B form factor.

### 5.2 Packaging, sandboxing, lifecycle

- **Packaging:** LGX archive built via `nix bundle --bundler github:logos-co/nix-bundle-lgx` (`README.md:23-31`). Metadata fields: `name`, `view`, `type`, `mainFilePath`, `dependencies`, `installDir`, `capabilities` (`src/UIPluginManager.cpp:86-103`).
- **Sandbox:** Each plugin gets a `QQmlEngine` with `DenyAllNAMFactory` + `RestrictedUrlInterceptor` (`src/PluginLoader.cpp:285-315`). File access whitelisted to `installDir`, the QML entry directory, and the three shared modules (`Theme`, `Controls`, `Icons`).
- **Important caveat for QtWebView**: the WebView is a separate networking stack from the QML engine's `QNetworkAccessManager`. The `DenyAllNAMFactory` does **not** automatically apply to a `WebView`'s underlying WebKitGTK renderer. The `RestrictedUrlInterceptor` is registered on the engine via `engine->addUrlInterceptor` (`src/PluginLoader.cpp:314`) and **may** intercept WebView navigations — this needs runtime verification. **ASSUMPTION: WebView fetch from inside the plugin currently works against arbitrary URLs**, since `logos-webview-app` evidently functions, but this is a security risk worth confirming with the Basecamp team.
- **Lifecycle:** loaded by `package_manager` (`docs/project.md:170-173,401`), shown via `PackageCoordinator.cpp` and `UIPluginManager.cpp`. No workspace persistence today (`docs/project.md:638-640`) — Dokieli would need to autosave to its storage backend on every change since Basecamp will not preserve open tabs across restarts.

### 5.3 Routing storage calls through Basecamp

This is the architecturally most interesting question. Three options:

**Option B-1 — WebView talks directly to a Logos node over HTTP.** Simplest. Dokieli inside the WebView issues `fetch('http://127.0.0.1:8080/api/storage/v1/...')`. Requires the user to run `logos-storage-nim` with `--api-cors-origin='*'` and to load Dokieli over `http://` (mixed content blocks `https://` shells from `http://localhost`). Bypasses the `storage_module` entirely. Not really "an app on top of Basecamp"; Basecamp is just hosting a webview window.

**Option B-2 — WebView talks to `storage_module` via a custom URL scheme.** Register a custom scheme handler (`QWebEngineUrlSchemeHandler` for QtWebEngine, or QtWebView's equivalent) so `logos://cid/<cid>` and `logos://upload` go through the plugin's C++ which calls `storage_module` over Qt Remote Objects. This is the "right" answer architecturally — it routes Dokieli's storage traffic through Logos's native module pipeline, inherits sandboxing, and avoids HTTP/CORS/mixed-content. **Cost:** Dokieli's `LogosStorage` backend has to know about a non-`https://` scheme (`fetch('logos://...')` is illegal in plain browsers but works in Qt's WebView with a registered scheme handler). It also requires Basecamp's plugin to expose a scheme-handler API that QML/WebView plugins can register against — not present today. **Effort: significant Basecamp work first.**

**Option B-3 — Bridge over `window.qt.webChannelTransport`.** Use QtWebChannel to expose a JS proxy object inside the WebView that calls the C++ side (which then calls `storage_module`). Dokieli's `LogosStorage` would call `window.logos.storageGet(cid)` etc. instead of `fetch`. Cleaner than B-1, lighter than B-2, but couples Dokieli to a Basecamp-specific API. **Effort: moderate.**

### 5.4 Identity bridging

Dokieli expects a WebID URL in `Config.User.IRI` (`src/auth.js:379-380`). Basecamp has no user/identity layer (no `webid`/`did`/`wallet` in source). Capability tokens (`app/main.cpp:158-164`) are inter-module authorisation, not user identity. So the integration must either:

- **Side-channel WebID-OIDC** entirely inside the WebView session (the user logs in to a Solid IdP from inside Dokieli; Basecamp does not see the credentials). This re-introduces the Solid stack just for identity, which is ironic if storage is on Logos.
- **Define a Logos identity primitive.** A `did:key:…` derived from the libp2p PrivateKey (`storage.nim:91-97`) is a candidate. Dokieli would need to accept non-`https://` IRIs in `Config.User.IRI` — the URI sanitisers in `src/utils/sanitization.js` and `src/uri.js:85-115` may currently block these.
- **Dual identity.** Dokieli holds a WebID for Solid documents and a `did:key` for Logos documents, switched per active backend.

### 5.5 Effort estimate: **hard**

Compounding factors:
- Basecamp lacks a web-app plugin type today — needs either a wrapper QML plugin or an enum addition + dispatch code in `PluginLoader`/`UIPluginManager`.
- QtWebView/WebKitGTK on Linux is feature-restricted vs Chromium and has known gaps around modern JS/WebAPI; ProseMirror, ES module bundles, IndexedDB usage in `src/storage.js` need runtime validation. **ASSUMPTION**: not yet verified.
- WebExtension shipping form is irrelevant inside a QtWebView (no extension APIs).
- No identity layer; needs design.
- No persistent workspace; needs Dokieli to autosave aggressively or live with losing state.
- The "right" routing answer (B-2) requires changes to Basecamp's plugin API.

A no-frills B-1 form factor is achievable in ~1–2 weeks but is not really integration — it is just a kiosk WebView pointing at a separately running daemon. A real integration (B-2 or B-3) is multi-month.

### 5.6 Concrete next steps

1. **Build a minimal `logos-webview-app`-style plugin** that loads `https://dokieli.org` (or a bundled copy) inside QtWebView; verify that ProseMirror + `idb-keyval` + the WebExtension-detection branches all degrade gracefully when running in a non-extension same-origin context.
2. **Run Dokieli in QtWebView/WebKitGTK** end-to-end with a Solid pod backend before involving Logos at all — to prove the WebView is good enough.
3. **Decide routing model.** Pick B-1 (HTTP loopback), B-2 (custom scheme handler), or B-3 (QtWebChannel bridge). B-3 is the highest-leverage middle ground.
4. **Coordinate with Basecamp on a `ui_web` plugin type.** Without it, packaging is awkward — a `ui_qml` shell whose only job is to host a WebView is all overhead.
5. **Define the identity story.** This blocks both directions but bites Direction B harder because it must round-trip through the WebView session.

---

## 6. Comparison and Recommendation

### 6.1 Side-by-side feasibility table

| Dimension | Direction A — Logos as Dokieli backend | Direction B — Dokieli inside Basecamp |
|---|---|---|
| **Clean integration seam exists today** | Yes — `StorageBackend` interface, three precedent backends, single router wiring point in `src/init.js:73-103` | No — `ui_qml`/legacy only; no `ui_web` type, no embedded HTTP server |
| **First-step deliverable** | New `LogosStorage` class + `init.js` change | LGX plugin wrapping QtWebView, loading bundled Dokieli |
| **Largest protocol mismatch** | CID vs hierarchical URL addressing (resolvable in `src/doc.js:2189-2342`) | Storage call routing (HTTP loopback vs Qt scheme handler vs WebChannel bridge) |
| **Identity gap** | Replace WebID for Logos paths (e.g., `did:key`) | Same identity gap, but worse — no Basecamp identity primitive exists |
| **Browser/runtime risk** | Runs in vanilla browser → low risk | Runs in QtWebView/WebKitGTK → unverified compatibility with ProseMirror, ES modules, IndexedDB, service worker |
| **CORS / network constraints** | Operator must run local node with `--api-cors-origin`; mixed-content if Dokieli is HTTPS | Plugin sandbox (`DenyAllNAMFactory`) does not apply to WebView fetches; behaviour with `RestrictedUrlInterceptor` unverified |
| **Required upstream changes** | None to Logos storage; ~2 files in Dokieli | Likely a `ui_web` plugin type + scheme handler API in Basecamp |
| **License compatibility** | OK (Apache-2.0 / MIT both sides) | OK |
| **Maturity risk** | `logos-storage-nim` self-declared pre-alpha; HTTP API surface stable enough | Basecamp is experimental; QtWebView path is the sole web on-ramp |
| **Effort** | Moderate (~2–3 weeks PoC) | Hard (~weeks for kiosk; months for real integration) |
| **Information unlocked** | Validates the protocol from a real client; surfaces CID/PATCH/ACL gaps | Validates packaging story; doesn't surface protocol issues until Direction A is done |

### 6.2 Lower-risk first step

**Direction A.** Reasoning:

1. It runs in a vanilla browser, decoupling the integration question from the QtWebView/WebKitGTK runtime risk (which is significant and not yet measured).
2. It exercises the Logos storage HTTP API from a non-trivial client — currently the only consumer is `logos-storage-module` over the C ABI in-process. Real browser traffic exposes CORS, content-disposition, range, and error-shape gaps early.
3. It produces a reusable `LogosStorage` class. If Direction B is later pursued, the same backend code runs unchanged inside the embedded WebView — Direction B becomes "bring your own Dokieli build with `LogosStorage` already enabled."
4. It does not require any change to Logos Basecamp or Logos storage. It's confined to Dokieli, where the abstraction is freshly built and idiomatic.
5. It is testable end-to-end on a developer laptop: `nim build` the storage node, `npm run build` Dokieli, point to localhost.

Direction B has nothing to test with until Direction A's `LogosStorage` exists, otherwise the embedded Dokieli would be talking to a Solid pod from inside a Basecamp window — which is a packaging exercise, not an integration.

### 6.3 Open questions blocking confidence

1. **Identity:** does Logos plan to standardise on `did:key`/`did:web`/peer-id-based identifiers? Without a decision, both directions stub identity.
2. **Mutable document semantics on a CID store:** is a names/IPNS-like layer expected, or are documents intentionally immutable with each save producing a new top CID and external indexing handling "current version"?
3. **CORS, TLS and mixed content:** is the recommended deployment a local-only `http://127.0.0.1:8080` node, a TLS-terminating reverse proxy, or something else? This determines whether an HTTPS-hosted Dokieli can ever talk to Logos storage in a non-Basecamp context.
4. **QtWebView capability on Linux:** does WebKitGTK 4.1 (`nix/app.nix:7`) render Dokieli's editor stack (ProseMirror + ES module bundle + service worker registration logic in `src/init.js:105-119`) without crashes or feature gaps? Direction B is partly blocked on this answer.
5. **Custom URL scheme handlers in Basecamp:** would the Basecamp team accept exposing a `QWebEngineUrlSchemeHandler`-style API to plugins? Without it, Direction B's only viable form factor is HTTP loopback (Option B-1).
6. **Fork strategy:** `logos-storage-nim` carries unrenamed Codex artefacts (`codexdht` package, `https://api.codex.storage` doc link, copyright headers). Will the rename complete soon, and will the public API URL prefix stabilise before integration code commits to it?

### 6.4 Risks

- **Protocol churn.** `logos-storage-nim` is pre-alpha by self-declaration (`README.md:5`); `apiCorsAllowedOrigin` and the `/api/storage/v1` URL prefix are subject to change. Pin a commit and gate Dokieli's `LogosStorage` on a server-version check.
- **Abandoned dependencies.** Dokieli's Solid-OIDC client `@uvdsl/solid-oidc-client-browser` is a community single-maintainer package; if Direction A drops Solid-OIDC for Logos paths, this risk is reduced. `rdf-ext` and `rdfa-streaming-parser` are healthy.
- **Stripped Codex marketplace.** `nim-codex`'s payment/erasure-coding stack appears removed in the Logos fork. Any Dokieli feature that assumed Codex incentives (none today) would be blocked.
- **Identity vacuum.** Both repos have zero authentication primitives. A real deployment must add at least token-based authorisation; otherwise any local network attacker who can reach `127.0.0.1:8080` can wipe the user's storage.
- **License compatibility.** Both Logos repos and Basecamp dual-license MIT/Apache-2; Dokieli is Apache-2.0. No conflict.
- **Maintenance burden of a custom Dokieli fork.** If Direction B requires forking Dokieli (e.g., for a `LogosStorage` not landed upstream, or for Qt-bridge code), Logos takes on maintenance against an actively developed upstream (`3a907bd`, "Better handling of 404 in getACLResourceGraph" is a recent commit). Push the `LogosStorage` backend upstream — it is additive and non-controversial given the existing `gitforge` precedent.
- **QtWebView gaps.** Real risk for Direction B; needs measurement before committing. WebKitGTK lags Blink by ~12-18 months on Web platform features in some areas (CSS Container Queries, modern Service Worker behaviours).

---

## Appendix — Repo commit SHAs inspected

| Repo | Branch | HEAD SHA | HEAD subject | Tag (if any) |
|---|---|---|---|---|
| `logos-storage/logos-storage-nim` | (default) | `cf2f40f5591ce9e75e49b5c7e70d2ec53d296cfd` | chore: update nim 2.2.10 (#1425) | latest tag `v0.3.2` |
| `logos-co/logos-basecamp` | (default) | `b44a5cf4787fc3a5c08e157227e791aee4d48064` | bump dependencies (#183) | none |
| `logos-co/logos-storage-module` | (default) | `b1d82a32c1ba27e20d07b7ed8555fd45b02adb4e` | chore: move API tutorial into dedicated doc page, add ToC (#30) | none |
| `dokieli/dokieli` | (default) | `3a907bd314d213baab5577e99495ccd49e77223b` | Better handling of 404 in getACLResourceGraph | none |

All repos cloned with `--depth=50` on 2026-05-09. All file/line citations in this report refer to these SHAs. Where claims could not be verified from source they are tagged `ASSUMPTION` inline.

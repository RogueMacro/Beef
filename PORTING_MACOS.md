# Porting the Beef IDE to macOS (Apple Silicon)

Running notes for getting `IDE/` (BeefIDE) to build and run natively on macOS arm64.
Base: commit `6086538b` (master, Nov 2026). Host: macOS 15 (Darwin 24.6), arm64,
Homebrew in `/opt/homebrew`, `llvm@22` 22.1.8, `sdl3` 3.4.20, cmake 4.4, ninja 1.13.

## Build pipeline map

`./bin/build.sh [ide] [package] [no_ffi] [clean]`

1. **Native libs (CMake)** — two trees at repo root:
   - `jbuild_d/` = `CMAKE_BUILD_TYPE=Debug` → `jbuild_d/Debug/bin/{BeefBoot, libBeefRT_d.a, libBeefySysLib_d.a, libIDEHelper_d.a, libhunspell.dylib}`
   - `jbuild/` = `RelWithDebInfo` → `jbuild/Release/bin/{BeefBoot, libBeefRT.a, libBeefySysLib.a, libIDEHelper.a, libhunspell.dylib, ImgCreate}`
   - `ide` adds `-DBF_ENABLE_SDL=1` (both trees) and `-DBUILD_IMGCREATE=1` (release tree only).
   - On Darwin with brew: `LIBRARY_PATH`/`LD_RUN_PATH` = `$(brew --prefix llvm@22)/lib`.
     The local (uncommitted, user-authored) edit to `build.sh` also passes
     `-DCMAKE_PREFIX_PATH=$BREW_PREFIX -DCMAKE_CXX_FLAGS=-I$BREW_PREFIX/include` so SDL3 headers are found.
2. **Symlinks** into `IDE/dist/` and `BeefLibs/Beefy2D/dist/` for the static libs + `libhunspell.$LIBEXT`.
3. **Bootstrap**: `BeefBoot` compiles `BeefBuild_bootd` / `BeefBuild_boot` straight from sources
   (`--linkparams` uses `IDE/dist/IDEHelper_libs[_d].txt`, which on mac is `-lLLVM-22`).
4. **BeefBuild**: `BeefBuild_boot[d] -proddir=../../BeefBuild` → `IDE/dist/BeefBuild[_d]`, then runs `IDEHelper/Tests`.
5. **IDE** (only with `ide`): `cd IDE/dist && ./BeefBuild -clean -proddir=../ -config=Debug|Release`
   → `IDE/dist/BeefIDE_d` / `BeefIDE`, then symlinks `images/ImgCreate`.

BeefBuild picks the host platform automatically; on mac the config platform name is `macOS`
and the Beef define is `BF_PLATFORM_MACOS`. If a project has no `[Configs.<cfg>.macOS]` section
it silently uses defaults (that's why the IDE "builds" at all today).

### Fast iteration
Native libs only need rebuilding when C++ changes. For Beef-only changes:
```sh
cd IDE/dist && LIBRARY_PATH=$(brew --prefix llvm@22)/lib ./BeefBuild -proddir=../ -config=Debug   # a few seconds
```

## Findings (verification of the initial notes)

Confirmed:
- `./bin/build.sh ide` → native libs + BeefBuild OK, `BeefIDE_d` fails with **43 errors**, all
  `SaveFileDialog` / `OpenFileDialog` / `FolderBrowserDialog` (lines matched the notes;
  plus `IDEApp.bf:1135` was already in the list).
- Dialogs: `FileDialog.bf`, `OpenFileDialog.bf`, `FolderBrowserDialog.bf` are `#if WINDOWS / #elif LINUX`
  with no `#else`; `SaveFileDialog.bf` has an `[Error]` stub `#else`. `CommonDialog` and `DialogResult`
  live in `FileDialog.bf`.
- `SdlBFApp.cpp:334-341`: GL 3.2 core, **no** `SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG`, and
  `SDL_GL_CONTEXT_DEBUG_FLAG` is OR'd into the `SDL_GL_CONTEXT_PROFILE_MASK` value (should go in
  `SDL_GL_CONTEXT_FLAGS`). Numerically DEBUG_FLAG == PROFILE_CORE == 1, so it's harmless today but wrong.
- `IDEHelper/CMakeLists.txt` only enables LLDB under `UNIX AND NOT APPLE`.

Corrections / new facts:
- **SDL3 is not linked; it's `dlopen`ed at runtime** (`017b27f6 Use BfpDynLib to load SDL3`).
  `BfpDynLib_Load("SDL3")` tries `SDL3`, `SDL3.so`, `SDL3.dylib`, `libSDL3...`. On Apple Silicon,
  `/opt/homebrew/lib` is **not** in dyld's default fallback path, so this will fail at runtime unless we
  add a search path (or bundle `libSDL3.dylib` next to the exe). → Open problem for task 5.
- **All GL entry points come from `SDL_GL_GetProcAddress`**, so the IDE needs no `-framework OpenGL`
  or `-framework Cocoa` at link time (SDL pulls those in itself).
- **`BeefySysLib/platform/darwin/PlatformApp.h` hard-codes `typedef HeadlessApp PlatformBFApp;`**
  (SDL lines commented out). Even with `BF_ENABLE_SDL`, macOS would get a headless app. Must mirror
  `platform/linux/PlatformApp.h`. (C++ change → needs native rebuild.)
- `BeefySysLib/CMakeLists.txt` Apple branch globs `platform/darwin/BFPlatform.cpp`, which doesn't exist
  (glob silently matches nothing; harmless).
- On macOS `$(LinkFlags)` expands to `./libBeefRT[_d].a -Wl,-rpath -Wl,@executable_path`
  (`IDEApp.bf` ~11492), so the Linux64 pattern `$(LinkFlags) libIDEHelper_d.a libBeefySysLib_d.a ...` carries over.
- `BeefLibs/curl/BeefProj.toml` only adds `-lcurl` for Linux64; macOS needs the same (system libcurl).
- The IDE's `[Dependencies]` include `curl`, so curl's project configs matter for linking.

## Linux IDE port history (pattern reference)

- `8f9143a2` (2024-09) xdg-desktop-portal dialogs for Linux (`FileDialog.bf` `#elif BF_PLATFORM_LINUX`).
- `49f33598` (2025-05) "Fix Linux IDE build": adds `Linux64` sections to `IDE/BeefProj.toml`,
  `IDE/BeefSpace.toml`, `Beefy2D/BeefProj.toml`, plus CMake/build.sh tweaks. Our macOS configs mirror this.
- `8b099203` (2025-11) fontconfig font cache in `Font.bf`.
- 2026: many `SDL ...` commits (HiDPI `bd03c66d`, dlopen SDL `017b27f6`, clipboard, cursors, MSAA).

## Task log

### Task 1 — stub dialogs (done)
- Added `#elif BF_PLATFORM_MACOS` to `FileDialog.bf` (`DialogResult`, `CommonDialog`, `FileDialog`),
  `OpenFileDialog.bf`, `SaveFileDialog.bf`, `FolderBrowserDialog.bf`. API = the Linux surface
  (Title, InitialDirectory, FileName(s), Multiselect, ValidateNames, DefaultExt, Get/SetFilter,
  ShowReadOnly, OverwritePrompt, FolderKind, SelectedPath).
- `CommonDialog.ShowDialog` calls `protected virtual Result<DialogResult> RunDialog(INativeWindow owner)`,
  which returns `.Cancel` for now. Native NSOpenPanel/NSSavePanel work only has to override/replace `RunDialog`.
- `DialogResult` uses the Windows values (None=0, OK=1, Cancel=2); Linux's differ but nothing depends on them.
- Result: 0 compile errors. Next failure is the link: 333 undefined symbols (Debugger_*, BfCompiler_*,
  Gfx_*, BFApp_*, BFWindow_*, SpellChecker_*, HTTP_*, fts_fuzzy_match, ...) = IDEHelper + BeefySysLib not
  linked, and output lands in `IDE/build/Debug_macOS/IDE/IDE` → no macOS config in `IDE/BeefProj.toml`.

### Task 2 — macOS project configs (done)
- `IDE/BeefProj.toml`: `Debug.macOS` / `Release.macOS`, modelled on Linux64:
  `$(LinkFlags) ./libIDEHelper[_d].a ./libBeefySysLib[_d].a ./libhunspell.dylib $(Var IDEHelperLibs)`.
  (`$(LinkFlags)` already contributes `./libBeefRT[_d].a -Wl,-rpath -Wl,@executable_path`.)
  Release reads `IDEHelper_libs.txt` (Linux64 Release reads the `_d` file — likely a copy/paste slip upstream; left alone).
- `IDE/BeefSpace.toml`: every `*.Linux64` section duplicated as `*.macOS` (Debug, Release, Debug-IDE,
  Debug2, Paranoid, Test, Debug3, Debug_NoDeps).
- `BeefLibs/Beefy2D/BeefProj.toml`: `Debug.macOS` / `Release.macOS` mirroring Linux64, including
  `CopyToDependents` of the `.a`. Safe: both ends are symlinks to the same jbuild file and the copy only
  happens when src mtime > dest mtime, so it is a no-op.
- `BeefLibs/curl/BeefProj.toml`: `-lcurl` for macOS (links system `/usr/lib/libcurl.4.dylib`).
- No frameworks needed: SDL3 is dlopen'ed and GL comes through `SDL_GL_GetProcAddress`.
- Result: `BeefIDE_d` and `BeefIDE` link. `otool -L`: libcurl (system), `@rpath/libhunspell.dylib`,
  `/opt/homebrew/opt/llvm@22/lib/libLLVM.dylib` (absolute brew path → not relocatable; fine for dev),
  libc++, libSystem. rpath `@executable_path`.
- Gotcha: running the IDE step by hand needs `LIBRARY_PATH=$(brew --prefix llvm@22)/lib`, otherwise
  `ld: library 'LLVM-22' not found` (build.sh exports it).

### Task 3 — `build.sh ide` on Darwin (done)
- `BeefySysLib/platform/darwin/PlatformApp.h`: now mirrors Linux (`SdlBFApp` under `BF_ENABLE_SDL`,
  else `HeadlessApp`).
- `BeefySysLib/CMakeLists.txt`: on Apple with `BF_ENABLE_SDL`, `find_path(SDL3_INCLUDE_DIR SDL3/SDL.h ...)`
  (hints `/opt/homebrew/include`, `/usr/local/include`, plus `CMAKE_PREFIX_PATH`) → `include_directories(SYSTEM ...)`.
  Fails with a clear message if SDL3 isn't installed. Verified in a scratch tree configured *without*
  the local `-I$BREW_PREFIX/include` flag.
- ImgCreate already built; the symlink and IDE steps at the end of `build.sh` work unchanged on macOS.
- Result: `./bin/build.sh ide` exits 0. IDEHelper tests: 201/201 + 1/1 in both Debug and Release.
- `CMake Warning (unused-cli): BF_ENABLE_SDL` is pre-existing and harmless (it's tested with `DEFINED`).

### Task 4 — Linux-only code audit

| Site | What it does on Linux | macOS plan | Status |
| --- | --- | --- | --- |
| `Beefy2D/src/gfx/Font.bf` 269/456 | fontconfig (`libfontconfig.so`, AllowFail) builds a family-name → file map for system fonts | Without it the map is empty, but the IDE still works: "Segoe UI" falls through `AddFontFailEntry` to bundled `IDE/dist/fonts/NotoSans-*.ttf`, code font is bundled SourceCodePro. Lost: emoji/symbol fallbacks and user-chosen system fonts by name. Options: (a) CoreText (`CTFontManagerCopyAvailableFontURLs` + descriptor attributes) — needs Apple-framework FFI from Beef; (b) reuse the fontconfig path with Homebrew `fontconfig` (needs the same dyld search-path trick as SDL); (c) scan `/System/Library/Fonts`, `/Library/Fonts`, `~/Library/Fonts` by filename (cheap, approximate). | **Needs decision** (recommend CoreText, tied to the "how to call Apple APIs" decision) |
| `IDEApp.bf` 126 / 13819 | embeds `Resources/beeflang.png`, `BFApp_RegisterAppIcon` → `SDL_SetWindowIcon` | Same on macOS (SDL sets the Dock icon) | Done (`0278d44c`) |
| `IDEApp.bf` 137 | platform names | already had `BF_PLATFORM_MACOS` → `macOS` | No change |
| `Workspace.bf` 147 | `GetHostPlatform` | already has `BF_PLATFORM_MACOS` | No change |
| `IDEApp.bf` 13577, `BeefConfig.bf` 228, `WelcomePanel.bf` 17/48/96/105 | `LINUX_PACKAGE` only: user data in `~/.config/beeflang/`, managed libs + samples copied there | Packaging-only. macOS equivalent is `~/Library/Application Support/BeefLang/` for a `.app` build | Skip until `.app` packaging |
| `ProjectPanel.bf` 3239 | "Open folder" via D-Bus `org.freedesktop.FileManager1.ShowFolders` | `/usr/bin/open "<dir>"` | Done (builds; not click-tested) |
| `StartupPanel.bf` 240 | open recent workspace's folder (same D-Bus call) | `/usr/bin/open "<dir>"` | Done (builds; not click-tested) |
| `StartupPanel.bf` 463 | open docs URL via `org.freedesktop.portal.OpenURI` | `/usr/bin/open "<url>"` | Done (builds; not click-tested) |

Also noticed (not Linux-only, but relevant later): "Open in terminal" spawns `mSettings.mWindowsTerminal`
(Windows default), `TerminalPanel`/`ConsolePanel` are created only on Windows.

### Task 5 — window on screen (partly done)
What I did:
- `SdlBFApp.cpp`: after the default `dlopen`, try `<exe dir>/libSDL3.dylib`, `/opt/homebrew/lib/`,
  `/usr/local/lib/`. Verified with `vmmap`: loads `/opt/homebrew/Cellar/sdl3/3.4.20/lib/libSDL3.0.dylib`.
- GL context: `PROFILE_MASK = CORE`, `CONTEXT_FLAGS = FORWARD_COMPATIBLE (Apple) | DEBUG (_DEBUG)`.
  Note for Linux: debug builds of BeefySysLib now really get a debug context; the existing
  `glDebugMessageCallback` only logs, so the only visible change is possible extra GL log output.
- corlib `Socket` (`b595ed18`): macOS used Linux `FIONBIO` (0x5421, Darwin is 0x8004667e) and Linux errno values
  (`WouldBlock` 11, Darwin 35). Also `ioctl` was declared non-variadic, which is wrong on Apple arm64
  (variadic args go on the stack). Effect before the fix: any `Blocking = false` socket stayed blocking; the IDE's
  MCP server blocked the main loop in `accept()`, and treated EAGAIN as fatal.

What works (verified with `BeefIDE_d -mcp=<port> -deterministic -workspace=<dir>` and the IDE's own MCP tools):
- Launches, creates a 1083×841 pt window (2166×1626 px — Retina picked up; first-run logic set UI `Scale = 200`).
- Shaders compile under the 3.2 core context (shader errors are `BF_FATAL`, none hit).
- Main loop runs at ~60 frames/s. UI tree is built: Workspace (ProjectPanel), Startup, Output, Watch, etc.
- Opening a workspace, the project tree (`get_workspace_tree`), **Clean + Build** inside the IDE
  (126 modules, links, exe prints "Hello from Beef on macOS"), and **Start Without Debugging**.

What doesn't work yet / not verified:
- **I couldn't look at the pixels myself.** No Screen Recording permission for `screencapture`; the MCP
  `screenshot` tool's default path calls `GLRenderDevice::CreateRenderTarget` = `NOT_IMPL` (throws, aborts
  the IDE; upstream, Linux too). `screen=true` uses `glReadPixels` on the back buffer after the swap, which is
  undefined on macOS and comes back black. → **Needs a human look**, or implement `CreateRenderTarget` (FBO).
- **Start Debugging** aborts the IDE: with no LLDB on Apple, `DebugManager` falls back to `GDBDebugger`
  (Homebrew has `/opt/homebrew/bin/gdb`), and its `Detach()` calls `BfpSpawn_Kill`, which is `NOT_IMPL` in
  `posix/PosixCommon.cpp:2310`. Part of the deferred debugger work; a cheap guard would be to not offer GDB on macOS.
- File dialogs return Cancel (stubs).
- The "built …" time on the IDE start line shows UTC labelled as local (corlib `ToLocalTime` on macOS?).
- `libLLVM.dylib` is linked by absolute Homebrew path (fine for dev, matters for `.app` packaging).

## Decisions

- Uncommitted user edit to `bin/build.sh` (re-indent + brew `CMAKE_EXTRA_ARGS`) is left alone, not
  committed by me. After `181c1af9`, its `-DCMAKE_CXX_FLAGS=-I$BREW_PREFIX/include` should no longer be
  needed: a scratch tree configured with only `-DBF_ENABLE_SDL=1 -DLLVM_DIR=...` compiled BeefRT, BeefySysLib,
  IDEHelper and hunspell fine; the only failure was BeefBoot's `-lLLVM-22` link, which the *original*
  build.sh already handles by exporting `LIBRARY_PATH` on Darwin. So upstream build.sh + these commits should
  suffice (not yet re-run end-to-end with your edit reverted).
- Dialog stubs follow the Linux API surface; the native work only needs to implement `RunDialog`.
- SDL stays dlopen'ed (no link-time dependency), with Homebrew prefixes as a fallback search path.

## Open problems / next

1. Visual check of the window (or implement GL `CreateRenderTarget` so MCP screenshots work).
2. Native dialogs (NSOpenPanel/NSSavePanel) — needs the "how to call AppKit" decision.
3. System font lookup (CoreText) — same decision.
4. Debugger: LLDB on Apple; meanwhile avoid the GDB fallback crash (`BfpSpawn_Kill` NOT_IMPL).
5. Non-variadic `extern` declarations of variadic C functions (`ioctl`, `fcntl`, `open`, `printf`...) are broken
   on Apple arm64. Socket's is fixed; worth a corlib-wide audit.
6. `ToLocalTime` on macOS; `LIBRARY_PATH` needed for hand-run IDE builds.

## Build commands that work

```sh
brew install llvm@22 sdl3 ninja cmake
./bin/build.sh ide        # full: native libs + BeefBuild + tests + BeefIDE_d + BeefIDE (exit 0)
cd IDE/dist && LIBRARY_PATH=$(brew --prefix llvm@22)/lib ./BeefBuild -proddir=../ -config=Debug   # IDE only
cd IDE/dist && ./BeefIDE_d                                    # run
cd IDE/dist && ./BeefIDE_d -mcp=4310 -deterministic -workspace=/path/to/ws   # run + drive via MCP (curl JSON-RPC to /mcp)
```

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
cd IDE/dist && ./BeefBuild -proddir=../ -config=Debug      # ~seconds to a few minutes
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

## Decisions

- Uncommitted user edit to `bin/build.sh` (re-indent + brew `CMAKE_EXTRA_ARGS`) is left alone and not
  committed by me unless asked.

## Open problems

- SDL3 dylib search path at runtime (see above).
- `darwin/PlatformApp.h` → SdlBFApp when `BF_ENABLE_SDL`.
- GL forward-compat flag / debug flag placement.
- Debugger (LLDB on Apple) — deferred.

## Build commands that work

```sh
./bin/build.sh            # BeefBuild only: OK
./bin/build.sh ide        # native libs + BeefBuild OK; IDE step fails (43 errors) at 6086538b
cd IDE/dist && ./BeefBuild -proddir=../ -config=Debug    # IDE step only
```

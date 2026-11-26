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
- `IDEHelper/CMakeLists.txt` only enables LLDB under `UNIX AND NOT APPLE`. (Fixed in Task 10.)

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
| `Beefy2D/src/gfx/Font.bf` 269/456 | fontconfig (`libfontconfig.so`, AllowFail) builds a family-name → file map for system fonts | Without it the map is empty, but the IDE still works: "Segoe UI" falls through `AddFontFailEntry` to bundled `IDE/dist/fonts/NotoSans-*.ttf`, code font is bundled SourceCodePro. Lost: emoji/symbol fallbacks and user-chosen system fonts by name. Options: (a) CoreText (`CTFontManagerCopyAvailableFontURLs` + descriptor attributes) — needs Apple-framework FFI from Beef; (b) reuse the fontconfig path with Homebrew `fontconfig` (needs the same dyld search-path trick as SDL); (c) scan `/System/Library/Fonts`, `/Library/Fonts`, `~/Library/Fonts` by filename (cheap, approximate). | Done: CoreText shim (`fd26c3c1`), see Task 7 |
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
- ~~Visual check~~ — user confirmed the window draws correctly (2026-11-22).
- **I couldn't look at the pixels myself.** No Screen Recording permission for `screencapture`; the MCP
  `screenshot` tool's default path calls `GLRenderDevice::CreateRenderTarget` = `NOT_IMPL` (throws, aborts
  the IDE; upstream, Linux too). `screen=true` uses `glReadPixels` on the back buffer after the swap, which is
  undefined on macOS and comes back black. → **Needs a human look**, or implement `CreateRenderTarget` (FBO).
- **Start Debugging** aborts the IDE: with no LLDB on Apple, `DebugManager` falls back to `GDBDebugger`
  (Homebrew has `/opt/homebrew/bin/gdb`), and its `Detach()` calls `BfpSpawn_Kill`, which is `NOT_IMPL` in
  `posix/PosixCommon.cpp:2310`. Part of the deferred debugger work; a cheap guard would be to not offer GDB on macOS.
- ~~File dialogs return Cancel (stubs).~~ Native now, see Task 6.
- ~~The "built …" time on the IDE start line shows UTC labelled as local~~ — fixed, see Task 13.
- `libLLVM.dylib` is linked by absolute Homebrew path (fine for dev, matters for `.app` packaging).

### Task 6 — native file dialogs (done, needs hands-on testing)
- Decision (user, 2026-11-22): Apple APIs go through small shims in `BeefySysLib/platform/darwin`,
  exported with `BF_EXPORT`, not through the Objective-C runtime from Beef.
- `BeefySysLib/platform/darwin/DarwinDialogs.mm` (ARC): `BFFileDialog_Show(kind, flags, title, initialDir,
  defaultName, filter, &outPaths)` → -1 error / 0 cancel / 1 OK; paths come back NUL-separated, double-NUL
  terminated; `BFFileDialog_FreeResult` frees them. Runs `NSOpenPanel`/`NSSavePanel` `runModal` on the calling
  (main) thread, then gives key focus back to the previous window.
- Filters: the Windows-style string goes through unchanged. Several filters → "Format:" popup accessory, first
  selected (like Windows). Open panels match with `fnmatch(FNM_CASEFOLD)` in `panel:shouldEnableURL:`, so exact
  names (`BeefProj.toml`) work; save panels get the filter's `*.ext` as `allowedContentTypes` (with
  `allowsOtherFileTypes`). Folder dialogs ignore filters. NSSavePanel always asks before overwriting.
- corlib (`FileDialog.bf` macOS branch): `CommonDialog.RunNativeDialog`, `FileDialog.RunDialog` (FileName may carry a
  directory, used when `InitialDirectory` isn't set; `DefaultExt` appended on save when the name has no extension;
  `DefaultExt` is now stored as an owned string), `SaveFileDialog.IsSaveDialog`, `FolderBrowserDialog.RunDialog`.
- Linking: corlib's macOS dialogs now reference BeefySysLib symbols, so a program using them must link BeefySysLib
  and `-framework AppKit -framework UniformTypeIdentifiers`. Beefy2D's macOS configs add the frameworks. A plain
  corlib-only program that uses the dialogs gets a link error (before this it didn't compile at all).
- Verified: shim compiles warning-free; IDE links; "Open File" brings up a modal panel window (CGWindowList shows a new
  800×448 window at the modal layer). **Not verified:** clicking through (needs a human): picking files, multi-select,
  the Format popup, save with/without extension, folder pick, Cancel, and that keyboard state is sane afterwards.

### Task 7 — system fonts via CoreText (done)
- `BeefySysLib/platform/darwin/DarwinFonts.cpp` (plain C++, CoreText is a C API): `BFFont_EnumSystemFonts(callback,
  userData)` walks `CTFontCollectionCreateFromAvailableFonts`, reports family, style, file path and "regular"
  (no bold/italic trait, weight ≈ 0). Families starting with `.` (private UI fonts) are skipped.
- Faces inside `.ttc` collections get `path@index` (FTFont already parses that on every platform). The index comes from
  matching the PostScript name against `CTFontManagerCreateFontDescriptorsFromURL`, cached per file. Checked against
  FreeType: 841 TTC faces, family/style match on all but one (Galvji names "Oblique" vs "Italic"). The private
  `PingFangUI.ttc` lists more descriptors than faces, so indices ≥144 there don't open; nobody should pick those.
- `Font.bf`: `#elif BF_PLATFORM_MACOS` in `BuildFontNameCache` calls it; `AddSystemFont` uses the same naming as the
  fontconfig path. Beefy2D's macOS configs add `-framework CoreText`.
- The bootstrap BeefBuild (BeefBoot compiles Beefy2D sources directly, no toml) also references it, so
  `bin/build.sh`'s Darwin `LINKOPTS` gained `-framework CoreText -framework CoreFoundation`. Full
  `./bin/build.sh ide` passes again (tests 201/201 + 1/1, Debug and Release).
- Verified: with editor `Fonts = ["Menlo", "?Apple Symbols"]` the IDE opens `/System/Library/Fonts/Menlo.ttc` and
  `Apple Symbols.ttf` (lsof). UI fonts still come from bundled Noto via the "Segoe UI" fail entry, as on Linux.
- Not done: mapping the IDE's default alternates (`?Segoe UI Symbol/Historic/Emoji`) to Apple equivalents. "Apple
  Symbols" would be easy; "Apple Color Emoji" is an sbix color font and I haven't checked Beefy's FreeType path
  handles it.

### Task 8 — GL render targets (done)
- `GLRenderDevice::CreateRenderTarget`, `GLTexture::PhysSetAsTarget`, `GLTexture::GetBits` were `NOT_IMPL`
  (shared SDL backend, so Linux too). Now: texture + one FBO per GL context (FBOs aren't shared; the main and
  transparent-window contexts are different), optional depth / depth-stencil renderbuffer. Formats per the
  `RenderTargetFlags` bits DX uses. Not yet: Mipmaps, Shared, UnorderedAccess, MSAA (renders single-sampled).
- Orientation: texture targets use a flipped ortho projection so texel row 0 = image top (same as uploaded
  textures, so drawing a render target as an image isn't upside down, and `GetBits` reads top-down with no
  flip). Scissor isn't y-flipped for textures; `glFrontFace` switches to CW to keep culling right.
- `PhysSetRenderState` takes projection/scissor size from the bound target (`mPhysTargetWidth/Height`) instead of
  `mPhysRenderWindow`; a target change sets `mPhysTargetDirty` so the next batch reapplies its state even if the
  render state object is the same (`DrawToRenderTarget` sets the default state *before* binding the target).
- Window targets rebind FBO 0 only after a texture target was bound (desktop GL only; ES2 keeps `NOT_IMPL`).
- Verified via MCP: default `screenshot` (offscreen) renders the full IDE correctly (orientation, colors, clipping,
  text); `all=true` composites the main window plus an open File menu; repeated captures fine; `pixel_probe` works.
  So UI changes can now be checked without a human.

### Task 9 — popup placement on Retina (done, `8ad2fd07`)
- Symptom: with the main client area at (194, 72) pt, the File menu opened at (95, 54) pt.
- Cause: Beefy's window coordinates are pixels (creation, `Resize`, `GetPlacement`, mouse events all convert to/from
  SDL logical units), but `SdlBFWindow::GetPosition` returned SDL's *logical* position alongside pixel sizes.
  Popups are placed from the parent's reported position + pixel offsets, then halved → half the window offset.
  Linux X11 usually runs at scale 1, which hides it.
- Fix: `GetPosition` converts to pixels (`SDLLogicalToPixel`). Also `GetDesktopResolution` applies the display
  mode's `pixel_density`, and `GetWorkspaceRectFrom` compares its pixel rect with *pixel* display bounds (each
  display's scaled bounds computed once — `SDLGetDisplayScale` creates a probe window per call).
- Verified (CGWindowList vs IDE): File menu at (192, 90) pt right under the menu bar; File ▸ Open submenu beside it
  at the Open row; autocomplete list just below the insertion point.
- Known, left alone: SDL3 reports popup (menu/tooltip) positions **relative to the parent**, so `BFWindow.mX/mY` of
  popups are parent-relative on every platform; window creation compensates. Only visible effect found: the MCP
  `screenshot all=true` composite draws popups at the wrong place. Making popup positions absolute would mean
  changing creation/move/resize together and re-testing Linux.

### Task 10 — debugger via LLDB (done, needs hands-on testing)
- `IDEHelper/LLDBDebugger*.cpp` is already a full SB-API debugger (Linux port): launch/attach, breakpoints
  (conditions, hit counts, logging, memory), stepping, Beef-aware evaluation, call stacks, hot compiling. CMake only
  enabled it for `UNIX AND NOT APPLE`, so macOS fell back to `GDBDebugger` (the Start Debugging crash).
- **Which liblldb.** Homebrew's `llvm@22` no longer ships lldb. The separate `lldb` formula (23.1.6) links Homebrew's
  libLLVM **23**, and loading it next to the libLLVM **22** the IDE links breaks LLDB's expression parser: the first
  `EvaluateExpression` segfaults in `llvm::DataLayout::getTypeAllocSize` (clang codegen of LLDB's ObjC runtime
  utility function). Reproduced with a 30-line host: liblldb alone → fine; liblldb + `-lLLVM-22` → crash, even
  without calling into LLVM 22 (most likely dyld coalescing weak C++ symbols across the two LLVMs).
- **Fix: link Apple's `LLDB.framework`** (found via `xcode-select -p`: Xcode's `SharedFrameworks` or the CLT's
  `Library/PrivateFrameworks`). It exports only `lldb::SB*` (no LLVM symbols), finds its signed `debugserver`
  itself, and coexists with LLVM 22. Apple ships no SB headers, so they come from Homebrew's `lldb` keg
  (`brew install lldb`); the SB API is ABI stable and the whole IDE links against lldb-1700 with no missing symbols.
  `IDEHelper_libs*.txt` now gets `-F<dir> -framework LLDB -Wl,-rpath,<dir>`.
- Code changes (all `__APPLE__` additions, Linux paths unchanged):
  - Target stdio (pty output pump, FIFO pipes for redirected output, terminal stdin hand-off) shared with macOS —
    plain POSIX. Checked: opening a FIFO `O_RDWR` doesn't block on macOS and the reader sees EOF on close, as on Linux.
  - Attach: exe path from `proc_pidpath` (Linux reads `/proc/<pid>/exe`).
  - Process stats: `proc_pidinfo(PROC_PIDTASKINFO)` instead of `task_for_pid` (needs an entitlement we lack);
    times converted from mach absolute units.
  - The Beef DWARF "host/shadow" layer (`DebugTarget`) is skipped (`HostSyncModules`/`HostBuildCallStack` return
    early): it reads only ELF images and x64 registers. Every query it answers already falls back to LLDB.
  - Hot compiling linked only relocatable **ELF** objects, so at first `HotLoad` reported it unsupported on macOS -
    now done, see Task 11. One ELF-only shadow check is `#ifdef __linux__`.
- Verified via MCP on a small program: source breakpoints bind and hit; step over / out; call stack
  (`Hello.Program.Add` ← `Main` ← `BeefStartProgram` ← `main` ← `dyld!start`); locals with summaries
  (`List<int> { count=3 }`, `Point { mX=10 mY=6 mName="origin" }`); eval of arithmetic, `pt.mName.Length`, `list[1]`,
  a method call `Add(3, 4)`; conditional breakpoint (`a == 3`); stop and re-launch. Program output goes to the IDE's
  terminal unless output redirection is on (same as Linux).
- Not done / follow-ups: a Mach-O + arm64 `DebugTarget`; step-out landed on the loop header
  line (27) rather than the call line (28) — check against Linux before calling it a bug; LLDB shows Beef `int` as
  `long` (clang type system naming 8-byte ints; standalone lldb shows the same); attach not click-tested.

### Task 11 — hot compiling on macOS (done, needs hands-on testing)
- Enable per workspace: Workspace properties → Enable Hot Compilation (`AllowHotSwapping = true` under
  `[Configs.Debug.macOS]`). It defaults off on every non-Windows platform, Linux included.
- The Linux design carries over (LLDBDebugger.cpp "Hot swap" section): load each rebuilt object into memory mapped
  in the target near the program, resolve its symbols against the program (`dlsym` for libraries), bind globals to
  their canonical definitions (data keeps its storage, runtime type tables are patched in place), and redirect each
  replaced method with a jump written over its old entry. What's new for macOS:
  - **Mach-O arm64 objects**: an Apple `LLDBHotObject` with parse / prepare / resolve / link next to the ELF ones
    (`#elif defined(__APPLE__)`). Relocations: `UNSIGNED` (+`SUBTRACTOR`), `BRANCH26` (16-byte stubs when out of
    ±128MB), `PAGE21`/`PAGEOFF12` (+`ADDEND`, load/store scaling), `GOT_LOAD_*`, `TLVP_LOAD_*`, `POINTER_TO_GOT`.
    Symbol sizes (Mach-O has none) are the distance to the next symbol in the section. Common symbols are handled.
  - **arm64 jumps**: `b imm26` (4 bytes) or `ldr x16, #8; br x16; .quad` (16), behind small per-arch helpers
    (`HotFitsRelJump`/`HotWriteRelJump`/`HotWriteShortJump`); the x64 versions encode exactly what Linux wrote before.
  - **W^X**: Apple silicon maps nothing writable+executable except `MAP_JIT` memory, which the program's own threads
    can't write - the first try (one `MAP_JIT` heap) crashed on the first write to a new static. Now the heap is
    plain RW (`mmap` with the address as a hint, accepted within 1GB of it), each image puts code+GOT+stubs on their
    own 16KB pages and data after, and one `mprotect` expression per batch (`HotProtectImages`) makes code RX and
    data RW. Verified separately that RW→RX anonymous code runs on this machine, with or without a debugger.
  - **Thread-locals**: existing ones bind to the program's TLV descriptors; a new `[ThreadStatic]` gets a descriptor
    built from `__BFTLS_EXTRA`'s (dyld's thunk and key, offset into that 16KB reserve), starting zeroed as on Linux.
  - **Debug map**: the program's DWARF lives in its `.o` files, and a hot compile rewrites those, after which LLDB
    drops the original code's debug info ("debug map object file ... changed"). With hot swapping on, the debugger
    runs `xcrun dsymutil` on the program at launch (≈0.1s for a corlib-sized program), so LLDB reads the `.dSYM`.
    (`BfpSpawn_WaitFor` with a timeout throws on macOS, so it waits without one.)
  - Hot objects are registered with LLDB as modules (their code sections mapped where we loaded them), like Linux.
- Verified via MCP with a program ticking every 250ms:
  - edit a method body (`i * 2` → `i * 3`), static state carries on
  - change a virtual override
  - add a static with an initializer (starts at its value), a `[ThreadStatic]` (starts at 0), a new method with new string literals
  - second hot compile adding a virtual method to the base class (vtable extension), old image freed afterwards
  - breakpoint inside hot code: binds in `BeefHot_*_HotTest_Program.o`, locals, call stack through hot and original
    frames, step over / out
  - injected write failure (`BEEF_LLDB_HOT_FAIL_WRITE=1`): writes undone, program keeps running the old code
- Known gaps: evaluating a static *added* by a hot compile fails (LLDB reads it at its object-file address; data
  sections of hot objects are left unloaded, as on Linux); `sBfTypeData` whose size changed isn't updated (logged,
  same as Linux); a method already running (e.g. `Main`'s loop) keeps running its old code until it's re-entered.

### Task 12 — variadic C externs audit (done, `aac4bf01`)
- Why it matters: Apple arm64 passes variadic arguments on the stack, while a Beef `extern` with fixed parameters puts
  them in registers. Linux arm64 and x64 use registers for both, so these bugs only show up on Apple.
- Method: collect every Beef `extern` name and `LinkName("...")` target in `BeefLibs`, `IDE/src`, `BeefBuild/src` and
  `IDEHelper/Tests` (≈2900 + 940), then match them against prototypes ending in `...` in the macOS SDK, Homebrew
  headers (curl, SDL2, SDL3, libgit2, fontconfig) and the BeefySysLib/BeefRT/IDEHelper headers. Script:
  regex over comment-stripped headers, kept in the session scratchpad (not committed).
- Hits:
  - `curl_easy_setopt` / `curl_easy_getinfo` (`BeefLibs/curl/src/Curl.bf`): **broken**. The first `SetOpt` returned
    `BadFunctionArgument`, so `Transfer.Init` died on the unhandled result. Fixed: declared with `...` under
    `BF_PLATFORM_MACOS || BF_PLATFORM_IOS`, like `ioctl` in Socket (`b595ed18`). Other platforms unchanged.
    The IDE itself doesn't call curl (only a commented-out block in BeefBuild does), so this affected user programs.
  - `ioctl` (Socket): fixed earlier.
  - SDL2 `SDL_Log*` / `SDL_SetError`: declared with only the format string, and callers pass no variadic arguments,
    so the fixed-argument ABI matches. Left alone (a `%` in the message is a format bug on every platform).
  - fontconfig `FcObjectSetBuild`, sd-bus, emscripten, the `sprintf` test: already declared with `...`.
  - No variadic functions among the BeefySysLib/BeefRT/IDEHelper exports.
- Verified with a scratch program (curl Transfer over a local `file://` URL, plus an Easy `SetOpt`/`Perform`/
  `GetInfo(.EffectiveUrl)` on a missing file): before the fix it aborted with `BadFunctionArgument`, after it all
  three paths pass. The IDE still builds. MiniZ's externs are libc and were covered by the SDK scan. FMOD has no
  installed headers; none of its bound names is a log/format-style function. Windows and Linux keep the old
  declarations (they're under `#else`), so nothing changes there.

### Task 13 — local time zone (done, `d48afad7`)
- Symptom: `DateTime.Now` / `ToLocalTime` gave UTC (the IDE's "built …" line was an hour early here, CET).
  Cause: `TimeZoneInfo.GetLocalTimeZoneFromTzFile()` was a stub returning `Utc` on **every** non-Windows platform,
  so Linux had the same bug. Decision (user): parse the tzfile, not libc hooks or a fixed offset.
- `BeefLibs/corlib/src/TimeZoneInfo.Unix.bf` (`extension TimeZoneInfo`, `#if !BF_PLATFORM_WINDOWS`); the stub in
  `TimeZoneInfo.bf` is gone, nothing else there changed.
  - Source: `$TZ` (`:`-prefix stripped; absolute path, else `/usr/share/zoneinfo/<name>`, else parsed as a POSIX TZ
    string), otherwise `/etc/localtime`. Id from the symlink target after `zoneinfo/` (`Europe/Oslo`), else `Local`.
    Unreadable or invalid data falls back to UTC as before.
  - TZif v1–v4: the 64-bit block plus the POSIX footer (`std offset dst [offset],start[/time],end[/time]`, `Mm.w.d`,
    `Jn`, `n`, quoted `<+03>` names, US rules when a DST name has no rule, like glibc).
  - The .NET Framework rule model (`AdjustmentRule`: date range, yearly start/end `TransitionTime`, `DaylightDelta`,
    `BaseUtcOffsetDelta`) can't hold arbitrary transitions, so the code builds one rule per year from the transitions:
    transitions become "Nth/last weekday" rules so identical years merge (Oslo: 20 rules for 1895–9999). Years whose
    standard or daylight offset changes, or with several DST periods (Ramadan breaks, WWII double summer time), are
    split into date ranges at the nearest midnight. Southern-hemisphere years wrap (start > end). The footer becomes
    an open-ended last rule; times it can't express (`M3.5.0/-1` Nuuk, `M3.4.4/50` Gaza) are expanded exactly until
    2100, then clamped into the day.
  - Slim files (`zic -b slim`, common on Linux) end with a no-op transition marking where the footer takes over; the
    footer only applies after the file's last transition, no-ops included.
  - Gotcha: a floating `TransitionTime` stores `Day = 1`, so a January transition at 00:00 looks like the existing
    "year starts/ends in DST" marker (`IsStartDateMarkerForBeginningOfYear`); those use a fixed date.
- Verified (macOS; scratch harness comparing `ToLocalTime`, `IsDaylightSavingTime` and the local→UTC round trip with
  libc `localtime_r`, sampled every 7h13m):
  - all 598 zones, 1970–2038: no crashes; 117 offset differences in 78 zones, each a single sample within 12 hours of a
    mid-year offset change (rules start at midnight); 4 round-trip failures, each the hour before a permanent switch
    out of DST at the same offset (Yukon 2020, Damascus 2022), which the model treats as a fall-back hour.
  - Python `zoneinfo`: offset changes identical to 2160 for Oslo, Sydney, New York, Casablanca, to 2100 for Gaza and
    Nuuk (macOS libc ignores DST after 2037 for Nuuk: it can't parse the v3 footer's negative time).
  - `TZ` forms (`EST5EDT`, `CET-1CEST,M3.5.0,M10.5.0/3`, `<+0330>-3:30`, negative DST `IST-1GMT0,...`, `:Europe/Paris`,
    absolute path, bogus → UTC); slim vs fat builds of the same source (zic) give identical results.
  - IDE start line: "built 11/22/2026 at 11:43 PM" = the binary's local mtime. `./bin/build.sh ide` passes (201/201 +
    1/1, Debug and Release).
- Known limits: the DST flag is false for all-year DST (war time) and for DST at the standard offset (Moscow 1991),
  offsets are right; offsets rounded to whole minutes (local mean time only). **Linux not tested** (no Linux box/VM
  here; Docker isn't running) — same file format, code paths and system paths, but `/etc/localtime` copies (not
  symlinks) give Id `Local`.

### Task 14 — native menu bar (done, needs hands-on testing)
- Request (user, 2026-11-26): File/Edit/View/... in the macOS menu bar at the top of the screen, not inside the window.
- Before: Windows uses native menus (`mMainWindow.mSysMenu` → `BFWindow_AddMenuItem`), every other platform draws
  `IDE/src/ui/MenuBar.bf` inside `MainFrame`; `SdlBFWindow::AddMenuItem` returned NULL.
- `BeefySysLib/platform/darwin/DarwinMenu.mm` (ARC, AppKit): `SdlBFWindow` creates a root menu for `BFWINDOW_MENU`
  windows (only the IDE main window) and forwards Add/Modify/RemoveMenuItem under `__APPLE__`. The root replaces SDL's
  default `[NSApp mainMenu]`: an app menu (Services, Hide ⌘H, Hide Others ⌥⌘H, Show All, Quit ⌘Q), then the IDE's
  menus. The "Help" menu becomes `NSApp.helpMenu` (Spotlight menu search).
  - Opening a submenu calls `mMenuItemSelectedFunc` with it (`menuNeedsUpdate:`), like `WM_INITMENUPOPUP` on Windows,
    so the Beef update handlers refresh enabled/checked state. Item clicks are queued and delivered from
    `DarwinMenu_DispatchPending()` at the end of `SdlBFApp::ProcessSDLEvents`, not from inside `SDL_PollEvent`.
  - Quit runs the main window's close query (same as the close button), then removes it.
  - **Shortcuts are display-only**; the IDE keeps handling keys (its bindings stay Ctrl-based, shown as ⌃). AppKit
    matches item key equivalents even when the menu delegate answers NO to `menuHasKeyEquivalent:` (checked: ⌃F was
    consumed by Edit ▸ Quick Find), so equivalents are only set while their menu is open (`menuWillOpen:` /
    `menuDidClose:`). Multi-chord hot keys ("Ctrl+K, Ctrl+C") are drawn after a right-aligned tab in an attributed title.
  - `&` mnemonics are stripped. NULL text/hot key in Modify keeps the current one, as on Windows.
  - While a native modal (NSOpenPanel) runs, clicks and update calls are ignored. While a Beef modal dialog is up,
    `BFWindow.NativeMenuItemSelected` (macOS only) ignores leaf items, since unlike Windows the menu bar isn't disabled.
- IDE: `CreateMenu`, the MCP `GetMenuRoot` and `MainFrame` treat macOS like Windows (no `MenuBar` widget, no Alt+letter
  menu opening). `bin/build.sh` bootstrap `LINKOPTS` gained `-framework AppKit` (Beefy2D's configs already had it).
- Verified (lldb on the running IDE + MCP): `NSApp.mainMenu` = app menu + File…Help with the right items; key
  equivalents `Control-F`, `Control-Shift-F`, `Shift-F3`, `Option-←` while open, none while closed;
  `performKeyEquivalent:` returns NO for ⌃F and ⌃⌥O with menus closed, YES for ⌘Q (IDE then exits via close query);
  update handler disables Debug items with no workspace; Help ▸ About opens the About dialog; a second About while it
  is up is ignored. MCP screenshot: no in-window menu bar. `./bin/build.sh ide` passes.
- **Not verified:** real mouse clicks / keyboard in the menu bar (no Accessibility permission here), look of the
  attributed multi-chord items and of disabled items.
- Known gaps: File ▸ Preferences and File ▸ Exit stay where they are (not moved to the app menu as Settings…/Quit);
  no standard Window menu items (Minimize ⌘M, Zoom); IDE shortcuts remain Ctrl-based.

### Task 15 — setup script and Brewfile (done)
- Goal: make the port easy for others to build. Containers were ruled out: Docker on a Mac runs Linux, the build needs
  AppKit/CoreText, Xcode's `LLDB.framework` and Apple's linker, and cross-compiling from Linux (osxcross) means
  repackaging Apple's SDK and still gives no `LLDB.framework` or way to test.
- `Brewfile`: cmake, ninja, llvm@22, sdl3, lldb (headers only).
- `bin/setup_macos.sh` (bash 3.2; `--check` changes nothing): arch/macOS version, Xcode or CLT (`xcode-select -p`,
  `xcrun clang`, dsymutil), `LLDB.framework` (same search as `IDEHelper/CMakeLists.txt`), developer mode
  (`DevToolsSecurity`), Homebrew, each formula (LLVM must be 22.1.x, `libSDL3.dylib` present, LLDB headers), libffi
  sources, a non-ninja `jbuild_d/`. Missing required pieces exit 1 with a hint; debugger-only pieces are warnings.
  - Installs missing formulas with plain `brew install`, not `brew bundle install`: bundle also upgrades outdated
    formulas (it reports an outdated cmake as unsatisfied) and unlinks keg-only `llvm@22` if the user linked it.
- `bin/build.sh`: also looks for `$(brew --prefix llvm@22)/bin/llvm-config`. llvm@22 is keg-only, so before this a
  fresh machine needed it on PATH by hand, and failed with the Linux "install llvm-22-dev" message (now macOS-specific).
- README: short "Building on macOS (unofficial port)" section.
- Verified: `--check` on this machine (all ok); without brew on PATH (fails with hint, exit 1); a Brewfile with a
  nonexistent formula (reported as not installed); bad argument (exit 2); build.sh's LLVM lookup with only a `brew`
  wrapper on PATH (finds `/opt/homebrew/opt/llvm@22/bin/llvm-config`) and with no brew (empty, so the error path);
  `./bin/build.sh ide` passes. **Not verified:** a really fresh Mac (actual installs, CLT-only machine, Intel).

### Task 16 — GitHub Actions macOS build (written, not yet run)
- `.github/workflows/build.yml`: upstream's `build-macos` job (`if: false` since `88e4b36f` "Disable broken macOS
  build"; plain `bin/build.sh` on macos-latest + macos-15-intel) is replaced by `build-macos-ide`: `macos-15` (arm64),
  `bin/setup_macos.sh` (installs the Brewfile formulas, checks Xcode's `LLDB.framework`), then `bin/build.sh ide`
  (native libs, BeefBuild + IDEHelper tests, both IDE configs). Timeout 90 min. Intel dropped: the port is arm64-only.
- The Windows/Linux jobs are unchanged and still run on every push.
- Unverified until the first run: brew install time on the runner (lldb pulls Homebrew's llvm as a dependency), the
  runner's default Xcode `LLDB.framework` linking against Homebrew lldb's headers, build time vs the timeout.
- No artifacts yet: the binaries link Homebrew's libLLVM by absolute path and dlopen Homebrew's SDL3, so they only run
  on a machine set up the same way. Uploading an `.app` belongs with the packaging work.

## Decisions

- Uncommitted user edit to `bin/build.sh` (re-indent + brew `CMAKE_EXTRA_ARGS`) is left alone, not
  committed by me. After `181c1af9`, its `-DCMAKE_CXX_FLAGS=-I$BREW_PREFIX/include` should no longer be
  needed: a scratch tree configured with only `-DBF_ENABLE_SDL=1 -DLLVM_DIR=...` compiled BeefRT, BeefySysLib,
  IDEHelper and hunspell fine; the only failure was BeefBoot's `-lLLVM-22` link, which the *original*
  build.sh already handles by exporting `LIBRARY_PATH` on Darwin. So upstream build.sh + these commits should
  suffice (not yet re-run end-to-end with your edit reverted).
- Dialogs follow the Linux API surface; the macOS work lives in `RunDialog`.
- Apple APIs: Obj-C++/C++ shims in `BeefySysLib/platform/darwin`, `BF_EXPORT`ed, linked frameworks listed in
  Beefy2D's macOS configs (user decision).
- SDL stays dlopen'ed (no link-time dependency), with Homebrew prefixes as a fallback search path.
- Menu bar: native NSMenu on macOS; shortcuts display-only, the IDE keeps handling keys (Task 14).
- Debugger: the existing LLDB debugger, linked against Apple's `LLDB.framework` with Homebrew `lldb` headers
  (user picked Homebrew's liblldb; switched to the framework after liblldb 23 + LLVM 22 proved to crash, see Task 10).

## Open problems / next

1. Hands-on test of the native dialogs (see Task 6).
2. (optional) Absolute popup positions, so MCP `all=true` composites are right (see Task 9).
3. Map the default "Segoe UI Symbol/Emoji" alternates to Apple fonts.
4. Debugger follow-ups (Task 10/11): Mach-O/arm64 `DebugTarget`, step-out location check, evaluating statics added
   by a hot compile.
   Without LLDB (no Xcode/CLT or no headers) the GDB fallback still crashes (`BfpSpawn_Kill` NOT_IMPL).
5. ~~Non-variadic `extern`s of variadic C functions~~: audited, curl fixed (Task 12). Any new `extern` of a
   variadic C function has to be declared with `...` on Apple.
6. ~~`ToLocalTime` on macOS~~ (Task 13); `LIBRARY_PATH` needed for hand-run IDE builds.

## Build commands that work

```sh
bin/setup_macos.sh        # checks prerequisites, installs missing Brewfile formulas (--check: report only)
./bin/build.sh ide        # full: native libs + BeefBuild + tests + BeefIDE_d + BeefIDE (exit 0)
cd IDE/dist && LIBRARY_PATH=$(brew --prefix llvm@22)/lib ./BeefBuild -proddir=../ -config=Debug   # IDE only
cd IDE/dist && ./BeefIDE_d                                    # run
cd IDE/dist && ./BeefIDE_d -mcp=4310 -deterministic -workspace=/path/to/ws   # run + drive via MCP (curl JSON-RPC to /mcp)
```

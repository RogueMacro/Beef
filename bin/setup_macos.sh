#!/bin/bash
# Checks (and installs where it can) everything needed to build Beef and the IDE on macOS.
#
#   bin/setup_macos.sh            check, and install Brewfile packages that aren't installed
#   bin/setup_macos.sh --check    check only, change nothing
#
# Exits non-zero if something required is missing. Then build with: ./bin/build.sh ide

SCRIPTPATH=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOTPATH="$(dirname "$SCRIPTPATH")"

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h|--help)
      sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""; C_OFF=""
fi

ERRORS=0
WARNINGS=0
ok()   { echo "  ${C_OK}ok${C_OFF}    $1"; }
warn() { echo "  ${C_WARN}warn${C_OFF}  $1"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "  ${C_ERR}FAIL${C_OFF}  $1"; ERRORS=$((ERRORS + 1)); }
hint() { echo "        $1"; }
section() { echo; echo "${C_BOLD}$1${C_OFF}"; }

if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "This script is for macOS. On Linux, see the README and run bin/build.sh directly." >&2
  exit 1
fi

### System ###

section "System"
MACOS_VERSION=$(sw_vers -productVersion)
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  ok "macOS $MACOS_VERSION, $ARCH"
else
  warn "macOS $MACOS_VERSION, $ARCH - the macOS port is developed and tested on Apple Silicon (arm64) only"
fi

### Xcode / Command Line Tools ###

section "Xcode / Command Line Tools"
DEVELOPER_DIR=$(xcode-select -p 2>/dev/null)
if [ -z "$DEVELOPER_DIR" ] || [ ! -d "$DEVELOPER_DIR" ]; then
  fail "No Xcode or Command Line Tools found"
  hint "Install them with: xcode-select --install   (or install Xcode from the App Store)"
else
  ok "Developer dir: $DEVELOPER_DIR"

  if CLANG_VERSION=$(xcrun clang --version 2>/dev/null | head -1); then
    ok "Apple clang: $CLANG_VERSION"
  else
    fail "xcrun can't run clang"
    hint "If you just installed Xcode, accept its license: sudo xcodebuild -license accept"
  fi

  if ! xcrun --find dsymutil >/dev/null 2>&1; then
    warn "dsymutil not found (used by hot compiling while debugging)"
  fi

  # Same search as IDEHelper/CMakeLists.txt
  LLDB_FRAMEWORK=""
  for dir in "$DEVELOPER_DIR/../SharedFrameworks" "$DEVELOPER_DIR/Library/PrivateFrameworks"; do
    if [ -d "$dir/LLDB.framework" ]; then
      LLDB_FRAMEWORK=$(cd "$dir/LLDB.framework" && pwd -P)
      break
    fi
  done
  if [ -n "$LLDB_FRAMEWORK" ]; then
    ok "LLDB.framework: $LLDB_FRAMEWORK"
  else
    warn "LLDB.framework not found - the IDE will build without its debugger"
    hint "It ships with Xcode and the Command Line Tools; check that xcode-select -p points at a full install"
  fi

  if DevToolsSecurity -status 2>/dev/null | grep -q "enabled"; then
    ok "Developer mode is enabled (debugging won't ask for a password)"
  else
    warn "Developer mode is off: macOS will ask for an admin password the first time the IDE debugs a program"
    hint "Enable it with: sudo DevToolsSecurity -enable"
  fi
fi

### Homebrew ###

section "Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  fail "Homebrew is not installed"
  hint "Install it from https://brew.sh, then run this script again"
else
  BREW_PREFIX=$(brew --prefix)
  ok "Homebrew at $BREW_PREFIX"

  # Install formulas from the Brewfile that aren't installed at all. Not 'brew bundle install': that also
  # upgrades outdated formulas and unlinks keg-only ones (llvm@22) that a user linked on purpose.
  MISSING=""
  for formula in $(sed -n 's/^brew "\([^"]*\)".*/\1/p' "$ROOTPATH/Brewfile"); do
    if [ -z "$(brew list --versions "$formula" 2>/dev/null)" ]; then
      MISSING="$MISSING $formula"
    fi
  done
  if [ -n "$MISSING" ]; then
    if [ $CHECK_ONLY == 1 ]; then
      warn "Not installed:$MISSING (run without --check to install)"
    else
      echo "  Installing:$MISSING"
      if brew install $MISSING; then
        ok "Installed:$MISSING"
      else
        fail "brew install failed (see above)"
      fi
    fi
  fi

  # Reports an installed formula's version, or fails/warns if it's missing
  brew_version() {
    brew list --versions "$1" 2>/dev/null | awk '{print $2}'
  }

  # cmake
  if command -v cmake >/dev/null 2>&1; then
    ok "cmake $(cmake --version | head -1 | awk '{print $3}')"
  else
    fail "cmake not found"
    hint "brew install cmake"
  fi

  # ninja
  if command -v ninja >/dev/null 2>&1; then
    ok "ninja $(ninja --version)"
  else
    warn "ninja not found - builds will use make and be slower"
    hint "brew install ninja"
  fi

  # llvm@22 (bin/build.sh requires 22.1.x)
  LLVM_CONFIG="$BREW_PREFIX/opt/llvm@22/bin/llvm-config"
  if [ -x "$LLVM_CONFIG" ]; then
    LLVM_VERSION=$("$LLVM_CONFIG" --version)
    case "$LLVM_VERSION" in
      22.1.*) ok "LLVM $LLVM_VERSION ($BREW_PREFIX/opt/llvm@22)" ;;
      *)
        fail "LLVM $LLVM_VERSION found, but the build needs 22.1.x"
        hint "brew upgrade llvm@22"
        ;;
    esac
  else
    fail "LLVM 22 not found"
    hint "brew install llvm@22"
  fi

  # sdl3 (dlopen'ed by the IDE at runtime)
  SDL_VERSION=$(brew_version sdl3)
  if [ -n "$SDL_VERSION" ] && [ -e "$BREW_PREFIX/lib/libSDL3.dylib" ]; then
    ok "SDL3 $SDL_VERSION"
  else
    fail "SDL3 not found (the IDE needs it for its window)"
    hint "brew install sdl3"
  fi

  # lldb headers (the library itself comes from Xcode)
  if [ -f "$BREW_PREFIX/opt/lldb/include/lldb/API/LLDB.h" ]; then
    ok "LLDB headers ($BREW_PREFIX/opt/lldb/include)"
  else
    warn "LLDB headers not found - the IDE will build without its debugger"
    hint "brew install lldb"
  fi
fi

### Repo ###

section "Repository"
if [ -f "$ROOTPATH/BeefySysLib/third_party/libffi/configure" ]; then
  ok "libffi sources present"
else
  fail "BeefySysLib/third_party/libffi/configure is missing - is the checkout complete?"
fi

if [ -d "$ROOTPATH/jbuild_d" ] && [ ! -f "$ROOTPATH/jbuild_d/build.ninja" ] && command -v ninja >/dev/null 2>&1; then
  warn "jbuild_d/ was configured without ninja; './bin/build.sh clean' once to switch to ninja"
fi

### Summary ###

echo
if [ $ERRORS -gt 0 ]; then
  echo "${C_ERR}${C_BOLD}$ERRORS problem(s) must be fixed before building.${C_OFF}"
  exit 1
fi

if [ $WARNINGS -gt 0 ]; then
  echo "${C_WARN}${C_BOLD}Ready to build, with $WARNINGS warning(s) above.${C_OFF}"
else
  echo "${C_OK}${C_BOLD}Ready to build.${C_OFF}"
fi
echo
echo "Next:"
echo "  ./bin/build.sh ide        # native libs, BeefBuild, tests and the IDE (first build takes a while)"
echo "  IDE/dist/BeefIDE_d        # run the debug IDE (IDE/dist/BeefIDE for release)"

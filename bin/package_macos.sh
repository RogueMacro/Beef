#!/bin/bash
# Packages an existing build (./bin/build.sh ide) as a self-contained BeefIDE.app plus a zip of it.
#
#   bin/package_macos.sh            -> builds/macos/BeefIDE.app and builds/macos/BeefIDE-<version>-macos-arm64.zip
#   bin/package_macos.sh --no-zip   -> only the .app
#
# The app bundles the dylibs that come from Homebrew (libLLVM and its deps, SDL3) and libhunspell, and is
# signed ad hoc (not notarized: on first launch, right-click > Open). It still needs Xcode or the Command
# Line Tools on the user's machine: for linking Beef programs (clang) and for the debugger (LLDB.framework).
#
# Bundle layout (DarwinAppBundle.h makes the IDE and BeefBuild use Contents/Resources/bin as install dir):
#   Contents/MacOS/BeefIDE, BeefBuild
#   Contents/Frameworks/*.dylib
#   Contents/Resources/bin/        runtime libs, BeefConfig.toml, fonts, images, shaders, ...
#   Contents/Resources/BeefLibs/   corlib and the other libraries
# User data (settings, layout, managed libs) goes to ~/Library/Application Support/BeefLang/.

set -e

SCRIPTPATH=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOTPATH="$(dirname "$SCRIPTPATH")"

MAKE_ZIP=1
for arg in "$@"; do
  case "$arg" in
    --no-zip) MAKE_ZIP=0 ;;
    -h|--help)
      sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

fail() { echo "ERROR: $1" >&2; exit 1; }

[[ "$OSTYPE" == "darwin"* ]] || fail "This script is for macOS"
command -v brew >/dev/null 2>&1 || fail "Homebrew not found (SDL3 is bundled from it)"

DIST="$ROOTPATH/IDE/dist"
REL_BIN="$ROOTPATH/jbuild/Release/bin"
DBG_BIN="$ROOTPATH/jbuild_d/Debug/bin"
SDL_DYLIB="$(brew --prefix sdl3)/lib/libSDL3.dylib"

for f in "$DIST/BeefIDE" "$DIST/BeefBuild" "$REL_BIN/libBeefRT.a" "$DBG_BIN/libBeefRT_d.a" "$REL_BIN/libBeefySysLib.a" \
  "$DBG_BIN/libBeefySysLib_d.a" "$REL_BIN/libhunspell.dylib" "$REL_BIN/ImgCreate"; do
  [ -e "$f" ] || fail "$f is missing - run ./bin/build.sh ide first"
done
[ -e "$SDL_DYLIB" ] || fail "$SDL_DYLIB is missing - brew install sdl3"

VERSION=$(sed -n 's/.*public const String cVersion = "\([^"]*\)".*/\1/p' "$ROOTPATH/IDE/src/IDEApp.bf")
[ -n "$VERSION" ] || fail "Couldn't read cVersion from IDE/src/IDEApp.bf"
ARCH=$(lipo -archs "$DIST/BeefIDE")
MIN_MACOS=$(otool -l "$DIST/BeefIDE" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')

OUT_DIR="$ROOTPATH/builds/macos"
APP="$OUT_DIR/BeefIDE.app"
CONTENTS="$APP/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
INSTALL_DIR="$CONTENTS/Resources/bin"

echo "Packaging BeefIDE $VERSION ($ARCH, macOS $MIN_MACOS+) into $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$FRAMEWORKS" "$INSTALL_DIR"

### Executables ###

cp "$DIST/BeefIDE" "$DIST/BeefBuild" "$CONTENTS/MacOS/"

### Install dir ###

cp -L "$REL_BIN/libBeefRT.a" "$DBG_BIN/libBeefRT_d.a" "$REL_BIN/libBeefySysLib.a" "$DBG_BIN/libBeefySysLib_d.a" "$INSTALL_DIR/"
cp "$DIST/BeefConfig_install.toml" "$INSTALL_DIR/BeefConfig.toml"
cp "$DIST/BeefDbgVis.toml" "$DIST/en_US.aff" "$DIST/en_US.dic" "$INSTALL_DIR/"
cp -R "$DIST/fonts" "$DIST/shaders" "$INSTALL_DIR/"
mkdir -p "$INSTALL_DIR/images"
find "$DIST/images" -maxdepth 1 -type f \( -name '*.png' -o -name '*.tga' -o -name '*.ttf' \) -exec cp {} "$INSTALL_DIR/images/" \;
cp -L "$REL_BIN/ImgCreate" "$INSTALL_DIR/images/ImgCreate"

### BeefLibs (tracked files only, so no build output) ###

(cd "$ROOTPATH" && git ls-files -z BeefLibs) | rsync -a --from0 --files-from=- "$ROOTPATH/" "$CONTENTS/Resources/"
# Beefy2D's macOS configs link these from its dist dir (build.sh only symlinks them there)
cp -L "$REL_BIN/libBeefySysLib.a" "$DBG_BIN/libBeefySysLib_d.a" "$CONTENTS/Resources/BeefLibs/Beefy2D/dist/"

### Dylibs ###

# Copies a dylib into Frameworks under the given name, gives it an @rpath install name and bundles its deps
bundle_dylib() {
  local src="$1" name="$2"
  [ -f "$FRAMEWORKS/$name" ] && return
  echo "  bundling $name (from $src)"
  cp -L "$src" "$FRAMEWORKS/$name"
  chmod u+w "$FRAMEWORKS/$name"
  install_name_tool -id "@rpath/$name" "$FRAMEWORKS/$name" 2>/dev/null
  fix_deps "$FRAMEWORKS/$name"
}

# Points a Mach-O's non-system dependencies at bundled copies
fix_deps() {
  local file="$1" dep name
  for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}'); do
    case "$dep" in
      /usr/lib/*|/System/*) ;;
      @rpath/LLDB.framework/*) ;; # Xcode's / the Command Line Tools' copy, found through the rpaths below
      @rpath/*)
        name="${dep#@rpath/}"
        [ -f "$FRAMEWORKS/$name" ] || fail "$file needs $dep, which isn't bundled"
        ;;
      @*) fail "$file has an unexpected dependency $dep" ;;
      *)
        name=$(basename "$dep")
        bundle_dylib "$dep" "$name"
        install_name_tool -change "$dep" "@rpath/$name" "$file" 2>/dev/null
        ;;
    esac
  done
}

bundle_dylib "$REL_BIN/libhunspell.dylib" libhunspell.dylib
# The IDE dlopens SDL3 as @executable_path/../Frameworks/libSDL3.dylib
bundle_dylib "$SDL_DYLIB" libSDL3.dylib

for exe in "$CONTENTS/MacOS/BeefIDE" "$CONTENTS/MacOS/BeefBuild"; do
  fix_deps "$exe"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe"
  # LLDB.framework: the build machine's rpath (normally Xcode's) is kept; also look in the Command Line Tools
  CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/PrivateFrameworks"
  if ! otool -l "$exe" | grep -q "path $CLT_FRAMEWORKS "; then
    install_name_tool -add_rpath "$CLT_FRAMEWORKS" "$exe"
  fi
done
fix_deps "$INSTALL_DIR/images/ImgCreate"

# Nothing may still point into Homebrew or the build tree
for f in "$CONTENTS/MacOS/"* "$FRAMEWORKS/"* "$INSTALL_DIR/images/ImgCreate"; do
  if otool -L "$f" | tail -n +2 | grep -E -q "/opt/homebrew|/usr/local|$ROOTPATH"; then
    otool -L "$f" >&2
    fail "$f still references a non-bundled library"
  fi
done

### Info.plist and icon ###

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Beef IDE</string>
	<key>CFBundleExecutable</key>
	<string>BeefIDE</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>org.beeflang.BeefIDE</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>BeefIDE</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF
plutil -lint -s "$CONTENTS/Info.plist"

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
sips -p 256 256 "$ROOTPATH/IDE/Resources/Beef256.png" --out "$ICONSET/icon_256x256.png" >/dev/null
for size in 16 32 128; do
  sips -z $size $size "$ICONSET/icon_256x256.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICONSET/icon_256x256.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

### Signing (ad hoc), inside out ###

for f in "$FRAMEWORKS/"*.dylib "$INSTALL_DIR/images/ImgCreate" "$CONTENTS/MacOS/BeefBuild"; do
  codesign --force --sign - "$f"
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ $MAKE_ZIP == 1 ]; then
  ZIP="$OUT_DIR/BeefIDE-$VERSION-macos-$ARCH.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "Built $ZIP ($(du -sh "$ZIP" | cut -f1))"
fi

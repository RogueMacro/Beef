# Homebrew dependencies for building Beef (compiler, BeefBuild and the IDE) on macOS.
# Run bin/setup_macos.sh, which installs whichever of these are missing and also checks the parts
# Homebrew can't install (Xcode / Command Line Tools, LLDB.framework). `brew bundle` works too, but it
# also upgrades outdated formulas and unlinks llvm@22 if you linked it.

brew "cmake"
brew "ninja"    # optional, but much faster builds
brew "llvm@22"  # bin/build.sh requires LLVM 22.1.x; keg-only, build.sh finds it through brew
brew "sdl3"     # IDE window/input; loaded at runtime from Homebrew's lib dir
brew "lldb"     # LLDB SB API headers only: the IDE debugger links Xcode's LLDB.framework

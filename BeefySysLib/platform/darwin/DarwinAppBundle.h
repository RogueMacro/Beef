#pragma once

// Layout of the packaged BeefIDE.app (see bin/package_macos.sh):
//   Contents/MacOS/        BeefIDE, BeefBuild
//   Contents/Frameworks/   bundled dylibs (libLLVM, libSDL3, libhunspell, ...)
//   Contents/Resources/bin/        the install dir: runtime libs, BeefConfig.toml, fonts, images, shaders, ...
//   Contents/Resources/BeefLibs/   corlib and the other libraries
// A plain build (IDE/dist) keeps everything next to the executable.

#include "Common.h"

NS_BF_BEGIN;

// If exeDir is "<name>.app/Contents/MacOS", sets outInstallDir to "<name>.app/Contents/Resources/bin/"
inline bool DarwinGetAppBundleInstallDir(const StringImpl& exeDir, String& outInstallDir)
{
	String dir = exeDir;
	while ((dir.length() > 0) && (dir[dir.length() - 1] == '/'))
		dir.RemoveFromEnd(1);

	const char* suffix = ".app/Contents/MacOS";
	if (!dir.EndsWith(suffix))
		return false;

	outInstallDir = dir.Substring(0, dir.length() - strlen("MacOS"));
	outInstallDir += "Resources/bin/";
	return true;
}

NS_BF_END;

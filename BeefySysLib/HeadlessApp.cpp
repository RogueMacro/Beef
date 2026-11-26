#include "HeadlessApp.h"
#include "platform/PlatformHelper.h"
#ifdef __APPLE__
#include "platform/darwin/DarwinAppBundle.h"
#endif

USING_NS_BF;

void HeadlessApp::Init()
{
    mRunning = true;

	Beefy::String exePath;
	BfpGetStrHelper(exePath, [](char* outStr, int* inOutStrSize, BfpResult* result)
	{
		BfpSystem_GetExecutablePath(outStr, inOutStrSize, (BfpSystemResult*)result);
	});

	mInstallDir = GetFileDir(exePath) + "/";
#ifdef __APPLE__
	// BeefBuild inside BeefIDE.app: the install dir is Contents/Resources/bin
	DarwinGetAppBundleInstallDir(GetFileDir(exePath), mInstallDir);
#endif
}

void HeadlessApp::Run()
{
	while (mRunning)
	{
        BfpThread_Sleep((uint32)(1000 / mRefreshRate));
		Process();
	}
}

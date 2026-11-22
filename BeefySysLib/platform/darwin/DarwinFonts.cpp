// System font enumeration for macOS through CoreText, used by Beefy2D's Font to map font names to files.

#include <CoreText/CoreText.h>
#include <limits.h>
#include <math.h>
#include "Common.h"
#include "util/Dictionary.h"
#include "util/Array.h"

typedef void (BF_CALLTYPE* BFFontEnumCallback)(const char* family, const char* style, const char* path, int32 isRegular, void* userData);

static bool BFCFStringToUTF8(CFStringRef str, Beefy::String& outStr)
{
	outStr.Clear();
	if (str == NULL)
		return false;

	CFIndex maxSize = CFStringGetMaximumSizeForEncoding(CFStringGetLength(str), kCFStringEncodingUTF8) + 1;
	char* buffer = new char[maxSize];
	bool success = CFStringGetCString(str, buffer, maxSize, kCFStringEncodingUTF8);
	if (success)
		outStr = buffer;
	delete [] buffer;
	return success;
}

// Returns the face's index within its file, for collections (.ttc) holding several faces. CoreText doesn't
// report it directly, so match the PostScript name against the file's descriptors, which come back in file order.
static int BFGetFaceIndex(CTFontDescriptorRef desc, CFURLRef url, const Beefy::String& path, Beefy::Dictionary<Beefy::String, Beefy::Array<Beefy::String>>& faceNameCache)
{
	Beefy::Array<Beefy::String>* faceNames = NULL;
	if (faceNameCache.TryAdd(path, NULL, &faceNames))
	{
		CFArrayRef fileDescs = CTFontManagerCreateFontDescriptorsFromURL(url);
		if (fileDescs != NULL)
		{
			CFIndex fileDescCount = CFArrayGetCount(fileDescs);
			for (CFIndex i = 0; i < fileDescCount; i++)
			{
				CFStringRef name = (CFStringRef)CTFontDescriptorCopyAttribute((CTFontDescriptorRef)CFArrayGetValueAtIndex(fileDescs, i), kCTFontNameAttribute);
				Beefy::String nameStr;
				BFCFStringToUTF8(name, nameStr);
				faceNames->Add(nameStr);
				if (name != NULL)
					CFRelease(name);
			}
			CFRelease(fileDescs);
		}
	}

	if (faceNames->size() <= 1)
		return 0;

	CFStringRef name = (CFStringRef)CTFontDescriptorCopyAttribute(desc, kCTFontNameAttribute);
	Beefy::String nameStr;
	BFCFStringToUTF8(name, nameStr);
	if (name != NULL)
		CFRelease(name);

	for (int i = 0; i < (int)faceNames->size(); i++)
	{
		if ((*faceNames)[i] == nameStr)
			return i;
	}
	return 0;
}

// Calls 'callback' once per installed font face. 'path' is "file@index" for faces after the first in a
// collection, the form FTFont understands. 'isRegular' is set for upright, normal-weight faces,
// which also get registered under their bare family name.
BF_EXPORT void BF_CALLTYPE BFFont_EnumSystemFonts(BFFontEnumCallback callback, void* userData)
{
	CTFontCollectionRef collection = CTFontCollectionCreateFromAvailableFonts(NULL);
	if (collection == NULL)
		return;
	CFArrayRef descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection);
	CFRelease(collection);
	if (descriptors == NULL)
		return;

	Beefy::String familyStr;
	Beefy::String styleStr;
	Beefy::String pathStr;
	Beefy::Dictionary<Beefy::String, Beefy::Array<Beefy::String>> faceNameCache;
	char path[PATH_MAX];

	CFIndex count = CFArrayGetCount(descriptors);
	for (CFIndex i = 0; i < count; i++)
	{
		CTFontDescriptorRef desc = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, i);
		CFURLRef url = (CFURLRef)CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute);
		CFStringRef family = (CFStringRef)CTFontDescriptorCopyAttribute(desc, kCTFontFamilyNameAttribute);
		CFStringRef style = (CFStringRef)CTFontDescriptorCopyAttribute(desc, kCTFontStyleNameAttribute);
		CFDictionaryRef traits = (CFDictionaryRef)CTFontDescriptorCopyAttribute(desc, kCTFontTraitsAttribute);

		// Families starting with '.' are private system UI fonts
		if ((url != NULL) && (CFURLGetFileSystemRepresentation(url, true, (UInt8*)path, PATH_MAX)) &&
			(BFCFStringToUTF8(family, familyStr)) && (!familyStr.IsEmpty()) && (!familyStr.StartsWith('.')))
		{
			BFCFStringToUTF8(style, styleStr);

			bool isRegular = true;
			if (traits != NULL)
			{
				uint32 symTraits = 0;
				CFNumberRef symTraitsNum = (CFNumberRef)CFDictionaryGetValue(traits, kCTFontSymbolicTrait);
				if (symTraitsNum != NULL)
					CFNumberGetValue(symTraitsNum, kCFNumberSInt32Type, &symTraits);

				double weight = 0;
				CFNumberRef weightNum = (CFNumberRef)CFDictionaryGetValue(traits, kCTFontWeightTrait);
				if (weightNum != NULL)
					CFNumberGetValue(weightNum, kCFNumberDoubleType, &weight);

				isRegular = ((symTraits & (kCTFontItalicTrait | kCTFontBoldTrait)) == 0) && (fabs(weight) < 0.01);
			}

			pathStr = path;
			int faceIdx = BFGetFaceIndex(desc, url, pathStr, faceNameCache);
			if (faceIdx > 0)
				pathStr += Beefy::StrFormat("@%d", faceIdx);

			callback(familyStr.c_str(), styleStr.IsEmpty() ? NULL : styleStr.c_str(), pathStr.c_str(), isRegular ? 1 : 0, userData);
		}

		if (url != NULL)
			CFRelease(url);
		if (family != NULL)
			CFRelease(family);
		if (style != NULL)
			CFRelease(style);
		if (traits != NULL)
			CFRelease(traits);
	}

	CFRelease(descriptors);
}

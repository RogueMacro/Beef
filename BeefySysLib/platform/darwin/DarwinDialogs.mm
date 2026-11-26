// Native file dialogs for macOS (NSOpenPanel / NSSavePanel), called from corlib's System.IO dialogs.
// Compiled with ARC.

#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <fnmatch.h>
#include "Common.h"

enum BFFileDialogKind
{
	BFFileDialogKind_Open = 0,
	BFFileDialogKind_Save = 1,
	BFFileDialogKind_Folder = 2
};

enum BFFileDialogFlags
{
	BFFileDialogFlag_Multiselect = 1
};

enum BFFileDialogResult
{
	BFFileDialogResult_Error = -1,
	BFFileDialogResult_Cancel = 0,
	BFFileDialogResult_OK = 1
};

static NSString* BFToNSString(const char* str)
{
	if ((str == NULL) || (str[0] == 0))
		return nil;
	return [NSString stringWithUTF8String:str];
}

@interface BFFileDialogFilter : NSObject
@property (strong) NSString* desc;
@property (strong) NSArray<NSString*>* patterns;
@property bool matchesAll;
@end

@implementation BFFileDialogFilter
@end

@interface BFFileDialogDelegate : NSObject<NSOpenSavePanelDelegate>
@property (weak) NSSavePanel* panel;
@property (strong) NSArray<BFFileDialogFilter*>* filters;
@property NSInteger filterIdx;
@end

@implementation BFFileDialogDelegate

- (BFFileDialogFilter*)currentFilter
{
	if ((self.filterIdx >= 0) && (self.filterIdx < (NSInteger)self.filters.count))
		return self.filters[self.filterIdx];
	return nil;
}

- (BOOL)panel:(id)sender shouldEnableURL:(NSURL*)url
{
	BFFileDialogFilter* filter = [self currentFilter];
	if ((filter == nil) || (filter.matchesAll))
		return YES;

	NSNumber* isDir = nil;
	if (([url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil]) && (isDir.boolValue))
		return YES;

	const char* name = url.lastPathComponent.UTF8String;
	if (name == NULL)
		return NO;
	for (NSString* pattern in filter.patterns)
	{
		if (fnmatch(pattern.UTF8String, name, FNM_CASEFOLD) == 0)
			return YES;
	}
	return NO;
}

- (void)applyFilter
{
	if ([self.panel isKindOfClass:[NSOpenPanel class]])
	{
		// Open panels filter through panel:shouldEnableURL:, they just need a refresh
		[self.panel validateVisibleColumns];
		return;
	}

	// Save panels: give them the filter's extensions so a typed name gets the right one appended.
	// An empty list allows any type.
	NSMutableArray<UTType*>* types = [NSMutableArray array];
	BFFileDialogFilter* filter = [self currentFilter];
	if ((filter != nil) && (!filter.matchesAll))
	{
		for (NSString* pattern in filter.patterns)
		{
			if (![pattern hasPrefix:@"*."])
				continue;
			UTType* type = [UTType typeWithFilenameExtension:[pattern substringFromIndex:2]];
			if (type != nil)
				[types addObject:type];
		}
	}
	self.panel.allowedContentTypes = types;
}

- (void)filterChanged:(NSPopUpButton*)sender
{
	self.filterIdx = sender.indexOfSelectedItem;
	[self applyFilter];
}

@end

// Parses a Windows-style filter: "Desc|*.a;*.b|All files (*.*)|*.*"
static NSArray<BFFileDialogFilter*>* BFParseFilters(const char* filterStr)
{
	NSMutableArray<BFFileDialogFilter*>* filters = [NSMutableArray array];
	NSString* str = BFToNSString(filterStr);
	if (str == nil)
		return filters;

	NSArray<NSString*>* parts = [str componentsSeparatedByString:@"|"];
	for (NSUInteger i = 0; i + 1 < parts.count; i += 2)
	{
		BFFileDialogFilter* filter = [BFFileDialogFilter new];
		filter.desc = parts[i];
		NSMutableArray<NSString*>* patterns = [NSMutableArray array];
		for (NSString* rawPattern in [parts[i + 1] componentsSeparatedByString:@";"])
		{
			NSString* pattern = [rawPattern stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
			if (pattern.length == 0)
				continue;
			if (([pattern isEqualToString:@"*"]) || ([pattern isEqualToString:@"*.*"]))
				filter.matchesAll = true;
			[patterns addObject:pattern];
		}
		filter.patterns = patterns;
		[filters addObject:filter];
	}
	return filters;
}

static NSView* BFCreateFilterAccessory(BFFileDialogDelegate* delegate)
{
	NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	// Add through the menu so identical descriptions aren't collapsed into one item
	for (BFFileDialogFilter* filter in delegate.filters)
		[popup.menu addItemWithTitle:filter.desc action:NULL keyEquivalent:@""];
	[popup selectItemAtIndex:delegate.filterIdx];
	popup.target = delegate;
	popup.action = @selector(filterChanged:);

	NSTextField* label = [NSTextField labelWithString:@"Format:"];
	NSStackView* stack = [NSStackView stackViewWithViews:@[label, popup]];
	stack.edgeInsets = NSEdgeInsetsMake(8, 16, 8, 16);
	[stack setFrameSize:stack.fittingSize];
	return stack;
}

// Shows a modal file dialog. On OK, *outPaths receives the selected paths as consecutive
// NUL-terminated UTF-8 strings followed by an extra NUL; free it with BFFileDialog_FreeResult.
BF_EXPORT int32 BF_CALLTYPE BFFileDialog_Show(int32 kind, int32 flags, const char* title, const char* initialDir, const char* defaultName, const char* filter, char** outPaths)
{
	*outPaths = NULL;

	@autoreleasepool
	{
		NSWindow* prevKeyWindow = [NSApp keyWindow];

		NSSavePanel* panel = nil;
		if (kind == BFFileDialogKind_Save)
		{
			panel = [NSSavePanel savePanel];
		}
		else
		{
			NSOpenPanel* openPanel = [NSOpenPanel openPanel];
			bool wantFolder = (kind == BFFileDialogKind_Folder);
			openPanel.canChooseFiles = !wantFolder;
			openPanel.canChooseDirectories = wantFolder;
			openPanel.allowsMultipleSelection = (flags & BFFileDialogFlag_Multiselect) != 0;
			openPanel.resolvesAliases = YES;
			panel = openPanel;
		}
		if (panel == nil)
			return BFFileDialogResult_Error;

		panel.canCreateDirectories = YES;

		NSString* titleStr = BFToNSString(title);
		if (titleStr != nil)
		{
			// Modern macOS doesn't show panel titles, so also use it as the message
			panel.title = titleStr;
			panel.message = titleStr;
		}

		NSString* dirStr = BFToNSString(initialDir);
		if (dirStr != nil)
			panel.directoryURL = [NSURL fileURLWithPath:dirStr isDirectory:YES];

		NSString* nameStr = BFToNSString(defaultName);
		if ((nameStr != nil) && (kind == BFFileDialogKind_Save))
			panel.nameFieldStringValue = nameStr;

		// Kept alive for the duration of runModal; the panel only holds it weakly
		BFFileDialogDelegate* delegate = [BFFileDialogDelegate new];
		delegate.panel = panel;
		if (kind != BFFileDialogKind_Folder)
		{
			delegate.filters = BFParseFilters(filter);
			if (delegate.filters.count > 0)
			{
				panel.delegate = delegate;
				if (kind == BFFileDialogKind_Save)
					panel.allowsOtherFileTypes = YES;
				if (delegate.filters.count > 1)
				{
					panel.accessoryView = BFCreateFilterAccessory(delegate);
					if (kind == BFFileDialogKind_Open)
						((NSOpenPanel*)panel).accessoryViewDisclosed = YES;
				}
				[delegate applyFilter];
			}
		}

		NSModalResponse response = [panel runModal];
		panel.delegate = nil;
		if (prevKeyWindow != nil)
			[prevKeyWindow makeKeyAndOrderFront:nil];

		if (response != NSModalResponseOK)
			return BFFileDialogResult_Cancel;

		NSArray<NSURL*>* urls = nil;
		if (kind == BFFileDialogKind_Save)
			urls = (panel.URL != nil) ? @[panel.URL] : @[];
		else
			urls = ((NSOpenPanel*)panel).URLs;
		if (urls.count == 0)
			return BFFileDialogResult_Cancel;

		size_t totalSize = 1;
		for (NSURL* url in urls)
			totalSize += strlen(url.fileSystemRepresentation) + 1;

		char* result = (char*)malloc(totalSize);
		if (result == NULL)
			return BFFileDialogResult_Error;
		char* ptr = result;
		for (NSURL* url in urls)
		{
			const char* path = url.fileSystemRepresentation;
			size_t len = strlen(path) + 1;
			memcpy(ptr, path, len);
			ptr += len;
		}
		*ptr = 0;

		*outPaths = result;
		return BFFileDialogResult_OK;
	}
}

BF_EXPORT void BF_CALLTYPE BFFileDialog_FreeResult(char* paths)
{
	free(paths);
}

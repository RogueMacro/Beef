// Native macOS menu bar (NSMenu) behind BFWindow::AddMenuItem / ModifyMenuItem / RemoveMenuItem.
// Compiled with ARC.
//
// - The window's root menu maps onto [NSApp mainMenu]; its top-level items follow an application menu
//   (Services, Hide, Hide Others, Show All, Quit).
// - Shortcuts are display-only: the Beef side handles all key bindings itself, so AppKit must never match
//   them. Hot keys that fit an NSMenuItem key equivalent (one chord) are set as one only while their menu is
//   open (menuWillOpen / menuDidClose), so a closed menu bar has nothing to match. (Answering NO to
//   menuHasKeyEquivalent does not stop AppKit from matching.) Multi-chord hot keys are drawn after a tab.
// - Opening a menu calls mMenuItemSelectedFunc with the submenu (like WM_INITMENUPOPUP on Windows), which
//   runs the Beef update handlers. Clicking an item is queued and delivered from DarwinMenu_DispatchPending.

#import <AppKit/AppKit.h>
#include "Common.h"
#include "BFApp.h"
#include "BFWindow.h"
#include "util/Array.h"
#include "util/Dictionary.h"
#include "DarwinMenu.h"

USING_NS_BF;

static const int32 BFMenuId_Quit = -1;

class DarwinBFMenu : public BFMenu
{
public:
	int32					mId;
	BFWindow*				mWindow;
	bool					mIsRoot;
	NSMenuItem*				mItem; // nil for the root
	NSMenu*					mSubmenu; // the main menu for the root, else created with the first child
	String					mText;
	String					mHotKey;
	bool					mEnabled;
	NSString*				mKeyEquivalent; // nil if the hot key doesn't fit one
	NSEventModifierFlags	mKeyEquivalentMask;

public:
	DarwinBFMenu();
	~DarwinBFMenu();
};

static Dictionary<int32, DarwinBFMenu*> gMenuMap;
static Array<int32> gPendingSelections;
static int32 gNextMenuId = 0;
static DarwinBFMenu* gRootMenu = NULL;

@interface BFNativeMenu : NSMenu
@property int32 bfMenuId;
@property bool isOpen;
@end

static DarwinBFMenu* GetOwner(NSMenu* menu)
{
	if (![menu isKindOfClass:[BFNativeMenu class]])
		return NULL;
	DarwinBFMenu* bfMenu = NULL;
	gMenuMap.TryGetValue(((BFNativeMenu*)menu).bfMenuId, &bfMenu);
	return bfMenu;
}

static void ApplyKeyEquivalent(DarwinBFMenu* menu)
{
	NSMenuItem* item = menu->mItem;
	if ((item == nil) || (item.isSeparatorItem))
		return;
	NSMenu* parentMenu = item.menu;
	bool isOpen = ([parentMenu isKindOfClass:[BFNativeMenu class]]) && (((BFNativeMenu*)parentMenu).isOpen);
	if ((isOpen) && (menu->mKeyEquivalent != nil))
	{
		item.keyEquivalent = menu->mKeyEquivalent;
		item.keyEquivalentModifierMask = menu->mKeyEquivalentMask;
	}
	else
	{
		item.keyEquivalent = @"";
		item.keyEquivalentModifierMask = 0;
	}
}

static void SetMenuOpen(NSMenu* menu, bool isOpen)
{
	DarwinBFMenu* owner = GetOwner(menu);
	if (owner == NULL)
		return;
	((BFNativeMenu*)menu).isOpen = isOpen;
	for (auto child : owner->mBFMenuList)
		ApplyKeyEquivalent((DarwinBFMenu*)child);
}

@implementation BFNativeMenu
@end

@interface BFMenuHandler : NSObject<NSMenuDelegate>
@end

@implementation BFMenuHandler

- (void)itemSelected:(NSMenuItem*)sender
{
	// Not while a native modal (file dialog) runs: the Beef side is blocked inside it
	if (NSApp.modalWindow != nil)
		return;
	gPendingSelections.Add((int32)sender.tag);
}

- (void)quitSelected:(id)sender
{
	gPendingSelections.Add(BFMenuId_Quit);
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	if (NSApp.modalWindow != nil)
		return;
	DarwinBFMenu* bfMenu = GetOwner(menu);
	if (bfMenu == NULL)
		return;
	BFWindow* window = bfMenu->mWindow;
	if ((window != NULL) && (window->mMenuItemSelectedFunc != NULL))
		window->mMenuItemSelectedFunc(window, bfMenu);
}

- (void)menuWillOpen:(NSMenu*)menu
{
	SetMenuOpen(menu, true);
}

- (void)menuDidClose:(NSMenu*)menu
{
	SetMenuOpen(menu, false);
}

- (BOOL)menuHasKeyEquivalent:(NSMenu*)menu forEvent:(NSEvent*)event target:(id*)target action:(SEL*)action
{
	// Keys go to the window, where the Beef side runs the command bound to them. This alone isn't enough
	//  (AppKit still matches item key equivalents), hence ApplyKeyEquivalent
	return NO;
}

@end

static BFMenuHandler* gMenuHandler = nil;

DarwinBFMenu::DarwinBFMenu()
{
	mParent = NULL;
	mId = 0;
	mWindow = NULL;
	mIsRoot = false;
	mItem = nil;
	mSubmenu = nil;
	mEnabled = true;
	mKeyEquivalent = nil;
	mKeyEquivalentMask = 0;
}

static void DeleteTree(DarwinBFMenu* menu);

DarwinBFMenu::~DarwinBFMenu()
{
	if (mIsRoot)
	{
		// The window that owned this menu is going away: its items leave the menu bar, and the whole tree is
		// deleted (the Beef side never deletes those items once the window is gone)
		for (auto child : mBFMenuList)
			DeleteTree((DarwinBFMenu*)child);
		mBFMenuList.Clear();
		NSApp.helpMenu = nil;
	}

	gMenuMap.Remove(mId);
	if ((mItem != nil) && (mItem.menu != nil))
		[mItem.menu removeItem:mItem];
	if (gRootMenu == this)
		gRootMenu = NULL;
}

static BFMenuHandler* GetMenuHandler()
{
	if (gMenuHandler == nil)
		gMenuHandler = [[BFMenuHandler alloc] init];
	return gMenuHandler;
}

static NSString* ToNSString(const StringImpl& str)
{
	NSString* result = [[NSString alloc] initWithBytes:str.c_str() length:str.length() encoding:NSUTF8StringEncoding];
	return (result != nil) ? result : @"";
}

// "&Open File..." -> "Open File...", "&&" -> "&"
static NSString* StripMnemonic(const StringImpl& text)
{
	String result;
	for (int i = 0; i < text.length(); i++)
	{
		char c = text[i];
		if (c == '&')
		{
			if ((i + 1 < text.length()) && (text[i + 1] == '&'))
			{
				result += '&';
				i++;
			}
			continue;
		}
		result += c;
	}
	return ToNSString(result);
}

static bool GetKeyEquivalent(const StringImpl& keyName, NSString** outKey, NSEventModifierFlags* outFlags)
{
	auto FuncKey = [&](unichar c)
	{
		*outKey = [NSString stringWithCharacters:&c length:1];
		return true;
	};

	if (keyName.length() == 1)
	{
		char c = keyName[0];
		if ((c >= 'A') && (c <= 'Z'))
			c = c - 'A' + 'a';
		if (((c >= 'a') && (c <= 'z')) || ((c >= '0') && (c <= '9')) || (strchr("[]/\\`.,-=;'", c) != NULL))
		{
			*outKey = [NSString stringWithFormat:@"%c", c];
			return true;
		}
		return false;
	}

	if ((keyName.length() >= 2) && (keyName[0] == 'F') && (isdigit((uint8)keyName[1])))
	{
		int num = atoi(keyName.c_str() + 1);
		if ((num >= 1) && (num <= 35))
			return FuncKey(NSF1FunctionKey + num - 1);
		return false;
	}

	if ((keyName.length() == 7) && (keyName.StartsWith("Numpad")) && (isdigit((uint8)keyName[6])))
	{
		*outFlags |= NSEventModifierFlagNumericPad;
		*outKey = [NSString stringWithFormat:@"%c", keyName[6]];
		return true;
	}

	struct KeyEntry
	{
		const char* mName;
		unichar mChar;
		bool mNumPad;
	};

	static const KeyEntry keyEntries[] =
	{
		{ "Tab", '\t', false },
		{ "Return", '\r', false },
		{ "Escape", 0x1B, false },
		{ "Space", ' ', false },
		{ "Backspace", 0x08, false },
		{ "Delete", NSDeleteFunctionKey, false },
		{ "Insert", NSInsertFunctionKey, false },
		{ "Home", NSHomeFunctionKey, false },
		{ "End", NSEndFunctionKey, false },
		{ "PageUp", NSPageUpFunctionKey, false },
		{ "PageDown", NSPageDownFunctionKey, false },
		{ "Left", NSLeftArrowFunctionKey, false },
		{ "Up", NSUpArrowFunctionKey, false },
		{ "Right", NSRightArrowFunctionKey, false },
		{ "Down", NSDownArrowFunctionKey, false },
		{ "Pause", NSPauseFunctionKey, false },
		{ "Break", NSBreakFunctionKey, false },
		{ "Help", NSHelpFunctionKey, false },
		{ "Clear", NSClearDisplayFunctionKey, false },
		{ "Semicolon", ';', false },
		{ "Equals", '=', false },
		{ "Comma", ',', false },
		{ "Minus", '-', false },
		{ "Period", '.', false },
		{ "Tilde", '`', false },
		{ "Grave", '`', false },
		{ "Apostrophe", '\'', false },
		{ "Multiply", '*', true },
		{ "Add", '+', true },
		{ "Subtract", '-', true },
		{ "Decimal", '.', true },
		{ "Divide", '/', true },
	};

	for (auto& entry : keyEntries)
	{
		if (keyName == entry.mName)
		{
			if (entry.mNumPad)
				*outFlags |= NSEventModifierFlagNumericPad;
			return FuncKey(entry.mChar);
		}
	}
	return false;
}

// Parses a single-chord hot key like "Ctrl+Shift+F" (the leading '#' already removed)
static bool ParseHotKey(const StringImpl& hotKey, NSString** outKey, NSEventModifierFlags* outFlags)
{
	*outKey = nil;
	*outFlags = 0;
	if ((hotKey.IsEmpty()) || (hotKey.Contains(',')))
		return false;

	int start = 0;
	while (true)
	{
		int plusIdx = (int)hotKey.IndexOf('+', start);
		// A trailing '+' is the key itself ("Ctrl++")
		if ((plusIdx == -1) || (plusIdx == hotKey.length() - 1))
			break;

		String modName = hotKey.Substring(start, plusIdx - start);
		modName.Trim();
		if (modName.Equals("Ctrl", StringImpl::CompareKind_OrdinalIgnoreCase))
			*outFlags |= NSEventModifierFlagControl;
		else if (modName.Equals("Alt", StringImpl::CompareKind_OrdinalIgnoreCase))
			*outFlags |= NSEventModifierFlagOption;
		else if (modName.Equals("Shift", StringImpl::CompareKind_OrdinalIgnoreCase))
			*outFlags |= NSEventModifierFlagShift;
		else
			return false;
		start = plusIdx + 1;
	}

	String keyName = hotKey.Substring(start);
	keyName.Trim();
	if (keyName == "+")
		keyName = "Add";
	return GetKeyEquivalent(keyName, outKey, outFlags);
}

// "Ctrl+K, Ctrl+Shift+C" -> "⌃K, ⌃⇧C"
static NSString* MakeHotKeyDisplay(const StringImpl& hotKey)
{
	NSMutableString* result = [ToNSString(hotKey) mutableCopy];
	[result replaceOccurrencesOfString:@"Ctrl+" withString:@"⌃" options:0 range:NSMakeRange(0, result.length)];
	[result replaceOccurrencesOfString:@"Alt+" withString:@"⌥" options:0 range:NSMakeRange(0, result.length)];
	[result replaceOccurrencesOfString:@"Shift+" withString:@"⇧" options:0 range:NSMakeRange(0, result.length)];
	return result;
}

static void UpdateItem(DarwinBFMenu* menu)
{
	NSMenuItem* item = menu->mItem;
	if ((item == nil) || (item.isSeparatorItem))
		return;

	NSString* title = StripMnemonic(menu->mText);
	item.title = title;
	if (menu->mSubmenu != nil)
		menu->mSubmenu.title = title;
	item.enabled = menu->mEnabled;

	String hotKey = menu->mHotKey;
	if (hotKey.StartsWith('#'))
		hotKey.Remove(0, 1);

	NSString* keyEquivalent = nil;
	NSEventModifierFlags modifierMask = 0;
	bool hasKeyEquivalent = ParseHotKey(hotKey, &keyEquivalent, &modifierMask);
	menu->mKeyEquivalent = hasKeyEquivalent ? keyEquivalent : nil;
	menu->mKeyEquivalentMask = hasKeyEquivalent ? modifierMask : 0;
	ApplyKeyEquivalent(menu);
	if (hasKeyEquivalent)
	{
		item.attributedTitle = nil;
		return;
	}

	if ((hotKey.IsEmpty()) || (menu->mParent == NULL) || (((DarwinBFMenu*)menu->mParent)->mIsRoot))
	{
		item.attributedTitle = nil;
		return;
	}

	// No key equivalent can show it (several chords): draw it right-aligned after a tab
	NSFont* font = [NSFont menuFontOfSize:0];
	NSString* hotKeyText = MakeHotKeyDisplay(hotKey);
	CGFloat titleWidth = [title sizeWithAttributes:@{ NSFontAttributeName: font }].width;
	CGFloat hotKeyWidth = [hotKeyText sizeWithAttributes:@{ NSFontAttributeName: font }].width;

	NSMutableParagraphStyle* paraStyle = [[NSMutableParagraphStyle alloc] init];
	paraStyle.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:ceil(titleWidth + 32 + hotKeyWidth) options:@{}] ];

	// Attributed titles don't get the disabled look on their own
	NSColor* titleColor = menu->mEnabled ? nil : [NSColor tertiaryLabelColor];
	NSColor* hotKeyColor = menu->mEnabled ? [NSColor secondaryLabelColor] : [NSColor tertiaryLabelColor];

	NSMutableDictionary* titleAttrs = [@{ NSFontAttributeName: font, NSParagraphStyleAttributeName: paraStyle } mutableCopy];
	if (titleColor != nil)
		titleAttrs[NSForegroundColorAttributeName] = titleColor;
	NSMutableAttributedString* attrTitle = [[NSMutableAttributedString alloc] initWithString:[title stringByAppendingString:@"\t"] attributes:titleAttrs];
	[attrTitle appendAttributedString:[[NSAttributedString alloc] initWithString:hotKeyText attributes:@{
		NSFontAttributeName: font, NSParagraphStyleAttributeName: paraStyle, NSForegroundColorAttributeName: hotKeyColor }]];
	item.attributedTitle = attrTitle;
}

static BFNativeMenu* CreateSubmenu(DarwinBFMenu* owner)
{
	BFNativeMenu* submenu = [[BFNativeMenu alloc] initWithTitle:StripMnemonic(owner->mText)];
	submenu.bfMenuId = owner->mId;
	submenu.autoenablesItems = NO;
	submenu.delegate = GetMenuHandler();
	owner->mSubmenu = submenu;
	owner->mItem.submenu = submenu;
	return submenu;
}

static NSMenu* CreateApplicationMenu()
{
	NSString* appName = [[NSProcessInfo processInfo] processName];
	NSMenu* appMenu = [[NSMenu alloc] initWithTitle:appName];

	NSMenuItem* servicesItem = [appMenu addItemWithTitle:@"Services" action:nil keyEquivalent:@""];
	NSMenu* servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
	servicesItem.submenu = servicesMenu;
	NSApp.servicesMenu = servicesMenu;
	[appMenu addItem:[NSMenuItem separatorItem]];

	[appMenu addItemWithTitle:[@"Hide " stringByAppendingString:appName] action:@selector(hide:) keyEquivalent:@"h"];
	NSMenuItem* hideOthersItem = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
	hideOthersItem.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
	[appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
	[appMenu addItem:[NSMenuItem separatorItem]];

	NSMenuItem* quitItem = [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:appName] action:@selector(quitSelected:) keyEquivalent:@"q"];
	quitItem.target = GetMenuHandler();
	return appMenu;
}

// Number of main menu items before the BF root's items (the application menu)
static const int MainMenuPrefixCount = 1;

BFMenu* Beefy::DarwinMenu_CreateRoot(BFWindow* window)
{
	@autoreleasepool
	{
		[NSApplication sharedApplication];

		// Replaces SDL's default menu bar
		NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
		NSMenuItem* appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
		appItem.submenu = CreateApplicationMenu();
		[mainMenu addItem:appItem];
		NSApp.mainMenu = mainMenu;

		DarwinBFMenu* root = new DarwinBFMenu();
		root->mId = ++gNextMenuId;
		root->mWindow = window;
		root->mIsRoot = true;
		root->mSubmenu = mainMenu;
		gMenuMap[root->mId] = root;
		gRootMenu = root;
		return root;
	}
}

BFMenu* Beefy::DarwinMenu_AddItem(BFWindow* window, BFMenu* parent, int insertIdx, const char* text, const char* hotKey, bool enabled, int checkState, bool radioCheck)
{
	@autoreleasepool
	{
		DarwinBFMenu* parentMenu = (DarwinBFMenu*)((parent != NULL) ? parent : window->mMenu);
		if (parentMenu == NULL)
			return NULL;

		DarwinBFMenu* newMenu = new DarwinBFMenu();
		newMenu->mId = ++gNextMenuId;
		newMenu->mWindow = window;
		newMenu->mParent = parentMenu;
		gMenuMap[newMenu->mId] = newMenu;

		if (text != NULL)
		{
			newMenu->mItem = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(itemSelected:) keyEquivalent:@""];
			newMenu->mItem.target = GetMenuHandler();
			newMenu->mItem.tag = newMenu->mId;
		}
		else
			newMenu->mItem = [NSMenuItem separatorItem];

		NSMenu* parentNSMenu = parentMenu->mSubmenu;
		if (parentNSMenu == nil)
			parentNSMenu = CreateSubmenu(parentMenu);

		int nsIdx = insertIdx + (parentMenu->mIsRoot ? MainMenuPrefixCount : 0);
		nsIdx = BF_CLAMP(nsIdx, 0, (int)parentNSMenu.numberOfItems);
		[parentNSMenu insertItem:newMenu->mItem atIndex:nsIdx];

		// Menu bar items need a submenu to show anything
		if ((parentMenu->mIsRoot) && (text != NULL))
		{
			newMenu->mText = text;
			BFNativeMenu* submenu = CreateSubmenu(newMenu);
			if ([submenu.title isEqualToString:@"Help"])
				NSApp.helpMenu = submenu;
		}

		parentMenu->mBFMenuList.Insert(BF_MIN(insertIdx, (int)parentMenu->mBFMenuList.size()), newMenu);
		DarwinMenu_ModifyItem(newMenu, text, hotKey, enabled, checkState, radioCheck);
		return newMenu;
	}
}

void Beefy::DarwinMenu_ModifyItem(BFMenu* item, const char* text, const char* hotKey, bool enabled, int checkState, bool radioCheck)
{
	@autoreleasepool
	{
		DarwinBFMenu* menu = (DarwinBFMenu*)item;
		if (menu == NULL)
			return;

		// NULL text / hot key keeps the current one, as on Windows
		if (text != NULL)
			menu->mText = text;
		if (hotKey != NULL)
			menu->mHotKey = hotKey;
		menu->mEnabled = enabled;
		if ((menu->mItem != nil) && (checkState != -1))
			menu->mItem.state = (checkState == 1) ? NSControlStateValueOn : NSControlStateValueOff;
		UpdateItem(menu);
	}
}

static void UnregisterTree(DarwinBFMenu* menu)
{
	gMenuMap.Remove(menu->mId);
	for (auto child : menu->mBFMenuList)
		UnregisterTree((DarwinBFMenu*)child);
}

void Beefy::DarwinMenu_RemoveItem(BFMenu* item)
{
	@autoreleasepool
	{
		DarwinBFMenu* menu = (DarwinBFMenu*)item;
		if (menu == NULL)
			return;

		if (menu->mParent != NULL)
			menu->mParent->mBFMenuList.Remove(menu);
		if ((menu->mItem != nil) && (menu->mItem.menu != nil))
			[menu->mItem.menu removeItem:menu->mItem];
		if (NSApp.helpMenu == menu->mSubmenu)
			NSApp.helpMenu = nil;
		// Children stay allocated (the Beef side may still delete them), but are never dispatched again
		UnregisterTree(menu);
	}
}

static void DeleteTree(DarwinBFMenu* menu)
{
	for (auto child : menu->mBFMenuList)
		DeleteTree((DarwinBFMenu*)child);
	menu->mBFMenuList.Clear();
	delete menu;
}

void Beefy::DarwinMenu_DispatchPending()
{
	if (gPendingSelections.IsEmpty())
		return;

	Array<int32> pending;
	for (auto id : gPendingSelections)
		pending.Add(id);
	gPendingSelections.Clear();

	for (auto id : pending)
	{
		if (id == BFMenuId_Quit)
		{
			if (gRootMenu == NULL)
				continue;
			BFWindow* window = gRootMenu->mWindow;
			if ((window->mCloseQueryFunc == NULL) || (window->mCloseQueryFunc(window) != 0))
				gBFApp->RemoveWindow(window);
			continue;
		}

		DarwinBFMenu* menu = NULL;
		if (!gMenuMap.TryGetValue(id, &menu))
			continue;
		BFWindow* window = menu->mWindow;
		if ((window != NULL) && (window->mMenuItemSelectedFunc != NULL))
			window->mMenuItemSelectedFunc(window, menu);
	}
}

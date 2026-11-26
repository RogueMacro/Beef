#pragma once

// Native macOS menu bar (NSMenu) for BFWindows created with BFWINDOW_MENU.
// Implemented in DarwinMenu.mm; callers must link -framework AppKit.

#include "Common.h"

NS_BF_BEGIN;

class BFMenu;
class BFWindow;

// Creates the root menu for a window. Its top-level items go into the application's main menu bar,
// after the application menu. Deleting the root removes them again.
BFMenu* DarwinMenu_CreateRoot(BFWindow* window);
BFMenu* DarwinMenu_AddItem(BFWindow* window, BFMenu* parent, int insertIdx, const char* text, const char* hotKey, bool enabled, int checkState, bool radioCheck);
void DarwinMenu_ModifyItem(BFMenu* item, const char* text, const char* hotKey, bool enabled, int checkState, bool radioCheck);
void DarwinMenu_RemoveItem(BFMenu* item);
// Menu item clicks happen inside AppKit's event handling (inside SDL_PollEvent). They are queued and
// delivered to BFWindow::mMenuItemSelectedFunc from here, once the event loop is done.
void DarwinMenu_DispatchPending();

NS_BF_END;

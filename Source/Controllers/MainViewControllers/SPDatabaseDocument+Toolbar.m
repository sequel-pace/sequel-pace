//
//  SPDatabaseDocument+Toolbar.m
//  Sequel PAce
//
//  Copyright (c) 2002-2003 Lorenz Textor. All rights reserved.
//  Copyright (c) 2012 Sequel Pro Team. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.
//

#import "SPDatabaseDocument.h"
#import "SPConnectionController.h"
#import "SPTablesList.h"
#import "SPFileHandle.h"
#import "SPKeychain.h"
#import "SPTableContent.h"
#import "SPCustomQuery.h"
#import "SPDataImport.h"
#import "SPExportController.h"
#import "SPSplitView.h"
#import "SPQueryController.h"
#import "SPNavigatorController.h"
#import "SPSQLParser.h"
#import "SPTableData.h"
#import "SPDatabaseData.h"
#import "SPExtendedTableInfo.h"
#import "SPHistoryController.h"
#import "SPPreferenceController.h"
#import "SPUserManager.h"
#import "SPEncodingPopupAccessory.h"
#import "SPProcessListController.h"
#import "SPServerVariablesController.h"
#import "SPLogger.h"
#import "SPDebugLogger.h"
#import "SPDatabaseCopy.h"
#import "SPTableCopy.h"
#import "SPDatabaseRename.h"
#import "SPTableRelations.h"
#import "SPCopyTable.h"
#import "SPServerSupport.h"
#import "SPTooltip.h"
#import "SPThreadAdditions.h"
#import "RegexKitLite.h"
#import "SPTextView.h"
#import "SPFavoriteColorSupport.h"
#import "SPCharsetCollationHelper.h"
#import "SPGotoDatabaseController.h"
#import "SPFunctions.h"
#import "SPCreateDatabaseInfo.h"
#import "SPAppController.h"
#import "SPBundleHTMLOutputController.h"
#import "SPTableTriggers.h"
#import "SPTableStructure.h"
#import "SPPrintAccessory.h"
#import "MGTemplateEngine.h"
#import "ICUTemplateMatcher.h"
#import "SPFavoritesOutlineView.h"
#import "SPSSHTunnel.h"
#import "SPHelpViewerClient.h"
#import "SPHelpViewerController.h"
#import "SPPrintUtility.h"
#import "SPBundleManager.h"
#import "sequel-pace-Swift.h"
#import "SPPostgresConnection.h"
#import "SPPostgresStreamingResultStore.h"

// Forward declaration of private properties/methods used by this category
@interface SPDatabaseDocument ()
@property (nonatomic, strong) NSImage *hideConsoleImage;
@property (nonatomic, strong) NSImage *showConsoleImage;
@property (nonatomic, strong) NSImage *textAndCommandMacwindowImage API_AVAILABLE(macos(11.0));
@property (readwrite, nonatomic, strong) NSToolbar *mainToolbar;
- (void)_addPreferenceObservers;
- (void)_removePreferenceObservers;
@end

@implementation SPDatabaseDocument (Toolbar)

#pragma mark -
#pragma mark Titlebar Methods

/**
 * Update the window title.
 */
- (void)updateWindowTitle:(id)sender {
    // Ensure a call on the main thread
    if (![NSThread isMainThread]) {
        return [[self onMainThread] updateWindowTitle:sender];
    }

    // Determine name details
    NSString *pathName = @"";
    if ([[[self fileURL] path] length] && ![self isUntitled]) {
        pathName = [NSString stringWithFormat:@"%@ — ", [[[self fileURL] path] lastPathComponent]];
    }

    if ([connectionController isConnecting]) {
        NSString *title = NSLocalizedString(@"Connecting…", @"window title string indicating that sp is connecting");
        [self.parentWindowController updateWindowWithTitle:title tabTitle:title];
    } else if (!_isConnected) {
        NSString *title = [NSString stringWithFormat:@"%@%@", pathName, [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString*)kCFBundleNameKey]];
        [self.parentWindowController updateWindowWithTitle:title tabTitle:title];
    } else {
        NSMutableString *windowTitle = [NSMutableString string];

        // Add the path to the window title
        [windowTitle appendString:pathName];

        // Add the PostgreSQL version to the window title if enabled in prefs
        if ([prefs boolForKey:SPDisplayServerVersionInWindowTitle]) {
            [windowTitle appendFormat:@"(PostgreSQL %@) ", postgresVersion];
        }

        NSMutableString *tabTitle = [NSMutableString string];

        // Add the name to the window
        [windowTitle appendString:[self name]];
        [tabTitle appendString:[self name]];

        // If a database is selected, add to the window - and other tabs if host is the same but db different or table is not set
        if ([self database]) {
            [windowTitle appendFormat:@"/%@", [self database]];
            [tabTitle appendFormat:@"/%@", [self database]];
        }

        // Add the table name if one is selected
        if ([[self table] length]) {
            [windowTitle appendFormat:@"/%@", [self table]];
            [tabTitle appendFormat:@"/%@", [self table]];
        }
        [self.parentWindowController updateWindowWithTitle:windowTitle tabTitle:tabTitle];
        [self.parentWindowController updateWindowAccessoryWithColor:[[SPFavoriteColorSupport sharedInstance] colorForIndex:[connectionController colorIndex]] isSSL:[self.connectionController isConnectedViaSSL]];
    }
}

#pragma mark -
#pragma mark Toolbar Methods

/**
 * Return the identifier for the currently selected toolbar item, or nil if none is selected.
 */
- (NSString *)selectedToolbarItemIdentifier
{
    return [self.mainToolbar selectedItemIdentifier];
}

/**
 * toolbar delegate method
 */
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)willBeInsertedIntoToolbar {
    NSToolbarItem *toolbarItem = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];

    if ([itemIdentifier isEqualToString:SPMainToolbarDatabaseSelection]) {
        [toolbarItem setLabel:NSLocalizedString(@"Select Database", @"toolbar item for selecting a db")];
        [toolbarItem setPaletteLabel:[toolbarItem label]];
        [toolbarItem setView:chooseDatabaseButton];
        [chooseDatabaseButton setTarget:self];
        [chooseDatabaseButton setAction:@selector(chooseDatabase:)];
        [chooseDatabaseButton setEnabled:(_isConnected && !_isWorkingLevel)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarHistoryNavigation]) {
        [toolbarItem setLabel:NSLocalizedString(@"Table History", @"toolbar item for navigation history")];
        [toolbarItem setPaletteLabel:[toolbarItem label]];
        // At some point after 10.9 the sizing of NSSegmentedControl changed, resulting in clipping in newer OS X versions.
        // We can't just adjust the XIB, because then it would be wrong for older versions (possibly resulting in drawing artifacts),
        // so we have the OS determine the proper size at runtime.
        [historyControl sizeToFit];
        [toolbarItem setView:historyControl];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarShowConsole]) {
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Show Console", @"show console")];
        [toolbarItem setToolTip:NSLocalizedString(@"Show the console which shows all SQL commands performed by Sequel PAce", @"tooltip for toolbar item for show console")];

        [toolbarItem setLabel:NSLocalizedString(@"Console", @"Console")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:self.textAndCommandMacwindowImage];
        } else {
            [toolbarItem setImage:self.hideConsoleImage];
        }

        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(showConsole)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarClearConsole]) {
        //set the text label to be displayed in the toolbar and customization palette
        [toolbarItem setLabel:NSLocalizedString(@"Clear Console", @"toolbar item for clear console")];
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Clear Console", @"toolbar item for clear console")];
        //set up tooltip and image
        [toolbarItem setToolTip:NSLocalizedString(@"Clear the console which shows all SQL commands performed by Sequel PAce", @"tooltip for toolbar item for clear console")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:self.textAndCommandMacwindowImage];
        } else {
            [toolbarItem setImage:[NSImage imageNamed:@"clearconsole"]];
        }
        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(clearConsole:)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarTableStructure]) {
        [toolbarItem setLabel:NSLocalizedString(@"Structure", @"toolbar item label for switching to the Table Structure tab")];
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Edit Table Structure", @"toolbar item label for switching to the Table Structure tab")];
        //set up tooltip and image
        [toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Structure tab", @"tooltip for toolbar item for switching to the Table Structure tab")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:[NSImage imageWithSystemSymbolName:@"scale.3d" accessibilityDescription:nil]];
        } else {
            [toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-structure"]];
        }
        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(viewStructure)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarTableContent]) {
        [toolbarItem setLabel:NSLocalizedString(@"Content", @"toolbar item label for switching to the Table Content tab")];
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Browse & Edit Table Content", @"toolbar item label for switching to the Table Content tab")];
        //set up tooltip and image
        [toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Content tab", @"tooltip for toolbar item for switching to the Table Content tab")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:[NSImage imageWithSystemSymbolName:@"text.justify" accessibilityDescription:nil]];
        } else {
            [toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-browse"]];
        }
        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(viewContent)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarCustomQuery]) {
        [toolbarItem setLabel:NSLocalizedString(@"Query", @"toolbar item label for switching to the Run Query tab")];
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Run Custom Query", @"toolbar item label for switching to the Run Query tab")];
        //set up tooltip and image
        [toolbarItem setToolTip:NSLocalizedString(@"Switch to the Run Query tab", @"tooltip for toolbar item for switching to the Run Query tab")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:[NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:nil]];
        } else {
            [toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-sql"]];
        }
        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(viewQuery)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarTableInfo]) {
        [toolbarItem setLabel:NSLocalizedString(@"Table Info", @"toolbar item label for switching to the Table Info tab")];
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Table Info", @"toolbar item label for switching to the Table Info tab")];
        //set up tooltip and image
        [toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Info tab", @"tooltip for toolbar item for switching to the Table Info tab")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:[NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:nil]];
        } else {
            [toolbarItem setImage:[NSImage imageNamed:NSImageNameInfo]];
        }
        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(viewStatus)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarTableRelations]) {
        [toolbarItem setLabel:NSLocalizedString(@"Relations", @"toolbar item label for switching to the Table Relations tab")];
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Table Relations", @"toolbar item label for switching to the Table Relations tab")];
        //set up tooltip and image
        [toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Relations tab", @"tooltip for toolbar item for switching to the Table Relations tab")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:[NSImage imageWithSystemSymbolName:@"arrow.2.squarepath" accessibilityDescription:nil]];
        } else {
            [toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-table-relations"]];
        }
        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(viewRelations)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarTableTriggers]) {
        [toolbarItem setLabel:NSLocalizedString(@"Triggers", @"toolbar item label for switching to the Table Triggers tab")];
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Table Triggers", @"toolbar item label for switching to the Table Triggers tab")];
        //set up tooltip and image
        [toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Triggers tab", @"tooltip for toolbar item for switching to the Table Triggers tab")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:[NSImage imageWithSystemSymbolName:@"bolt.circle" accessibilityDescription:nil]];
        } else {
            [toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-table-triggers"]];
        }
        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(viewTriggers)];

    } else if ([itemIdentifier isEqualToString:SPMainToolbarUserManager]) {
        [toolbarItem setLabel:NSLocalizedString(@"Users", @"toolbar item label for switching to the User Manager tab")];
        [toolbarItem setPaletteLabel:NSLocalizedString(@"Users", @"toolbar item label for switching to the User Manager tab")];
        //set up tooltip and image
        [toolbarItem setToolTip:NSLocalizedString(@"Switch to the User Manager tab", @"tooltip for toolbar item for switching to the User Manager tab")];
        if (@available(macOS 11.0, *)) {
            [toolbarItem setImage:[NSImage imageWithSystemSymbolName:@"person.3" accessibilityDescription:nil]];
        } else {
            [toolbarItem setImage:[NSImage imageNamed:NSImageNameUserGroup]];
        }
        //set up the target action
        [toolbarItem setTarget:self];
        [toolbarItem setAction:@selector(showUserManager)];

    } else {
        //itemIdentifier refered to a toolbar item that is not provided or supported by us or cocoa
        toolbarItem = nil;
    }

    return toolbarItem;
}

- (void)toolbarWillAddItem:(NSNotification *)notification
{
    NSToolbarItem *toAdd = [[notification userInfo] objectForKey:@"item"];

    if([[toAdd itemIdentifier] isEqualToString:SPMainToolbarDatabaseSelection]) {
        chooseDatabaseToolbarItem = toAdd;
    }
}

- (void)toolbarDidRemoveItem:(NSNotification *)notification
{
    NSToolbarItem *removed = [[notification userInfo] objectForKey:@"item"];

    if([[removed itemIdentifier] isEqualToString:SPMainToolbarDatabaseSelection]) {
        chooseDatabaseToolbarItem = nil;
    }
}

/**
 * toolbar delegate method
 */
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
    return @[
        SPMainToolbarDatabaseSelection,
        SPMainToolbarHistoryNavigation,
        SPMainToolbarShowConsole,
        SPMainToolbarClearConsole,
        SPMainToolbarTableStructure,
        SPMainToolbarTableContent,
        SPMainToolbarCustomQuery,
        SPMainToolbarTableInfo,
        SPMainToolbarTableRelations,
        SPMainToolbarTableTriggers,
        SPMainToolbarUserManager,
        NSToolbarCustomizeToolbarItemIdentifier,
        NSToolbarFlexibleSpaceItemIdentifier,
        NSToolbarSpaceItemIdentifier,
        NSToolbarSeparatorItemIdentifier
    ];
}

/**
 * toolbar delegate method
 */
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
    return @[
        SPMainToolbarDatabaseSelection,
        NSToolbarSpaceItemIdentifier,
        SPMainToolbarTableStructure,
        SPMainToolbarTableContent,
        SPMainToolbarTableRelations,
        SPMainToolbarTableTriggers,
        SPMainToolbarTableInfo,
        SPMainToolbarCustomQuery,
        NSToolbarSpaceItemIdentifier,
        SPMainToolbarHistoryNavigation,
        NSToolbarSpaceItemIdentifier,
        SPMainToolbarUserManager,
        SPMainToolbarShowConsole
    ];
}

/**
 * toolbar delegate method
 */
- (NSArray *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar
{
    return @[
        SPMainToolbarTableStructure,
        SPMainToolbarTableContent,
        SPMainToolbarCustomQuery,
        SPMainToolbarTableInfo,
        SPMainToolbarTableRelations,
        SPMainToolbarTableTriggers
    ];

}

/**
 * Validates the toolbar items - JCS NOTE: this is called loads!
 */
- (BOOL)validateToolbarItem:(NSToolbarItem *)toolbarItem
{
    if (!_isConnected || _isWorkingLevel) return NO;

    NSString *identifier = [toolbarItem itemIdentifier];

    // Show console item
    if ([identifier isEqualToString:SPMainToolbarShowConsole]) {
        NSWindow *queryWindow = [[SPQueryController sharedQueryController] window];

        if (@available(macOS 11.0, *)) {
            toolbarItem.image = self.textAndCommandMacwindowImage;
        } else {
            if ([queryWindow isVisible]) {
                toolbarItem.image = self.showConsoleImage;
            } else {
                toolbarItem.image = self.hideConsoleImage;
            }
        }

        if ([queryWindow isKeyWindow]) {
            return NO;
        } else {
            return YES;
        }
    }

    // Clear console item
    if ([identifier isEqualToString:SPMainToolbarClearConsole]) {
        return ([[SPQueryController sharedQueryController] consoleMessageCount] > 0);
    }

    if (![identifier isEqualToString:SPMainToolbarCustomQuery] && ![identifier isEqualToString:SPMainToolbarUserManager]) {
        return (([tablesListInstance tableType] == SPTableTypeTable) || ([tablesListInstance tableType] == SPTableTypeView));
    }

    return YES;
}


@end

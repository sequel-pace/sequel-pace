//
//  SPDatabaseDocument+ViewControl.m
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


// Forward declaration of private methods used by this category
@interface SPDatabaseDocument ()
- (void)_loadTabTask:(NSNumber *)tabViewItemIndexNumber;
- (void)_loadTableTask;
@end

@implementation SPDatabaseDocument (ViewControl)

#pragma mark - SPDatabaseViewController

#pragma mark Getters

/**
 * Returns the master database view, containing the tables list and views for
 * table setup and contents.
 */
- (NSView *)databaseView
{
    return parentView;
}

/**
 * Returns the name of the currently selected table/view/procedure/function.
 */
- (NSString *)table
{
    return selectedTableName;
}

/**
 * Returns the currently selected table type, or -1 if no table or multiple tables are selected
 */
- (SPTableType)tableType
{
    return selectedTableType;
}

/**
 * Returns YES if table source has already been loaded
 */
- (BOOL)structureLoaded
{
    return structureLoaded;
}

/**
 * Returns YES if table content has already been loaded
 */
- (BOOL)contentLoaded
{
    return contentLoaded;
}

/**
 * Returns YES if table status has already been loaded
 */
- (BOOL)statusLoaded
{
    return statusLoaded;
}

#pragma mark -
#pragma mark Tab view control and delegate methods

//WARNING: Might be called from code in background threads
- (void)viewStructure {

    SPMainQSync(^{
        // Cancel the selection if currently editing a view and unable to save
        if (![self couldCommitCurrentViewActions]) {
            [self.mainToolbar setSelectedItemIdentifier:*SPViewModeToMainToolbarMap[[self->prefs integerForKey:SPLastViewMode]]];
            return;
        }

        [self->tableTabView selectTabViewItemAtIndex:0];
        [self.mainToolbar setSelectedItemIdentifier:SPMainToolbarTableStructure];
        [self->spHistoryControllerInstance updateHistoryEntries];

        [self->prefs setInteger:SPStructureViewMode forKey:SPLastViewMode];

    });
}

- (void)viewContent {
    SPMainQSync(^{
        // Cancel the selection if currently editing a view and unable to save
        if (![self couldCommitCurrentViewActions]) {
            [self.mainToolbar setSelectedItemIdentifier:*SPViewModeToMainToolbarMap[[self->prefs integerForKey:SPLastViewMode]]];
            return;
        }

        [self->tableTabView selectTabViewItemAtIndex:1];
        [self.mainToolbar setSelectedItemIdentifier:SPMainToolbarTableContent];
        [self->spHistoryControllerInstance updateHistoryEntries];
        [self->prefs setInteger:SPContentViewMode forKey:SPLastViewMode];
    });
}

- (void)viewQuery {
    SPMainQSync(^{
        // Cancel the selection if currently editing a view and unable to save
        if (![self couldCommitCurrentViewActions]) {
            [self.mainToolbar setSelectedItemIdentifier:*SPViewModeToMainToolbarMap[[self->prefs integerForKey:SPLastViewMode]]];
            return;
        }

        [self->tableTabView selectTabViewItemAtIndex:2];
        [self.mainToolbar setSelectedItemIdentifier:SPMainToolbarCustomQuery];
        [self->spHistoryControllerInstance updateHistoryEntries];

        // Set the focus on the text field
        [[self.parentWindowController window] makeFirstResponder:self->customQueryTextView];

        [self->prefs setInteger:SPQueryEditorViewMode forKey:SPLastViewMode];
    });

}

- (void)viewStatus {
    SPMainQSync(^{
        // Cancel the selection if currently editing a view and unable to save
        if (![self couldCommitCurrentViewActions]) {
            [self.mainToolbar setSelectedItemIdentifier:*SPViewModeToMainToolbarMap[[self->prefs integerForKey:SPLastViewMode]]];
            return;
        }

        [self->tableTabView selectTabViewItemAtIndex:3];
        [self.mainToolbar setSelectedItemIdentifier:SPMainToolbarTableInfo];
        [self->spHistoryControllerInstance updateHistoryEntries];

        if ([[self table] length]) {
            [self->extendedTableInfoInstance loadTable:[self table]];
        }

        [[self.parentWindowController window] makeFirstResponder:[self->extendedTableInfoInstance valueForKeyPath:@"tableCreateSyntaxTextView"]];

        [self->prefs setInteger:SPTableInfoViewMode forKey:SPLastViewMode];
    });

}

- (void)viewRelations {
    SPMainQSync(^{
        // Cancel the selection if currently editing a view and unable to save
        if (![self couldCommitCurrentViewActions]) {
            [self.mainToolbar setSelectedItemIdentifier:*SPViewModeToMainToolbarMap[[self->prefs integerForKey:SPLastViewMode]]];
            return;
        }

        [self->tableTabView selectTabViewItemAtIndex:4];
        [self.mainToolbar setSelectedItemIdentifier:SPMainToolbarTableRelations];
        [self->spHistoryControllerInstance updateHistoryEntries];

        [self->prefs setInteger:SPRelationsViewMode forKey:SPLastViewMode];
    });

}

- (void)viewTriggers {
    SPMainQSync(^{
        // Cancel the selection if currently editing a view and unable to save
        if (![self couldCommitCurrentViewActions]) {
            [self.mainToolbar setSelectedItemIdentifier:*SPViewModeToMainToolbarMap[[self->prefs integerForKey:SPLastViewMode]]];
            return;
        }

        [self->tableTabView selectTabViewItemAtIndex:5];
        [self.mainToolbar setSelectedItemIdentifier:SPMainToolbarTableTriggers];
        [self->spHistoryControllerInstance updateHistoryEntries];

        [self->prefs setInteger:SPTriggersViewMode forKey:SPLastViewMode];
    });
}

/**
 * Mark the structure tab for refresh when it's next switched to,
 * or reload the view if it's currently active
 */
- (void)setStructureRequiresReload:(BOOL)reload
{
    BOOL reloadRequired = reload;

    if ([self currentlySelectedView] == SPTableViewStructure) {
        reloadRequired = NO;
    }

    if (reloadRequired && selectedTableName) {
        [tableSourceInstance loadTable:selectedTableName];
    }
    else {
        structureLoaded = !reload;
    }
}

/**
 * Mark the content tab for refresh when it's next switched to,
 * or reload the view if it's currently active
 */
- (void)setContentRequiresReload:(BOOL)reload
{
    if (reload && selectedTableName
        && [self currentlySelectedView] == SPTableViewContent
        ) {
        [tableContentInstance loadTable:selectedTableName];
    }
    else {
        contentLoaded = !reload;
    }
}

/**
 * Mark the extended tab info for refresh when it's next switched to,
 * or reload the view if it's currently active
 */
- (void)setStatusRequiresReload:(BOOL)reload
{
    if (reload && selectedTableName
        && [self currentlySelectedView] == SPTableViewStatus
        ) {
        [[extendedTableInfoInstance onMainThread] loadTable:selectedTableName];
    }
    else {
        statusLoaded = !reload;
    }
}

/**
 * Mark the relations tab for refresh when it's next switched to,
 * or reload the view if it's currently active
 */
- (void)setRelationsRequiresReload:(BOOL)reload
{
    if (reload && selectedTableName
        && [self currentlySelectedView] == SPTableViewRelations
        ) {
        [[tableRelationsInstance onMainThread] refreshRelations:self];
    }
    else {
        relationsLoaded = !reload;
    }
}

/**
 * Triggers a task to update the newly selected tab view, ensuring
 * the data is fully loaded and up-to-date.
 */
- (void)tabView:(NSTabView *)aTabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem
{
    [self startTaskWithDescription:[NSString stringWithFormat:NSLocalizedString(@"Loading %@...", @"Loading table task string"), [self table]]];

    // We can't pass aTabView or tabViewItem UI objects to a bg thread, but since the change should already
    // be done in *did*SelectTabViewItem we can just ask the tab view for the current selection index and use that
    SPTableViewType newView = [self currentlySelectedView];

    if ([NSThread isMainThread]) {
        [NSThread detachNewThreadWithName:SPCtxt(@"SPDatabaseDocument view load task", self)
                                   target:self
                                 selector:@selector(_loadTabTask:)
                                   object:@(newView)];
    }
    else {
        [self _loadTabTask:@(newView)];
    }
}


@end

//
//  SPDatabaseDocument+TableControl.m
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

@implementation SPDatabaseDocument (TableControl)

#pragma mark Table control

/**
 * Loads a specified table into the database view, and ensures it's selected in
 * the tables list.  Passing a table name of nil will deselect any currently selected
 * table, but will leave multiple selections intact.
 * If this method is supplied with the currently selected name, a reload rather than
 * a load will be triggered.
 */
- (void)loadTable:(NSString *)aTable ofType:(SPTableType)aTableType
{
    [SPDebugLogger log:@"[STEP 2] loadTable called for: %@, type: %ld", aTable, (long)aTableType];

    // Ensure a connection is still present
    if (![postgresConnection isConnected]){
        SPLog(@"![postgresConnection isConnected], returning");
        [SPDebugLogger log:@"[STEP 2] ERROR: Not connected, returning"];
        return;
    }

    // If the supplied table name was nil, clear the views.
    if (!aTable) {

        // Update the selected table name and type


        selectedTableType = SPTableTypeNone;

        // Clear the views
        [[tablesListInstance onMainThread] setSelectionState:nil];
        [tableSourceInstance loadTable:nil];
        [tableContentInstance loadTable:nil];
        [[extendedTableInfoInstance onMainThread] loadTable:nil];
        [[tableTriggersInstance onMainThread] resetInterface];
        [[tableRelationsInstance onMainThread] refreshRelations:self];
        structureLoaded = NO;
        contentLoaded = NO;
        statusLoaded = NO;
        triggersLoaded = NO;
        relationsLoaded = NO;

        // Update the window title
        [self updateWindowTitle:self];

        // Add a history entry
        [spHistoryControllerInstance updateHistoryEntries];

        // Notify listeners of the table change
        [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:SPTableChangedNotification object:self];

        return;
    }

    BOOL isReloading = (selectedTableName && [selectedTableName isEqualToString:aTable]);

    // Store the new name

    selectedTableName = [[NSString alloc] initWithString:aTable];
    selectedTableType = aTableType;

    // Start a task
    if (isReloading) {
        [self startTaskWithDescription:NSLocalizedString(@"Reloading...", @"Reloading table task string")];
    }
    else {
        [self startTaskWithDescription:[NSString stringWithFormat:NSLocalizedString(@"Loading %@...", @"Loading table task string"), aTable]];
    }

    // Update the tables list interface - also updates menus to reflect the selected table type
    [[tablesListInstance onMainThread] setSelectionState:[NSDictionary dictionaryWithObjectsAndKeys:aTable, @"name", [NSNumber numberWithInteger:aTableType], @"type", nil]];

    // If on the main thread, fire up a thread to deal with view changes and data loading;
    // if already on a background thread, make the changes on the existing thread.
    if ([NSThread isMainThread]) {
        [NSThread detachNewThreadWithName:SPCtxt(@"SPDatabaseDocument table load task", self)
                                   target:self
                                 selector:@selector(_loadTableTask)
                                   object:nil];
    }
    else {
        [self _loadTableTask];
    }
}

/**
 * In a threaded task, ensure that the supplied tab is loaded -
 * usually as a result of switching to it.
 */
- (void)_loadTabTask:(NSNumber *)tabViewItemIndexNumber
{
    @autoreleasepool {
        // If anything other than a single table or view is selected, don't proceed.
        if (![self table] || ([tablesListInstance tableType] != SPTableTypeTable && [tablesListInstance tableType] != SPTableTypeView)) {
            [self endTask];
            return;
        }

        // Get the tab view index and ensure the associated view is loaded
        SPTableViewType selectedTabViewIndex = (SPTableViewType)[tabViewItemIndexNumber integerValue];

        switch (selectedTabViewIndex) {
            case SPTableViewStructure:
                if (!structureLoaded) {
                    [tableSourceInstance loadTable:selectedTableName];
                    structureLoaded = YES;
                }
                break;
            case SPTableViewContent:
                if (!contentLoaded) {
                    [tableContentInstance loadTable:selectedTableName];
                    contentLoaded = YES;
                }
                break;
            case SPTableViewStatus:
                if (!statusLoaded) {
                    [[extendedTableInfoInstance onMainThread] loadTable:selectedTableName];
                    statusLoaded = YES;
                }
                break;
            case SPTableViewTriggers:
                if (!triggersLoaded) {
                    [[tableTriggersInstance onMainThread] loadTriggers];
                    triggersLoaded = YES;
                }
                break;
            case SPTableViewRelations:
                if (!relationsLoaded) {
                    [[tableRelationsInstance onMainThread] refreshRelations:self];
                    relationsLoaded = YES;
                }
                break;
            case SPTableViewCustomQuery:
            case SPTableViewInvalid:
                break;
        }

        [self endTask];
    }
}

/**
 * In a threaded task, load the currently selected table/view/proc/function.
 */
- (void)_loadTableTask
{
    [SPDebugLogger log:@"[STEP 3] _loadTableTask started on background thread"];

    @autoreleasepool {
        NSString *tableEncoding = nil;

        // Update the window title
        [self updateWindowTitle:self];

        // Reset table information caches and mark that all loaded views require their data reloading
        [tableDataInstance resetAllData];

        structureLoaded = NO;
        contentLoaded = NO;
        statusLoaded = NO;
        triggersLoaded = NO;
        relationsLoaded = NO;

        // Ensure status and details are fetched using UTF8
        NSString *previousEncoding = [postgresConnection encodingName];
        BOOL changeEncoding = ![previousEncoding hasPrefix:@"utf8"];

        if (changeEncoding) {
            [postgresConnection storeEncodingForRestoration];
            [postgresConnection setEncoding:@"utf8mb4"];
        }

        // Cache status information on the working thread
        [tableDataInstance updateStatusInformationForCurrentTable];

        // Check the current encoding against the table encoding to see whether
        // an encoding change and reset is required.  This also caches table information on
        // the working thread.
        if( selectedTableType == SPTableTypeView || selectedTableType == SPTableTypeTable) {

            // tableEncoding == nil indicates that there was an error while retrieving table data
            tableEncoding = [tableDataInstance tableEncoding];

            // If encoding is set to Autodetect, update the connection character set encoding to utf8mb4
            // This allows us to receive data encoded in various charsets as UTF-8 characters.
            if ([[prefs objectForKey:SPDefaultEncoding] intValue] == SPEncodingAutodetect) {
                if (![@"utf8mb4" isEqualToString:previousEncoding]) {
                    [self setConnectionEncoding:@"utf8mb4" reloadingViews:NO];
                    changeEncoding = NO;
                }
            }
        }

        if (changeEncoding) [postgresConnection restoreStoredEncoding];

        // Notify listeners of the table change now that the state is fully set up.
        [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:SPTableChangedNotification object:self];

        // Restore view states as appropriate
        [spHistoryControllerInstance restoreViewStates];

        // Load the currently selected view if looking at a table or view
        if (tableEncoding && (selectedTableType == SPTableTypeView || selectedTableType == SPTableTypeTable))
        {
            NSInteger selectedTabViewIndex = [[self onMainThread] currentlySelectedView];

            switch (selectedTabViewIndex) {
                case SPTableViewStructure:
                    [tableSourceInstance loadTable:selectedTableName];
                    structureLoaded = YES;
                    break;
                case SPTableViewContent:
                    [SPDebugLogger log:@"[STEP 4] Calling tableContentInstance loadTable"];
                    [tableContentInstance loadTable:selectedTableName];
                    contentLoaded = YES;
                    break;
                case SPTableViewStatus:
                    [[extendedTableInfoInstance onMainThread] loadTable:selectedTableName];
                    statusLoaded = YES;
                    break;
                case SPTableViewTriggers:
                    [[tableTriggersInstance onMainThread] loadTriggers];
                    triggersLoaded = YES;
                    break;
                case SPTableViewRelations:
                    [[tableRelationsInstance onMainThread] refreshRelations:self];
                    relationsLoaded = YES;
                    break;
            }
        }

        // Clear any views which haven't been loaded as they weren't visible.  Note
        // that this should be done after reloading visible views, instead of clearing all
        // views, to reduce UI operations and avoid resetting state unnecessarily.
        // Some views (eg TableRelations) make use of the SPTableChangedNotification and
        // so don't require manual clearing.
        if (!structureLoaded) [tableSourceInstance loadTable:nil];
        if (!contentLoaded) [tableContentInstance loadTable:nil];
        if (!statusLoaded) [[extendedTableInfoInstance onMainThread] loadTable:nil];
        if (!triggersLoaded) [[tableTriggersInstance onMainThread] resetInterface];

        // If the table row counts an inaccurate and require updating, trigger an update - no
        // action will be performed if not necessary
        [tableDataInstance updateAccurateNumberOfRowsForCurrentTableForcingUpdate:NO];

        SPMainQSync(^{
            // Update the "Show Create Syntax" window if it's already opened
            // according to the selected table/view/proc/func
            if ([[self getCreateTableSyntaxWindow] isVisible]) {
                [self showCreateTableSyntax:self];
            }
        });

        // Add a history entry
        @synchronized(self) {
            [spHistoryControllerInstance updateHistoryEntries];
        }
        // Empty the loading pool and exit the thread
        [self endTask];

        NSArray __block *triggeredCommands = nil;

        dispatch_sync(dispatch_get_main_queue(), ^{
            triggeredCommands = [SPBundleManager.shared bundleCommandsForTrigger:SPBundleTriggerActionTableChanged];
        });

        for(NSString* cmdPath in triggeredCommands)
        {
            NSArray *data = [cmdPath componentsSeparatedByString:@"|"];
            NSMenuItem *aMenuItem = [[NSMenuItem alloc] init];
            [aMenuItem setTag:0];
            [aMenuItem setToolTip:[data objectAtIndex:0]];

            // For HTML output check if corresponding window already exists
            BOOL stopTrigger = NO;
            if([(NSString*)[data objectAtIndex:2] length]) {
                BOOL correspondingWindowFound = NO;
                NSString *uuid = [data objectAtIndex:2];
                for(id win in [NSApp windows]) {
                    if([[[[win delegate] class] description] isEqualToString:@"SPBundleHTMLOutputController"]) {
                        if([[[win delegate] windowUUID] isEqualToString:uuid]) {
                            correspondingWindowFound = YES;
                            break;
                        }
                    }
                }
                if(!correspondingWindowFound) stopTrigger = YES;
            }
            if(!stopTrigger) {
                id firstResponder = [[NSApp keyWindow] firstResponder];
                if([[data objectAtIndex:1] isEqualToString:SPBundleScopeGeneral]) {
                    [SPBundleManager.shared executeBundleItemForApp:aMenuItem];
                }
                else if([[data objectAtIndex:1] isEqualToString:SPBundleScopeDataTable]) {
                    if([[[firstResponder class] description] isEqualToString:@"SPCopyTable"])
                        [[firstResponder onMainThread] executeBundleItemForDataTable:aMenuItem];
                }
                else if([[data objectAtIndex:1] isEqualToString:SPBundleScopeInputField]) {
                    if([firstResponder isKindOfClass:[NSTextView class]])
                        [[firstResponder onMainThread] executeBundleItemForInputField:aMenuItem];
                }
            }
        }
    }
}


@end

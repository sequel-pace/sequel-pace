//
//  SPDatabaseDocument+Print.m
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
- (void)_removePreferenceObservers;
@end

@implementation SPDatabaseDocument (Print)

#pragma mark - SPPrintController

/**
 * WebView delegate method.
 */
- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame {


    NSPrintOperation *op = [SPPrintUtility preparePrintOperationWithView:[[[printWebView mainFrame] frameView] documentView] printView:printWebView];

    /* -endTask has to be called first, since the toolbar caches the item enabled state before starting a sheet,
     * disables all items and restores the cached state after the sheet ends. Because the database chooser is disabled
     * during tasks, launching the sheet before calling -endTask first would result in the following flow:
     * - toolbar item caches database chooser state as disabled (because of the active task)
     * - sheet is shown
     * - endTask reenables database chooser (has no effect because of the open sheet)
     * - user dismisses sheet after some time
     * - toolbar item restores cached state and disables database chooser again
     * => Inconsistent UI: database chooser disabled when it should actually be enabled
     */
    if ([self isWorking]) [self endTask];

    [op runOperationModalForWindow:[self.parentWindowController window] delegate:self didRunSelector:nil contextInfo:nil];
}

/**
 * Loads the print document interface. The actual printing is done in the doneLoading delegate.
 */
- (void)printDocument {
    // Only display warning for the 'Table Content' view
    if ([self currentlySelectedView] == SPTableViewContent) {

        NSInteger rowLimit = [prefs integerForKey:SPPrintWarningRowLimit];

        // Result count minus one because the first element is the column names
        NSInteger resultRows = ([[tableContentInstance currentResult] count] - 1);

        if (resultRows > rowLimit) {

            NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to print the current content view of the table '%@'?\n\nIt currently contains %@ rows, which may take a significant amount of time to print.", @"continue to print informative message"), [self table], [NSNumberFormatter.decimalStyleFormatter stringFromNumber:[NSNumber numberWithLongLong:resultRows]]];
            [NSAlert createDefaultAlertWithTitle:NSLocalizedString(@"Continue to print?", @"continue to print message") message:message primaryButtonTitle:NSLocalizedString(@"Print", @"print button") primaryButtonHandler:^{
                [self startPrintDocumentOperation];
            } cancelButtonHandler:nil];
            return;
        }
    }

    [self startPrintDocumentOperation];
}

/**
 * Starts tge print document operation by spawning a new thread if required.
 */
- (void)startPrintDocumentOperation
{
    [self startTaskWithDescription:NSLocalizedString(@"Generating print document...", @"generating print document status message")];

    BOOL isTableInformation = ([self currentlySelectedView] == SPTableViewStatus);

    if ([NSThread isMainThread]) {
        printThread = [[NSThread alloc] initWithTarget:self selector:(isTableInformation) ? @selector(generateTableInfoHTMLForPrinting) : @selector(generateHTMLForPrinting) object:nil];
        [printThread setName:@"SPDatabaseDocument document generator"];

        [self enableTaskCancellationWithTitle:NSLocalizedString(@"Cancel", @"cancel button") callbackObject:self callbackFunction:@selector(generateHTMLForPrintingCallback)];

        [printThread start];
    }
    else {
        (isTableInformation) ? [self generateTableInfoHTMLForPrinting] : [self generateHTMLForPrinting];
    }
}

/**
 * HTML generation thread callback method.
 */
- (void)generateHTMLForPrintingCallback
{
    [self setTaskDescription:NSLocalizedString(@"Cancelling...", @"cancelling task status message")];

    // Cancel the print thread
    [printThread cancel];
}

/**
 * Loads the supplied HTML string in the print WebView.
 */
- (void)loadPrintWebViewWithHTMLString:(NSString *)HTMLString
{
    [[printWebView mainFrame] loadHTMLString:HTMLString baseURL:nil];


}

/**
 * Generates the HTML for the current view that is being printed.
 */
- (void)generateHTMLForPrinting
{
    @autoreleasepool {
        NSMutableDictionary *connection = [NSMutableDictionary dictionary];
        NSMutableDictionary *printData = [NSMutableDictionary dictionary];

        SPMainQSync(^{
            [connection setDictionary:[self connectionInformation]];
            [printData setObject:[self columnNames] forKey:@"columns"];
            SPTableViewType view = [self currentlySelectedView];

            NSString *heading = @"";

            // Table source view
            if (view == SPTableViewStructure) {

                NSDictionary *tableSource = [self->tableSourceInstance tableSourceForPrinting];

                NSInteger tableType = [self->tablesListInstance tableType];

                switch (tableType) {
                    case SPTableTypeTable:
                        heading = NSLocalizedString(@"Table Structure", @"table structure print heading");
                        break;
                    case SPTableTypeView:
                        heading = NSLocalizedString(@"View Structure", @"view structure print heading");
                        break;
                }

                NSArray *rows = [[NSArray alloc] initWithArray:
                                 [[tableSource objectForKey:@"structure"] objectsAtIndexes:
                                  [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, [[tableSource objectForKey:@"structure"] count] - 1)]]
                                 ];

                NSArray *indexes = [[NSArray alloc] initWithArray:
                                    [[tableSource objectForKey:@"indexes"] objectsAtIndexes:
                                     [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, [[tableSource objectForKey:@"indexes"] count] - 1)]]
                                    ];

                NSArray *indexColumns = [[tableSource objectForKey:@"indexes"] objectAtIndex:0];

                [printData setObject:rows forKey:@"rows"];
                [printData setObject:indexes forKey:@"indexes"];
                [printData setObject:indexColumns forKey:@"indexColumns"];

                if ([indexes count]) [printData setObject:@1 forKey:@"hasIndexes"];
            }
            // Table content view
            else if (view == SPTableViewContent) {

                NSArray *data = [self->tableContentInstance currentDataResultWithNULLs:NO hideBLOBs:YES];

                heading = NSLocalizedString(@"Table Content", @"table content print heading");

                NSArray *rows = [[NSArray alloc] initWithArray:
                                 [data objectsAtIndexes:
                                  [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, [data count] - 1)]]
                                 ];

                [printData setObject:rows forKey:@"rows"];
                [connection setValue:[self->tableContentInstance usedQuery] forKey:@"query"];
            }
            // Custom query view
            else if (view == SPTableViewCustomQuery) {

                NSArray *data = [self->customQueryInstance currentResult];

                heading = NSLocalizedString(@"Query Result", @"query result print heading");

                NSArray *rows = [[NSArray alloc] initWithArray:
                                 [data objectsAtIndexes:
                                  [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, [data count] - 1)]]
                                 ];

                [printData setObject:rows forKey:@"rows"];
                [connection setValue:[self->customQueryInstance usedQuery] forKey:@"query"];
            }
            // Table relations view
            else if (view == SPTableViewRelations) {

                NSArray *data = [self->tableRelationsInstance relationDataForPrinting];

                heading = NSLocalizedString(@"Table Relations", @"toolbar item label for switching to the Table Relations tab");

                NSArray *rows = [[NSArray alloc] initWithArray:
                                 [data objectsAtIndexes:
                                  [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, ([data count] - 1))]]
                                 ];

                [printData setObject:rows forKey:@"rows"];
            }
            // Table triggers view
            else if (view == SPTableViewTriggers) {

                NSArray *data = [self->tableTriggersInstance triggerDataForPrinting];

                heading = NSLocalizedString(@"Table Triggers", @"toolbar item label for switching to the Table Triggers tab");

                NSArray *rows = [[NSArray alloc] initWithArray:
                                 [data objectsAtIndexes:
                                  [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, ([data count] - 1))]]
                                 ];

                [printData setObject:rows forKey:@"rows"];
            }

            [printData setObject:heading forKey:@"heading"];
        });

        // Set up template engine with your chosen matcher
        MGTemplateEngine *engine = [MGTemplateEngine templateEngine];

        [engine setMatcher:[ICUTemplateMatcher matcherWithTemplateEngine:engine]];

        [engine setObject:connection forKey:@"c"];

        [printData setObject:@"Lucida Grande" forKey:@"font"];
        [printData setObject:([prefs boolForKey:SPDisplayTableViewVerticalGridlines]) ? @"1px solid #CCCCCC" : @"none" forKey:@"gridlines"];

        NSString *HTMLString = [engine processTemplateInFileAtPath:[[NSBundle mainBundle] pathForResource:SPHTMLPrintTemplate ofType:@"html"] withVariables:printData];

        // Check if the operation has been cancelled
        if ((printThread != nil) && (![NSThread isMainThread]) && ([printThread isCancelled])) {
            [self endTask];
            return;
        }

        [self performSelectorOnMainThread:@selector(loadPrintWebViewWithHTMLString:) withObject:HTMLString waitUntilDone:NO];
    }
}

/**
 * Generates the HTML for the table information view that is to be printed.
 */
- (void)generateTableInfoHTMLForPrinting
{
    @autoreleasepool {
        // Set up template engine with your chosen matcher
        MGTemplateEngine *engine = [MGTemplateEngine templateEngine];

        [engine setMatcher:[ICUTemplateMatcher matcherWithTemplateEngine:engine]];

        NSMutableDictionary *connection = [self connectionInformation];
        NSMutableDictionary *printData = [NSMutableDictionary dictionary];

        NSString *heading = NSLocalizedString(@"Table Information", @"table information print heading");

        [engine setObject:connection forKey:@"c"];
        [engine setObject:[[extendedTableInfoInstance onMainThread] tableInformationForPrinting] forKey:@"i"];

        [printData setObject:heading forKey:@"heading"];
        [printData setObject:[[NSUnarchiver unarchiveObjectWithData:[prefs objectForKey:SPCustomQueryEditorFont]] fontName] forKey:@"font"];

        NSString *HTMLString = [engine processTemplateInFileAtPath:[[NSBundle mainBundle] pathForResource:SPHTMLTableInfoPrintTemplate ofType:@"html"] withVariables:printData];

        // Check if the operation has been cancelled
        if ((printThread != nil) && (![NSThread isMainThread]) && ([printThread isCancelled])) {
            [self endTask];
            return;
        }

        [self performSelectorOnMainThread:@selector(loadPrintWebViewWithHTMLString:) withObject:HTMLString waitUntilDone:NO];
    }
}

/**
 * Returns an array of columns for whichever view is being printed.
 *
 * MUST BE CALLED ON THE UI THREAD!
 */
- (NSArray *)columnNames
{
    NSArray *columns = nil;

    SPTableViewType view = [self currentlySelectedView];

    // Table source view
    if ((view == SPTableViewStructure) && ([[tableSourceInstance tableSourceForPrinting] count] > 0)) {

        columns = [[NSArray alloc] initWithArray:[[[tableSourceInstance tableSourceForPrinting] objectForKey:@"structure"] objectAtIndex:0] copyItems:YES];
    }
    // Table content view
    else if ((view == SPTableViewContent) && ([[tableContentInstance currentResult] count] > 0)) {

        columns = [[NSArray alloc] initWithArray:[[tableContentInstance currentResult] objectAtIndex:0] copyItems:YES];
    }
    // Custom query view
    else if ((view == SPTableViewCustomQuery) && ([[customQueryInstance currentResult] count] > 0)) {

        columns = [[NSArray alloc] initWithArray:[[customQueryInstance currentResult] objectAtIndex:0] copyItems:YES];
    }
    // Table relations view
    else if ((view == SPTableViewRelations) && ([[tableRelationsInstance relationDataForPrinting] count] > 0)) {

        columns = [[NSArray alloc] initWithArray:[[tableRelationsInstance relationDataForPrinting] objectAtIndex:0] copyItems:YES];
    }
    // Table triggers view
    else if ((view == SPTableViewTriggers) && ([[tableTriggersInstance triggerDataForPrinting] count] > 0)) {

        columns = [[NSArray alloc] initWithArray:[[tableTriggersInstance triggerDataForPrinting] objectAtIndex:0] copyItems:YES];
    }

    return columns;
}

/**
 * Generates a dictionary of connection information that is used for printing.
 */
- (NSMutableDictionary *)connectionInformation
{
    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *versionForPrint = [NSString stringWithFormat:@"%@ %@ (%@ %@)",
                                 [infoDict objectForKey:@"CFBundleName"],
                                 [infoDict objectForKey:@"CFBundleShortVersionString"],
                                 NSLocalizedString(@"build", @"build label"),
                                 [infoDict objectForKey:@"CFBundleVersion"]];

    NSMutableDictionary *connection = [NSMutableDictionary dictionary];

    if ([[self user] length]) {
        [connection setValue:[self user] forKey:@"username"];
    }

    if ([[self table] length]) {
        [connection setValue:[self table] forKey:@"table"];
    }

    if ([connectionController port] && [[connectionController port] length]) {
        [connection setValue:[connectionController port] forKey:@"port"];
    }

    [connection setValue:[self host] forKey:@"hostname"];
    [connection setValue:selectedDatabase forKey:@"database"];
    [connection setValue:versionForPrint forKey:@"version"];

    return connection;
}

- (void)documentWillClose:(NSNotification *)notification {
    if ([notification.object isKindOfClass:[SPDatabaseDocument class]]) {
        SPDatabaseDocument *document = (SPDatabaseDocument *)[notification object];
        if (self == document) {

            NSAssert([NSThread isMainThread], @"Calling %s from a background thread is not supported!", __func__);

            [self closeConnection];

            // Unregister observers
            [self _removePreferenceObservers];

            [[NSNotificationCenter defaultCenter] removeObserver:self];
            [NSObject cancelPreviousPerformRequestsWithTarget:self];

            [taskProgressWindow close];

            if (processListController) [processListController close];

            // #2924: The connection controller doesn't retain its delegate (us), but it may outlive us (e.g. when running a bg thread)
            [connectionController setDelegate:nil];
            [printWebView setFrameLoadDelegate:nil];

            if (taskDrawTimer) {
                [taskDrawTimer invalidate];
            }
            if (queryExecutionTimer) {
                [queryExecutionTimer invalidate];
            }
        }
    }
}


@end

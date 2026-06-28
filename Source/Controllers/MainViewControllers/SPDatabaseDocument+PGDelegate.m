//
//  SPDatabaseDocument+PGDelegate.m
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
- (void)closeAndDisconnect;
@property (assign) BOOL appIsTerminating;
@end

@implementation SPDatabaseDocument (PGDelegate)

#pragma mark - SPPostgresConnection delegate methods

/**
 * Invoked when the framework is about to perform a query.
 */
- (void)willQueryString:(NSString *)query connection:(id)connection
{
    if ([prefs boolForKey:SPConsoleEnableLogging]) {
        if ((_queryMode == SPInterfaceQueryMode && [prefs boolForKey:SPConsoleEnableInterfaceLogging]) ||
            (_queryMode == SPCustomQueryQueryMode && [prefs boolForKey:SPConsoleEnableCustomQueryLogging]) ||
            (_queryMode == SPImportExportQueryMode && [prefs boolForKey:SPConsoleEnableImportExportLogging]))
        {
            [[SPQueryController sharedQueryController] showMessageInConsole:query connection:[self name] database:[self database]];
        }
    }
}

/**
 * Invoked when the query just executed by the framework resulted in an error.
 */
- (void)queryGaveError:(NSString *)error connection:(id)connection
{
    if ([prefs boolForKey:SPConsoleEnableLogging] && [prefs boolForKey:SPConsoleEnableErrorLogging]) {
        [[SPQueryController sharedQueryController] showErrorInConsole:error connection:[self name] database:[self database]];
    }
}

/**
 * Invoked when the current connection needs a password from the Keychain.
 */
- (NSString *)keychainPasswordForConnection:(SPPostgresConnection *)connection
{
    return [connectionController keychainPassword];
}

/**
 * Invoked when the current connection needs a ssh password from the Keychain.
 * This isn't actually part of the SPPostgresConnection delegate protocol, but is here
 * due to its similarity to the previous method.
 */
- (NSString *)keychainPasswordForSSHConnection:(SPPostgresConnection *)connection
{
    // If no keychain item is available, return an empty password
    NSString *password = [connectionController keychainPasswordForSSH];
    if (!password) return @"";

    return password;
}

/**
 * Invoked when an attempt was made to execute a query on the current connection, but the connection is not
 * actually active.
 */
- (void)noConnectionAvailable:(id)connection
{
    [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"No connection available", @"no connection available message") message:NSLocalizedString(@"An error has occurred and there doesn't seem to be a connection available.", @"no connection available informatie message") callback:nil];
}

/**
 * Invoked when the connection fails and the framework needs to know how to proceed.
 */
- (SPPostgresConnectionLostDecision)connectionLost:(id)connection
{

    SPLog(@"connectionLost");

    SPPostgresConnectionLostDecision connectionErrorCode = SPPostgresConnectionLostDisconnect;

    // Only display the reconnect dialog if the window is visible
    // and we are not terminating
    if ([self.parentWindowController window] && [[self.parentWindowController window] isVisible] && self.appIsTerminating == NO) {

        SPLog(@"not terminating, parentWindow isVisible, showing connectionErrorDialog");
        // Ensure the window isn't miniaturized
        if ([[self.parentWindowController window] isMiniaturized]) {
            [[self.parentWindowController window] deminiaturize:self];
        }
        [[self parentWindowControllerWindow] orderWindow:NSWindowAbove relativeTo:0];

        // Display the connection error dialog and wait for the return code
        [[self.parentWindowController window] beginSheet:connectionErrorDialog completionHandler:nil];
        connectionErrorCode = (SPPostgresConnectionLostDecision)[NSApp runModalForWindow:connectionErrorDialog];

        [NSApp endSheet:connectionErrorDialog];
        [connectionErrorDialog orderOut:nil];

        queryStartDate = [[NSDate alloc] init];

        // If 'disconnect' was selected, trigger a window close.
        if (connectionErrorCode == SPPostgresConnectionLostDisconnect) {
            [self performSelectorOnMainThread:@selector(closeAndDisconnect) withObject:nil waitUntilDone:YES];
        }
    }

    return connectionErrorCode;
}

/**
 * Invoke to display an informative but non-fatal error directly to the user.
 */
- (void)showErrorWithTitle:(NSString *)theTitle message:(NSString *)theMessage
{
    SPMainQSync(^{
        if ([[self.parentWindowController window] isVisible]) {
            [NSAlert createWarningAlertWithTitle:theTitle message:theMessage callback:nil];
        }
    });
}

/**
 * Invoked when user dismisses the error sheet displayed as a result of the current connection being lost.
 */
- (IBAction)closeErrorConnectionSheet:(id)sender
{
    [NSApp stopModalWithCode:[sender tag]];
}

/**
 * Close the connection - should be performed on the main thread.
 */
- (void)closeAndDisconnect {

    _isConnected = NO;

    [self.parentWindowControllerWindow orderOut:self];
    [self.parentWindowControllerWindow setAlphaValue:0.0f];
    [self.parentWindowControllerWindow performSelector:@selector(close) withObject:nil afterDelay:1.0];

    // if tab closed and there is text in the query view, safe to history
    NSString *queryString = [self->customQueryTextView.textStorage string];

    if([queryString length] > 0){
        [[SPQueryController sharedQueryController] addHistory:queryString forFileURL:[self fileURL]];
    }

    // Cancel autocompletion trigger
    if([prefs boolForKey:SPCustomQueryAutoComplete]) {
        [NSObject cancelPreviousPerformRequestsWithTarget:[customQueryInstance valueForKeyPath:@"textView"]
                                                 selector:@selector(doAutoCompletion)
                                                   object:nil];
    }
    if([prefs boolForKey:SPCustomQueryUpdateAutoHelp]) {
        [NSObject cancelPreviousPerformRequestsWithTarget:[customQueryInstance valueForKeyPath:@"textView"]
                                                 selector:@selector(autoHelp)
                                                   object:nil];
    }

    if (_isConnected) {
        [self closeConnection];
    } else {
        [connectionController cancelConnection:self];
    }
    if ([[[SPQueryController sharedQueryController] window] isVisible]) [self toggleConsole];
    [createTableSyntaxWindow orderOut:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSWindow *)parentWindowControllerWindow {
    return [self.parentWindowController window];
}


@end

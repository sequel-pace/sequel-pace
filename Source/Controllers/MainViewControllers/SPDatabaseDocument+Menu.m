//
//  SPDatabaseDocument+Menu.m
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
@end

@implementation SPDatabaseDocument (Menu)

#pragma mark -
#pragma mark Menu methods

/**
 * Saves SP session or if Custom Query tab is active the editor's content as SQL file
 * If sender == nil then the call came from [self writeSafelyToURL:ofType:forSaveOperation:error]
 */
- (IBAction)saveConnectionSheet:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    NSString *filename;
    NSString *contextInfo;

    [panel setAllowsOtherFileTypes:NO];
    [panel setCanSelectHiddenExtension:YES];

    // Save Query...
    if (sender != nil && [sender tag] == SPMainMenuFileSaveQuery) {

        // If Save was invoked, check whether the file was previously opened, and if so save without the panel
        if ([sender tag] == SPMainMenuFileSaveQuery && [[[self sqlFileURL] path] length]) {
            NSError *error = nil;
            NSString *content = [NSString stringWithString:[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string]];
            [content writeToURL:sqlFileURL atomically:YES encoding:sqlFileEncoding error:&error];
            return;
        }

        // Save the editor's content as SQL file
        [panel setAccessoryView:[SPEncodingPopupAccessory encodingAccessory:[prefs integerForKey:SPLastSQLFileEncoding]
                                                        includeDefaultEntry:NO
                                                              encodingPopUp:&encodingPopUp]];

        [panel setAllowedFileTypes:@[SPFileExtensionSQL]];

        if (![prefs stringForKey:@"lastSqlFileName"]) {
            [prefs setObject:@"" forKey:@"lastSqlFileName"];
        }

        filename = [prefs stringForKey:@"lastSqlFileName"];
        contextInfo = @"saveSQLfile";

        // If no lastSqlFileEncoding in prefs set it to UTF-8
        if (![prefs integerForKey:SPLastSQLFileEncoding]) {
            [prefs setInteger:4 forKey:SPLastSQLFileEncoding];
        }

        [encodingPopUp setEnabled:YES];
    }
    // Save Connection
    else if (sender == nil || [sender tag] == SPMainMenuFileSaveConnection) {

        // If Save was invoked check for fileURL and Untitled docs and save the spf file without save panel
        // otherwise ask for file name
        if (sender != nil && [sender tag] == SPMainMenuFileSaveConnection && [[[self fileURL] path] length] && ![self isUntitled]) {
            [self saveDocumentWithFilePath:nil inBackground:YES onlyPreferences:NO contextInfo:nil];
            return;
        }

        // Save current session (open connection windows as SPF file)
        [panel setAllowedFileTypes:@[SPFileExtensionDefault]];

        [self prepareSaveAccessoryViewWithPanel:panel];

        [self.saveConnectionIncludeQuery setEnabled:([[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string] length])];

        // Update accessory button states
        [self validateSaveConnectionAccessory:nil];

        // TODO note: it seems that one has problems with a NSSecureTextField inside an accessory view - ask HansJB
        [[self.saveConnectionEncryptString cell] setControlView:self.saveConnectionAccessory];
        [panel setAccessoryView:self.saveConnectionAccessory];

        // Set file name to the name of the connection
        filename = [self name];

        contextInfo = sender == nil ? @"saveSPFfileAndClose" : @"saveSPFfile";
    }
    // Save Session
    else if (sender == nil || [sender tag] == SPMainMenuFileSaveSession) {

        // Save current session (open connection windows as SPFS file)
        [panel setAllowedFileTypes:@[SPBundleFileExtension]];

        [self prepareSaveAccessoryViewWithPanel:panel];

        // Update accessory button states
        [self validateSaveConnectionAccessory:nil];
        [self.saveConnectionIncludeQuery setEnabled:YES];

        // TODO note: it seems that one has problems with a NSSecureTextField
        // inside an accessory view - ask HansJB
        [[self.saveConnectionEncryptString cell] setControlView:self.saveConnectionAccessory];
        [panel setAccessoryView:self.saveConnectionAccessory];

        // Set file name
        filename = [NSString stringWithFormat:NSLocalizedString(@"Session", @"Initial filename for 'Save session' file")];

        contextInfo = @"saveSession";
    }
    else {
        return;
    }

    [panel setNameFieldStringValue:filename];

    [panel beginSheetModalForWindow:[self.parentWindowController window] completionHandler:^(NSInteger returnCode) {
        [self saveConnectionPanelDidEnd:panel returnCode:returnCode contextInfo:contextInfo];
    }];
}
/**
 * Control the save connection panel's accessory view
 */
- (IBAction)validateSaveConnectionAccessory:(id)sender
{
    // [saveConnectionAutoConnect setEnabled:([saveConnectionSavePassword state] == NSControlStateValueOn)];
    [self.saveConnectionSavePasswordAlert setHidden:([self.saveConnectionSavePassword state] == NSControlStateValueOff)];

    // If user checks the Encrypt check box set focus to password field
    if (sender == self.saveConnectionEncrypt && [self.saveConnectionEncrypt state] == NSControlStateValueOn) [self.saveConnectionEncryptString selectText:sender];

    // Unfocus saveConnectionEncryptString
    if (sender == self.saveConnectionEncrypt && [self.saveConnectionEncrypt state] == NSControlStateValueOff) {
        // [saveConnectionEncryptString setStringValue:[saveConnectionEncryptString stringValue]];
        // TODO how can one make it better ?
        [[self.saveConnectionEncryptString window] makeFirstResponder:[[self.saveConnectionEncryptString window] initialFirstResponder]];
    }
}

- (void)saveConnectionPanelDidEnd:(NSSavePanel *)panel returnCode:(NSInteger)returnCode contextInfo:(NSString *)contextInfo
{
    [panel orderOut:nil]; // by default OS X hides the panel only after the current method is done

    if (returnCode == NSModalResponseOK) {

        NSString *fileName = [[panel URL] path];
        NSError *error = nil;

        // Save file as SQL file by using the chosen encoding
        if ([contextInfo isEqualToString:@"saveSQLfile"]) {

            [prefs setInteger:[[encodingPopUp selectedItem] tag] forKey:SPLastSQLFileEncoding];
            [prefs setObject:[fileName lastPathComponent] forKey:@"lastSqlFileName"];

            NSString *content = [NSString stringWithString:[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string]];
            [content writeToFile:fileName
                      atomically:YES
                        encoding:[[encodingPopUp selectedItem] tag]
                           error:&error];

            if (error != nil) {
                NSAlert *errorAlert = [NSAlert alertWithError:error];
                [errorAlert runModal];
            }
            [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:fileName]];

        // Save connection and session as SPF file
        } else if([contextInfo isEqualToString:@"saveSPFfile"] || [contextInfo isEqualToString:@"saveSPFfileAndClose"]) {
            // Save changes of saveConnectionEncryptString
            [[self.saveConnectionEncryptString window] makeFirstResponder:[[self.saveConnectionEncryptString window] initialFirstResponder]];

            [self saveDocumentWithFilePath:fileName inBackground:NO onlyPreferences:NO contextInfo:nil];

            if ([contextInfo isEqualToString:@"saveSPFfileAndClose"]) {
                [self closeAndDisconnect];
            }

        // Save all open windows including all tabs as session
        } else if ([contextInfo isEqualToString:@"saveSession"]) {
            NSDictionary *userInfo = @{
                @"contextInfo": contextInfo,
                @"encrypted": [NSNumber numberWithBool:[self.saveConnectionEncrypt state] == NSControlStateValueOn],
                @"saveConnectionEncryptString": [self.saveConnectionEncryptString stringValue],
                @"auto_connect": [NSNumber numberWithBool:[self.saveConnectionAutoConnect state] == NSControlStateValueOn],
                @"save_password": [NSNumber numberWithBool:[self.saveConnectionSavePassword state] == NSControlStateValueOn],
                @"include_session": [NSNumber numberWithBool:[self.saveConnectionIncludeData state] == NSControlStateValueOn],
                @"save_editor_content": [NSNumber numberWithBool:[self.saveConnectionIncludeQuery state] == NSControlStateValueOn]
            };
            [[NSNotificationCenter defaultCenter] postNotificationName:SPDocumentSaveToSPFNotification object:fileName userInfo:userInfo];
        }
    }
}

- (BOOL)saveDocumentWithFilePath:(NSString *)fileName inBackground:(BOOL)saveInBackground onlyPreferences:(BOOL)saveOnlyPreferences contextInfo:(NSDictionary*)contextInfo
{
    // Do not save if no connection is/was available
    if (saveInBackground && ([self postgresVersion] == nil || ![[self postgresVersion] length])) return NO;

    NSMutableDictionary *spfDocData_temp = [NSMutableDictionary dictionary];

    if (fileName == nil) fileName = [[self fileURL] path];

    // Store save panel settings or take them from spfDocData
    if (!saveInBackground && contextInfo == nil) {
        [spfDocData_temp setObject:[NSNumber numberWithBool:([self.saveConnectionEncrypt state]==NSControlStateValueOn) ? YES : NO ] forKey:@"encrypted"];
        if([[spfDocData_temp objectForKey:@"encrypted"] boolValue]) {
            [spfDocData_temp setObject:[self.saveConnectionEncryptString stringValue] forKey:@"e_string"];
        }
        [spfDocData_temp setObject:[NSNumber numberWithBool:([self.saveConnectionAutoConnect state]==NSControlStateValueOn) ? YES : NO ] forKey:@"auto_connect"];
        [spfDocData_temp setObject:[NSNumber numberWithBool:([self.saveConnectionSavePassword state]==NSControlStateValueOn) ? YES : NO ] forKey:@"save_password"];
        [spfDocData_temp setObject:[NSNumber numberWithBool:([self.saveConnectionIncludeData state]==NSControlStateValueOn) ? YES : NO ] forKey:@"include_session"];
        [spfDocData_temp setObject:@NO forKey:@"save_editor_content"];
        if([[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string] length]) {
            [spfDocData_temp setObject:[NSNumber numberWithBool:([self.saveConnectionIncludeQuery state] == NSControlStateValueOn) ? YES : NO] forKey:@"save_editor_content"];
        }
    }
    else {
        // If contextInfo != nil call came from other SPDatabaseDocument while saving it as bundle
        [spfDocData_temp addEntriesFromDictionary:(contextInfo == nil ? spfDocData : contextInfo)];
    }

    // Update only query favourites, history, etc. by reading the file again
    if (saveOnlyPreferences) {

        // Check URL for safety reasons
        if (![[[self fileURL] path] length] || [self isUntitled]) {
            NSLog(@"Couldn't save data. No file URL found!");
            NSBeep();
            return NO;
        }

        NSMutableDictionary *spf = [[NSMutableDictionary alloc] init];
        {
            NSError *error = nil;

            NSData *pData = [NSData dataWithContentsOfFile:fileName options:NSUncachedRead error:&error];

            if (pData && !error) {
                NSDictionary *pDict = [NSPropertyListSerialization propertyListWithData:pData
                                                                                options:NSPropertyListImmutable
                                                                                 format:NULL
                                                                                  error:&error];

                if (pDict && !error) {
                    [spf addEntriesFromDictionary:pDict];
                }
            }

            if(![spf count] || error) {
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")];
                [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Connection data file “%@” couldn't be read. Please try to save the document under a different name.\n\nDetails: %@", @"message error while reading connection data file and suggesting to save it under a differnet name"), [fileName lastPathComponent], [error localizedDescription]]];

                // Order of buttons matters! first button has "firstButtonReturn" return value from runModal()
                [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                [alert addButtonWithTitle:NSLocalizedString(@"Ignore", @"ignore button")];

                return [alert runModal] == NSAlertSecondButtonReturn;
            }
        }

        // For dispatching later
        if (![[spf objectForKey:SPFFormatKey] isEqualToString:SPFConnectionContentType]) {
            NSLog(@"SPF file format is not 'connection'.");
            return NO;
        }

        // Update the keys
        [spf setObject:[[SPQueryController sharedQueryController] favoritesForFileURL:[self fileURL]] forKey:SPQueryFavorites];
        // DON'T SAVE QUERY HISTORY IN EXPORTS FOR SECURITY
        // [spfStructure setObject:[stateDetails objectForKey:SPQueryHistory] forKey:SPQueryHistory];
        [spf setObject:[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] forKey:SPContentFilters];

        // Save it again
        NSError *error = nil;
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:spf
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                                  options:0
                                                                    error:&error];

        if (error) {
            [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error while converting connection data", @"error while converting connection data") message:[error localizedDescription] callback:nil];
            return NO;
        }

        [plist writeToFile:fileName options:NSAtomicWrite error:&error];

        if (error != nil) {
            NSAlert *errorAlert = [NSAlert alertWithError:error];
            [errorAlert runModal];
            return NO;
        }

        [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:fileName]];

        return YES;
    }

    // Set up the dictionary to save to file, together with a data store
    NSMutableDictionary *spfStructure = [NSMutableDictionary dictionary];
    NSMutableDictionary *spfData = [NSMutableDictionary dictionary];

    // Add basic details
    [spfStructure setObject:@1 forKey:SPFVersionKey];
    [spfStructure setObject:SPFConnectionContentType forKey:SPFFormatKey];
    [spfStructure setObject:@"postgresql" forKey:@"rdbms_type"];
    if([self postgresVersion]) [spfStructure setObject:[self postgresVersion] forKey:@"rdbms_version"];

    // Add auto-connect if appropriate
    [spfStructure setObject:[spfDocData_temp objectForKey:@"auto_connect"] forKey:@"auto_connect"];

    // Set up the document details to store
    NSMutableDictionary *stateDetailsToSave = [NSMutableDictionary dictionaryWithDictionary:@{
        @"connection": @YES,
        @"history":    @YES,
    }];

    // Include session data like selected table, view etc. ?
    if ([[spfDocData_temp objectForKey:@"include_session"] boolValue]) [stateDetailsToSave setObject:@YES forKey:@"session"];

    // Include the query editor contents if asked to
    if ([[spfDocData_temp objectForKey:@"save_editor_content"] boolValue]) {
        [stateDetailsToSave setObject:@YES forKey:@"query"];
        [stateDetailsToSave setObject:@YES forKey:@"enablecompression"];
    }

    // Add passwords if asked to
    if ([[spfDocData_temp objectForKey:@"save_password"] boolValue]) [stateDetailsToSave setObject:@YES forKey:@"password"];

    // Retrieve details and add to the appropriate dictionaries
    NSMutableDictionary *stateDetails = [NSMutableDictionary dictionaryWithDictionary:[self stateIncludingDetails:stateDetailsToSave]];
    [spfStructure setObject:[stateDetails objectForKey:SPQueryFavorites] forKey:SPQueryFavorites];
    // DON'T SAVE QUERY HISTORY IN EXPORTS FOR SECURITY
    // [spfStructure setObject:[stateDetails objectForKey:SPQueryHistory] forKey:SPQueryHistory];
    [spfStructure setObject:[stateDetails objectForKey:SPContentFilters] forKey:SPContentFilters];
    [stateDetails removeObjectsForKeys:@[SPQueryFavorites, SPQueryHistory, SPContentFilters]];
    [spfData addEntriesFromDictionary:stateDetails];

    // Determine whether to use encryption when adding the data
    [spfStructure setObject:[spfDocData_temp objectForKey:@"encrypted"] forKey:@"encrypted"];

    if (![[spfDocData_temp objectForKey:@"encrypted"] boolValue]) {

        // Convert the content selection to encoded data
        if ([[spfData objectForKey:@"session"] objectForKey:@"contentSelection"]) {
            NSMutableDictionary *sessionInfo = [NSMutableDictionary dictionaryWithDictionary:[spfData objectForKey:@"session"]];
            NSMutableData *dataToEncode = [[NSMutableData alloc] init];
            NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:dataToEncode];
            [archiver encodeObject:[sessionInfo objectForKey:@"contentSelection"] forKey:@"data"];
            [archiver finishEncoding];
            [sessionInfo setObject:dataToEncode forKey:@"contentSelection"];
            [spfData setObject:sessionInfo forKey:@"session"];
        }

        [spfStructure setObject:spfData forKey:@"data"];
    }
    else {
        NSMutableData *dataToEncrypt = [[NSMutableData alloc] init];
        NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:dataToEncrypt];
        [archiver encodeObject:spfData forKey:@"data"];
        [archiver finishEncoding];
        [spfStructure setObject:[dataToEncrypt dataEncryptedWithPassword:[spfDocData_temp objectForKey:@"e_string"]] forKey:@"data"];
    }

    // Convert to plist
    NSError *error = nil;
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:spfStructure
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0
                                                                error:&error];

    if (error) {
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error while converting connection data", @"error while converting connection data") message:[error localizedDescription] callback:nil];
        return NO;
    }

    [plist writeToFile:fileName options:NSAtomicWrite error:&error];

    if (error != nil){
        NSAlert *errorAlert = [NSAlert alertWithError:error];
        [errorAlert runModal];
        return NO;
    }

    if (contextInfo == nil) {
        // Register and update query favorites, content filter, and history for the (new) file URL
        NSMutableDictionary *preferences = [[NSMutableDictionary alloc] init];
        if([spfStructure objectForKey:SPQueryHistory]){
            [preferences setObject:[spfStructure objectForKey:SPQueryHistory] forKey:SPQueryHistory];
        }
        if([spfStructure objectForKey:SPQueryFavorites]){
            [preferences setObject:[spfStructure objectForKey:SPQueryFavorites] forKey:SPQueryFavorites];
        }
        if([spfStructure objectForKey:SPContentFilters]){
            [preferences setObject:[spfStructure objectForKey:SPContentFilters] forKey:SPContentFilters];
        }
        [[SPQueryController sharedQueryController] registerDocumentWithFileURL:[NSURL fileURLWithPath:fileName] andContextInfo:preferences];

        NSURL *newURL = [NSURL fileURLWithPath:fileName];
        [self setFileURL:newURL];
        [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:fileName]];

        [self updateWindowTitle:self];

        // Store doc data permanently
        [spfDocData removeAllObjects];
        [spfDocData addEntriesFromDictionary:spfDocData_temp];
    }

    return YES;
}

/**
 * Open the currently selected database in a new tab, clearing any table selection.
 */
- (void)openDatabaseInNewTab {

    // Get the current state
    NSDictionary *allStateDetails = @{
        @"connection" : @YES,
        @"history"    : @YES,
        @"session"    : @YES,
        @"query"      : @YES,
        @"password"   : @YES
    };
    NSMutableDictionary *currentState = [NSMutableDictionary dictionaryWithDictionary:[self stateIncludingDetails:allStateDetails]];

    // Ensure it's set to autoconnect, and clear the table
    [currentState setObject:@YES forKey:@"auto_connect"];
    NSMutableDictionary *sessionDict = [NSMutableDictionary dictionaryWithDictionary:[currentState objectForKey:@"session"]];
    [sessionDict removeObjectForKey:@"table"];
    [currentState setObject:sessionDict forKey:@"session"];

    [[NSNotificationCenter defaultCenter] postNotificationName:SPDocumentDuplicateTabNotification object:nil userInfo:currentState];
}

/**
 * Passes the request to the dataImport object
 */
- (void)importFile {
    [tableDumpInstance importFile];
}

/**
 * Passes the request to the dataImport object
 */
- (void)importFromClipboard {
    [tableDumpInstance importFromClipboard];
}

/**
 * Show the PostgreSQL Help TOC of the current PostgreSQL connection
 * Invoked by the MainMenu > Help > PostgreSQL Help
 */
- (void)showPostgreSQLHelp {
    [helpViewerClientInstance showHelpFor:SPHelpViewerSearchTOC addToHistory:YES calledByAutoHelp:NO];
    [[helpViewerClientInstance helpWebViewWindow] makeKeyWindow];
}

/**
 * Forwards a responder request to set the focus to the table list filter area or table list
 */
- (IBAction) makeTableListFilterHaveFocus:(id)sender
{
    [tablesListInstance performSelector:@selector(makeTableListFilterHaveFocus) withObject:nil afterDelay:0.1];
}


- (IBAction)showConnectionDebugMessages:(id)sender {

    SPConnectionController *conn = self.connectionController;

    NSString *debugMessages = [conn->sshTunnel debugMessages];

    SPLog(@"%@", debugMessages);

    conn->errorDetailWindow.title = NSLocalizedString(@"SSH Tunnel Debugging Info", @"SSH Tunnel Debugging Info");
    conn->errorDetailText.string = debugMessages;

    [[self parentWindowControllerWindow] beginSheet:conn->errorDetailWindow completionHandler:nil];

}

/**
 * Menu item validation.
 */
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];

    if (action == @selector(chooseDatabase:)) {
        return _isConnected && databaseListIsSelectable;
    }

    if (!_isConnected || _isWorkingLevel) {
        return action == @selector(terminate:);
    }

    // Data export
    if (action == @selector(export:)) {
        return (([self database] != nil) && ([[tablesListInstance tables] count] > 1));
    }

    // Selected tables data export
    if (action == @selector(exportSelectedTablesAs:)) {

        NSInteger tag = [menuItem tag];
        NSInteger type = [tablesListInstance tableType];
        NSInteger numberOfSelectedItems = [[[tablesListInstance valueForKeyPath:@"tablesListView"] selectedRowIndexes] count];

        BOOL enable = (([self database] != nil) && numberOfSelectedItems);

        // Enable all export formats if at least one table/view is selected
        if (numberOfSelectedItems == 1) {
            if (type == SPTableTypeTable || type == SPTableTypeView) {
                return enable;
            }
            else if ((type == SPTableTypeProc) || (type == SPTableTypeFunc)) {
                return (enable && (tag == SPSQLExport));
            }
        }
        else {
            for (NSNumber *eachType in [tablesListInstance selectedTableTypes])
            {
                if ([eachType intValue] == SPTableTypeTable || [eachType intValue] == SPTableTypeView) return enable;
            }

            return (enable && (tag == SPSQLExport));
        }
    }

    // Can only be enabled on mysql 4.1+
    if (action == @selector(alterDatabase:)) {
        return (([self database] != nil));
    }

    // Table specific actions
    if (action == @selector(viewStructure) ||
        action == @selector(viewContent)   ||
        action == @selector(viewRelations) ||
        action == @selector(viewStatus)    ||
        action == @selector(viewTriggers))
    {
        return [self database] != nil && [[[tablesListInstance valueForKeyPath:@"tablesListView"] selectedRowIndexes] count];

    }

    // Database specific actions
    if (action == @selector(import:)               ||
        action == @selector(removeDatabase:)       ||
        action == @selector(copyDatabase:)         ||
        action == @selector(renameDatabase:)       ||
        action == @selector(openDatabaseInNewTab:) ||
        action == @selector(refreshTables:))
    {
        return [self database] != nil;
    }

    if (action == @selector(importFromClipboard:)){
        return [self database] && [[NSPasteboard generalPasteboard] availableTypeFromArray:@[NSPasteboardTypeString]];
    }

    // Change "Save Query/Queries" menu item title dynamically
    // and disable it if no query in the editor
    if (action == @selector(saveConnectionSheet:) && [menuItem tag] == 0) {
        if ([customQueryInstance numberOfQueries] < 1) {
            [menuItem setTitle:NSLocalizedString(@"Save Query…", @"Save Query…")];

            return NO;
        }
        else {
            [menuItem setTitle:[customQueryInstance numberOfQueries] == 1 ? NSLocalizedString(@"Save Query…", @"Save Query…") : NSLocalizedString(@"Save Queries…", @"Save Queries…")];
        }

        return YES;
    }

    if (action == @selector(printDocument:)) {
        return (
                ([self database] != nil && [[tablesListInstance valueForKeyPath:@"tablesListView"] numberOfSelectedRows] == 1) ||
                // If Custom Query Tab is active the textView will handle printDocument by itself
                // if it is first responder; otherwise allow to print the Query Result table even
                // if no db/table is selected
                [self currentlySelectedView] == SPTableViewCustomQuery
                );
    }

    if (action == @selector(chooseEncoding:)) {
        return [self supportsEncoding];
    }

    // unhide the debugging info menu
    if (action == @selector(showConnectionDebugMessages:)) {
        if(_isConnected && connectionController->sshTunnel != nil){
            menuItem.hidden = NO;
            [menuItem.menu.itemArray enumerateObjectsUsingBlock:^(NSMenuItem *item2, NSUInteger idx, BOOL * _Nonnull stop) {
                if ([item2.title isEqualToString:NSLocalizedString(@"SSH Tunnel Debugging Info", @"SSH Tunnel Debugging Info")]) {
                    SPLog(@"Unhiding HR above SSH Tunnel Debugging");
                    NSMenuItem *hrMenuItem = [menuItem.menu.itemArray safeObjectAtIndex:idx-1];
                    if(hrMenuItem.isSeparatorItem){
                        hrMenuItem.hidden = NO;
                    }
                    *stop = YES;
                }
            }];
        }
        return YES;
    }

    // Table actions and view switching
    if (action == @selector(analyzeTable:) ||
        action == @selector(optimizeTable:) ||
        action == @selector(repairTable:) ||
        action == @selector(flushTable:) ||
        action == @selector(checkTable:) ||
        action == @selector(checksumTable:) ||
        action == @selector(showCreateTableSyntax:) ||
        action == @selector(copyCreateTableSyntax:))
    {
        return [[[tablesListInstance valueForKeyPath:@"tablesListView"] selectedRowIndexes] count];
    }

    if (action == @selector(addConnectionToFavorites:)) {
        return ![connectionController selectedFavorite] || [connectionController isEditingConnection];
    }

    // Backward in history menu item
    if ((action == @selector(backForwardInHistory:)) && ([menuItem tag] == 0)) {
        return ([spHistoryControllerInstance countPrevious]);
    }

    // Forward in history menu item
    if ((action == @selector(backForwardInHistory:)) && ([menuItem tag] == 1)) {
        return [spHistoryControllerInstance countForward];
    }

    // Show/hide console
    if (action == @selector(toggleConsole:)) {
        [menuItem setTitle:([[[SPQueryController sharedQueryController] window] isVisible] && [[[NSApp keyWindow] windowController] isKindOfClass:[SPQueryController class]]) ? NSLocalizedString(@"Hide Console", @"hide console") : NSLocalizedString(@"Show Console", @"show console")];
        return YES;
    }

    // Clear console
    if (action == @selector(clearConsole:)) {
        return ([[SPQueryController sharedQueryController] consoleMessageCount] > 0);
    }

    // Show/hide console
    if (action == @selector(toggleNavigator:)) {
        [menuItem setTitle:([[[SPNavigatorController sharedNavigatorController] window] isVisible]) ? NSLocalizedString(@"Hide Navigator", @"hide navigator") : NSLocalizedString(@"Show Navigator", @"show navigator")];
    }

    // Focus on table content filter
    if (action == @selector(focusOnTableContentFilter:) || action == @selector(showFilterTable:)) {
        return ([self table] != nil && [[self table] isNotEqualTo:@""]);
    }

    // Focus on table list or filter resp.
    if (action == @selector(makeTableListFilterHaveFocus:)) {

        [menuItem setTitle:[[tablesListInstance valueForKeyPath:@"tables"] count] > 20 ? NSLocalizedString(@"Filter Tables", @"filter tables menu item") : NSLocalizedString(@"Change Focus to Table List", @"change focus to table list menu item")];

        return [[tablesListInstance valueForKeyPath:@"tables"] count] > 1;
    }

    // If validation for the sort favorites tableview items reaches here then the preferences window isn't
    // open return NO.
    if ((action == @selector(sortFavorites:)) || (action == @selector(reverseSortFavorites:))) {
        return NO;
    }

    // Default to YES for unhandled menus
    return YES;
}

/**
 * Adds the current database connection details to the user's favorites if it doesn't already exist.
 */
- (void)addConnectionToFavorites {
    // Obviously don't add if it already exists. We shouldn't really need this as the menu item validation
    // enables or disables the menu item based on the same method. Although to be safe do the check anyway
    // as we don't know what's calling this method.
    if ([connectionController selectedFavorite] && ![connectionController isEditingConnection]) {
        return;
    }

    // Request the connection controller to add its details to favorites
    [connectionController addFavoriteUsingCurrentDetails:self];
}

/**
 * Return YES if Custom Query is active.
 */
- (BOOL)isCustomQuerySelected
{
    return [[self selectedToolbarItemIdentifier] isEqualToString:SPMainToolbarCustomQuery];
}

/**
 * Return the createTableSyntaxWindow
 */
- (NSWindow *)getCreateTableSyntaxWindow
{
    return createTableSyntaxWindow;
}


@end

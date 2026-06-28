//
//  SPDatabaseDocument+State.m
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

@implementation SPDatabaseDocument (State)

#pragma mark -
#pragma mark NSDocument compatibility

/**
 * Set the NSURL for a .spf file for this connection instance.
 */
- (void)setFileURL:(NSURL *)theURL
{
    spfFileURL = theURL;
    if ([self.parentWindowController databaseDocument] == self) {
        if (spfFileURL && [spfFileURL isFileURL]) {
            [[self.parentWindowController window] setRepresentedURL:spfFileURL];
        } else {
            [[self.parentWindowController window] setRepresentedURL:nil];
        }
    }
}

/**
 * Retrieve the NSURL for the .spf file for this connection instance (if any)
 */
- (NSURL *)fileURL
{
    return [spfFileURL copy];
}

/**
 * Invoked if user chose "Save" from 'Do you want save changes you made...' sheet
 * which is called automatically if [self isDocumentEdited] == YES and user wanted to close an Untitled doc.
 */
- (BOOL)writeSafelyToURL:(NSURL *)absoluteURL ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation error:(NSError **)outError
{
    if(saveOperation == NSSaveOperation) {
        // Dummy error to avoid crashes after Canceling the Save Panel
        if (outError) *outError = [NSError errorWithDomain:@"SP_DOMAIN" code:1000 userInfo:nil];
        [self saveConnectionSheet:nil];
        return NO;
    }
    return YES;
}

/**
 * Shows "save?" dialog when closing the document if the an Untitled doc has doc-based query favorites or content filters.
 */
- (BOOL)isDocumentEdited
{
    return (
            [self fileURL] && [[[self fileURL] path] length] && [self isUntitled] && ([[[SPQueryController sharedQueryController] favoritesForFileURL:[self fileURL]] count]
                                                                                      || [[[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] objectForKey:@"number"] count]
                                                                                      || [[[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] objectForKey:@"date"] count]
                                                                                      || [[[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] objectForKey:@"string"] count])
            );
}

/**
 * The window title for this document.
 */
- (NSString *)displayName
{
    if (!_isConnected) {
        return [NSString stringWithFormat:@"%@%@", ([[[self fileURL] path] length] && ![self isUntitled]) ? [NSString stringWithFormat:@"%@ — ",[[[self fileURL] path] lastPathComponent]] : @"", [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString*)kCFBundleNameKey]];
    }
    return [[[self fileURL] path] lastPathComponent];
}

- (NSUndoManager *)undoManager
{
    return undoManager;
}

#pragma mark -
#pragma mark State saving and setting

/**
 * Retrieve the current database document state for saving.  A supplied dictionary
 * determines the level of detail that is required, with the following optional keys:
 *  - connection: Connection settings (with keychain references where available) and database
 *  - password: Whether to include passwords in the returned connection details
 *  - session: Selected table and view, together with content view filter, sort, scroll position
 *  - history: query history, per-doc query favourites, and per-doc content filters
 *  - query: custom query editor content
 *    - enablecompression: large (>50k) custom query editor contents will be stored as compressed data
 * If none of these are supplied, nil will be returned.
 */
- (NSDictionary *) stateIncludingDetails:(NSDictionary *)detailsToReturn
{
    BOOL returnConnection = [[detailsToReturn objectForKey:@"connection"] boolValue];
    BOOL includePasswords = [[detailsToReturn objectForKey:@"password"] boolValue];
    BOOL returnSession    = [[detailsToReturn objectForKey:@"session"] boolValue];
    BOOL returnHistory    = [[detailsToReturn objectForKey:@"history"] boolValue];
    BOOL returnQuery      = [[detailsToReturn objectForKey:@"query"] boolValue];

    if (!returnConnection && !returnSession && !returnHistory && !returnQuery) return nil;
    NSMutableDictionary *stateDetails = [NSMutableDictionary dictionary];

    // Add connection details
    if (returnConnection) {
        NSMutableDictionary *connection = [NSMutableDictionary dictionary];

        [connection setObject:@"postgresql" forKey:@"rdbms_type"];

        NSString *connectionType;
        switch ([connectionController type]) {
            case SPTCPIPConnection:
                connectionType = @"SPTCPIPConnection";
                break;
            case SPSocketConnection:
                connectionType = @"SPSocketConnection";
                if ([connectionController socket] && [[connectionController socket] length]) [connection setObject:[connectionController socket] forKey:@"socket"];
                break;
            case SPSSHTunnelConnection:
                connectionType = @"SPSSHTunnelConnection";
                [connection setObject:[connectionController sshHost] forKey:@"ssh_host"];
                [connection setObject:[connectionController sshUser] forKey:@"ssh_user"];
                [connection setObject:[NSNumber numberWithInteger:[connectionController sshKeyLocationEnabled]] forKey:@"ssh_keyLocationEnabled"];
                if ([connectionController sshKeyLocation]) [connection setObject:[connectionController sshKeyLocation] forKey:@"ssh_keyLocation"];
                if ([connectionController sshPort] && [[connectionController sshPort] length]) [connection setObject:[NSNumber numberWithInteger:[[connectionController sshPort] integerValue]] forKey:@"ssh_port"];
                break;
            default:
                connectionType = @"SPTCPIPConnection";
        }
        [connection setObject:connectionType forKey:@"type"];

        NSString *kcid = [connectionController connectionKeychainID];
        if ([kcid length]) [connection setObject:kcid forKey:@"kcid"];
        [connection setObject:[self name] forKey:@"name"];
        [connection setObject:[self host] forKey:@"host"];
        [connection setObject:[self user] forKey:@"user"];
        if([connectionController colorIndex] >= 0)                              [connection setObject:[NSNumber numberWithInteger:[connectionController colorIndex]] forKey:SPFavoriteColorIndexKey];
        if([connectionController port] && [[connectionController port] length]) [connection setObject:[NSNumber numberWithInteger:[[connectionController port] integerValue]] forKey:@"port"];
        if([[self database] length])                                            [connection setObject:[self database] forKey:@"database"];

        if (includePasswords) {
            NSString *pw = [connectionController keychainPassword];
            if (!pw) pw = [connectionController password];
            if (pw) [connection setObject:pw forKey:@"password"];

            if ([connectionController type] == SPSSHTunnelConnection) {
                NSString *sshpw = [self keychainPasswordForSSHConnection:nil];
                if(![sshpw length]) sshpw = [connectionController sshPassword];
                [connection setObject:(sshpw ? sshpw : @"") forKey:@"ssh_password"];
            }
        }

        [connection setObject:[NSNumber numberWithInteger:[connectionController useSSL]] forKey:@"useSSL"];
        [connection setObject:[NSNumber numberWithInteger:[connectionController allowDataLocalInfile]] forKey:@"allowDataLocalInfile"];
        [connection setObject:[NSNumber numberWithInteger:[connectionController enableClearTextPlugin]] forKey:@"enableClearTextPlugin"];
        [connection setObject:[NSNumber numberWithInteger:[connectionController sslKeyFileLocationEnabled]] forKey:@"sslKeyFileLocationEnabled"];
        if ([connectionController sslKeyFileLocation]) [connection setObject:[connectionController sslKeyFileLocation] forKey:@"sslKeyFileLocation"];
        [connection setObject:[NSNumber numberWithInteger:[connectionController sslCertificateFileLocationEnabled]] forKey:@"sslCertificateFileLocationEnabled"];
        if ([connectionController sslCertificateFileLocation]) [connection setObject:[connectionController sslCertificateFileLocation] forKey:@"sslCertificateFileLocation"];
        [connection setObject:[NSNumber numberWithInteger:[connectionController sslCACertFileLocationEnabled]] forKey:@"sslCACertFileLocationEnabled"];
        if ([connectionController sslCACertFileLocation]) [connection setObject:[connectionController sslCACertFileLocation] forKey:@"sslCACertFileLocation"];

        [stateDetails setObject:[NSDictionary dictionaryWithDictionary:connection] forKey:@"connection"];
    }

    // Add document-specific saved settings
    if (returnHistory) {
        [stateDetails setObject:[[SPQueryController sharedQueryController] favoritesForFileURL:[self fileURL]] forKey:SPQueryFavorites];
        [stateDetails setObject:[[SPQueryController sharedQueryController] historyForFileURL:[self fileURL]] forKey:SPQueryHistory];
        [stateDetails setObject:[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] forKey:SPContentFilters];
    }

    // Set up a session state dictionary for either state or custom query
    NSMutableDictionary *sessionState = [NSMutableDictionary dictionary];

    // Store session state if appropriate
    if (returnSession) {

        if ([[self table] length]) [sessionState setObject:[self table] forKey:@"table"];

        NSString *currentlySelectedViewName;
        switch ([self currentlySelectedView]) {
            case SPTableViewStructure:
                currentlySelectedViewName = @"SP_VIEW_STRUCTURE";
                break;
            case SPTableViewContent:
                currentlySelectedViewName = @"SP_VIEW_CONTENT";
                break;
            case SPTableViewCustomQuery:
                currentlySelectedViewName = @"SP_VIEW_CUSTOMQUERY";
                break;
            case SPTableViewStatus:
                currentlySelectedViewName = @"SP_VIEW_STATUS";
                break;
            case SPTableViewRelations:
                currentlySelectedViewName = @"SP_VIEW_RELATIONS";
                break;
            case SPTableViewTriggers:
                currentlySelectedViewName = @"SP_VIEW_TRIGGERS";
                break;
            default:
                currentlySelectedViewName = @"SP_VIEW_STRUCTURE";
        }
        [sessionState setObject:currentlySelectedViewName forKey:@"view"];

        [sessionState setObject:[postgresConnection encodingName] forKey:@"connectionEncoding"];

        [sessionState setObject:[NSNumber numberWithBool:[[[self.parentWindowController window] toolbar] isVisible]] forKey:@"isToolbarVisible"];
        [sessionState setObject:[NSNumber numberWithFloat:[tableContentInstance tablesListWidth]] forKey:@"windowVerticalDividerPosition"];

        if ([tableContentInstance sortColumnName]) [sessionState setObject:[tableContentInstance sortColumnName] forKey:@"contentSortCol"];
        [sessionState setObject:[NSNumber numberWithBool:[tableContentInstance sortColumnIsAscending]] forKey:@"contentSortColIsAsc"];
        [sessionState setObject:[NSNumber numberWithInteger:[tableContentInstance pageNumber]] forKey:@"contentPageNumber"];
        [sessionState setObject:NSStringFromRect([tableContentInstance viewport]) forKey:@"contentViewport"];
        NSDictionary *filterSettings = [tableContentInstance filterSettings];
        if (filterSettings) [sessionState setObject:filterSettings forKey:@"contentFilterV2"];

        NSDictionary *contentSelectedRows = [tableContentInstance selectionDetailsAllowingIndexSelection:YES];
        if (contentSelectedRows) {
            [sessionState setObject:contentSelectedRows forKey:@"contentSelection"];
        }
    }

    // Add the custom query editor content if appropriate
    if (returnQuery) {
        NSString *queryString = [[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string];
        if ([[detailsToReturn objectForKey:@"enablecompression"] boolValue] && [queryString length] > 50000) {
            [sessionState setObject:[[queryString dataUsingEncoding:NSUTF8StringEncoding] compress] forKey:@"queries"];
        } else {
            [sessionState setObject:queryString forKey:@"queries"];
        }
    }

    // Store the session state dictionary if either state or custom queries were saved
    if ([sessionState count]) [stateDetails setObject:[NSDictionary dictionaryWithDictionary:sessionState] forKey:@"session"];

    return stateDetails;
}

- (BOOL)setState:(NSDictionary *)stateDetails
{
    return [self setState:stateDetails fromFile:YES];
}

/**
 * Set the state of the document to the supplied dictionary, which should
 * at least contain a "connection" dictionary of details.
 * Returns whether the state was set successfully.
 */
- (BOOL)setState:(NSDictionary *)stateDetails fromFile:(BOOL)spfBased
{
    NSDictionary *connection = nil;
    NSInteger connectionType = -1;
    SPKeychain *keychain = nil;

    // If this document already has a connection, don't proceed.
    if (postgresConnection) return NO;

    // Load the connection data from the state dictionary
    connection = [NSDictionary dictionaryWithDictionary:[stateDetails objectForKey:@"connection"]];
    if (!connection) return NO;

    if ([connection objectForKey:@"kcid"]) keychain = [[SPKeychain alloc] init];

    [self updateWindowTitle:self];

    if(spfBased) {
        // Deselect all favorites on the connection controller,
        // and clear and reset the connection state.
        [[connectionController favoritesOutlineView] deselectAll:connectionController];
        [connectionController updateFavoriteSelection:self];

        // Suppress the possibility to choose an other connection from the favorites
        // if a connection should initialized by SPF file. Otherwise it could happen
        // that the SPF file runs out of sync.
        [[connectionController favoritesOutlineView] setEnabled:NO];
    }
    else {
        [connectionController selectQuickConnectItem];
    }

    // Set the correct connection type
    NSString *typeString = [connection objectForKey:@"type"];
    if (typeString) {
        if ([typeString isEqualToString:@"SPTCPIPConnection"])          connectionType = SPTCPIPConnection;
        else if ([typeString isEqualToString:@"SPSocketConnection"])    connectionType = SPSocketConnection;
        else if ([typeString isEqualToString:@"SPSSHTunnelConnection"]) connectionType = SPSSHTunnelConnection;
        else                                                            connectionType = SPTCPIPConnection;

        [connectionController setType:connectionType];
        [connectionController resizeTabViewToConnectionType:connectionType animating:NO];
    }

    // Set basic details
    if ([connection objectForKey:@"name"])                 [connectionController setName:[connection objectForKey:@"name"]];
    if ([connection objectForKey:@"user"])                 [connectionController setUser:[connection objectForKey:@"user"]];
    if ([connection objectForKey:@"host"])                 [connectionController setHost:[connection objectForKey:@"host"]];
    if ([connection objectForKey:@"port"])                 [connectionController setPort:[NSString stringWithFormat:@"%ld", (long)[[connection objectForKey:@"port"] integerValue]]];
    if ([connection objectForKey:SPFavoriteColorIndexKey]) [connectionController setColorIndex:[(NSNumber *)[connection objectForKey:SPFavoriteColorIndexKey] integerValue]];


    //Set special connection settings
    if ([connection objectForKey:@"allowDataLocalInfile"])              [connectionController setAllowDataLocalInfile:[[connection objectForKey:@"allowDataLocalInfile"] intValue]];

    // Set Enable cleartext plugin
    if ([connection objectForKey:@"enableClearTextPlugin"])             [connectionController setEnableClearTextPlugin:[[connection objectForKey:@"enableClearTextPlugin"] intValue]];

    // Set SSL details
    if ([connection objectForKey:@"useSSL"])                            [connectionController setUseSSL:[[connection objectForKey:@"useSSL"] intValue]];
    if ([connection objectForKey:@"sslKeyFileLocationEnabled"])         [connectionController setSslKeyFileLocationEnabled:[[connection objectForKey:@"sslKeyFileLocationEnabled"] intValue]];
    if ([connection objectForKey:@"sslKeyFileLocation"])                [connectionController setSslKeyFileLocation:[connection objectForKey:@"sslKeyFileLocation"]];
    if ([connection objectForKey:@"sslCertificateFileLocationEnabled"]) [connectionController setSslCertificateFileLocationEnabled:[[connection objectForKey:@"sslCertificateFileLocationEnabled"] intValue]];
    if ([connection objectForKey:@"sslCertificateFileLocation"])        [connectionController setSslCertificateFileLocation:[connection objectForKey:@"sslCertificateFileLocation"]];
    if ([connection objectForKey:@"sslCACertFileLocationEnabled"])      [connectionController setSslCACertFileLocationEnabled:[[connection objectForKey:@"sslCACertFileLocationEnabled"] intValue]];
    if ([connection objectForKey:@"sslCACertFileLocation"])             [connectionController setSslCACertFileLocation:[connection objectForKey:@"sslCACertFileLocation"]];

    // Set the keychain details if available
    NSString *kcid = (NSString *)[connection objectForKey:@"kcid"];
    if ([kcid length]) {
        [connectionController setConnectionKeychainID:kcid];
        [connectionController setConnectionKeychainItemName:[keychain nameForFavoriteName:[connectionController name] id:kcid]];
        [connectionController setConnectionKeychainItemAccount:[keychain accountForUser:[connectionController user] host:[connectionController host] database:[connection objectForKey:@"database"]]];
    }

    // Set password - if not in SPF file try to get it via the KeyChain
    if ([connection objectForKey:@"password"]) {
        [connectionController setPassword:[connection objectForKey:@"password"]];
    }
    else {
        NSString *pw = [connectionController keychainPassword];
        if (pw) [connectionController setPassword:pw];
    }

    // Set the socket details, whether or not the type is a socket
    if ([connection objectForKey:@"socket"])                 [connectionController setSocket:[connection objectForKey:@"socket"]];
    // Set SSH details if available, whether or not the SSH type is currently active (to allow fallback on failure)
    if ([connection objectForKey:@"ssh_host"])               [connectionController setSshHost:[connection objectForKey:@"ssh_host"]];
    if ([connection objectForKey:@"ssh_user"])               [connectionController setSshUser:[connection objectForKey:@"ssh_user"]];
    if ([connection objectForKey:@"ssh_keyLocationEnabled"]) [connectionController setSshKeyLocationEnabled:[[connection objectForKey:@"ssh_keyLocationEnabled"] intValue]];
    if ([connection objectForKey:@"ssh_keyLocation"])        [connectionController setSshKeyLocation:[connection objectForKey:@"ssh_keyLocation"]];
    if ([connection objectForKey:@"ssh_port"])               [connectionController setSshPort:[NSString stringWithFormat:@"%ld", (long)[[connection objectForKey:@"ssh_port"] integerValue]]];

    // Set the SSH password - if not in SPF file try to get it via the KeyChain
    if ([connection objectForKey:@"ssh_password"]) {
        [connectionController setSshPassword:[connection objectForKey:@"ssh_password"]];
    }
    else {
        if ([kcid length]) {
            [connectionController setConnectionSSHKeychainItemName:[keychain nameForSSHForFavoriteName:[connectionController name] id:kcid]];
            [connectionController setConnectionSSHKeychainItemAccount:[keychain accountForSSHUser:[connectionController sshUser] sshHost:[connectionController sshHost]]];
        }
        NSString *sshpw = [self keychainPasswordForSSHConnection:nil];
        if(sshpw) [connectionController setSshPassword:sshpw];
    }

    // Restore the selected database if saved
    if ([connection objectForKey:@"database"]) [connectionController setDatabase:[connection objectForKey:@"database"]];

    // Store session details - if provided - for later setting once the connection is established
    if ([stateDetails objectForKey:@"session"]) {
        spfSession = [NSDictionary dictionaryWithDictionary:[stateDetails objectForKey:@"session"]];
    }

    // Restore favourites and history
    id o;
    if ((o = [stateDetails objectForKey:SPQueryFavorites])) [spfPreferences setObject:o forKey:SPQueryFavorites];
    if ((o = [stateDetails objectForKey:SPQueryHistory]))   [spfPreferences setObject:o forKey:SPQueryHistory];
    if ((o = [stateDetails objectForKey:SPContentFilters])) [spfPreferences setObject:o forKey:SPContentFilters];

    [connectionController updateSSLInterface:self];

    // Autoconnect if appropriate
    if ([stateDetails objectForKey:@"auto_connect"] && [[stateDetails valueForKey:@"auto_connect"] boolValue]) {
        [self connect];
    }

    return YES;
}

/**
 * Initialise the document with the connection file at the supplied path.
 * Returns whether the document was initialised successfully.
 */
- (BOOL)setStateFromConnectionFile:(NSString *)path {
    NSString *encryptpw = nil;
    NSMutableDictionary *data = nil;
    NSDictionary *spf = nil;
    NSError *error = nil;

    // Read the property list data, and unserialize it.
    NSData *pData = [NSData dataWithContentsOfFile:path options:NSUncachedRead error:&error];

    if(pData && !error) {
        spf = [NSPropertyListSerialization propertyListWithData:pData
                                                        options:NSPropertyListImmutable
                                                         format:NULL
                                                          error:&error];
    }

    if (!spf || error) {
        NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Connection data file couldn't be read. (%@)", @"error while reading connection data file"), [error localizedDescription]];
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file") message:message callback:nil];
        [self closeAndDisconnect];
        return NO;
    }

    // If the .spf format is unhandled, error.
    if (![[spf objectForKey:SPFFormatKey] isEqualToString:SPFConnectionContentType]) {
        NSString *message = [NSString stringWithFormat:NSLocalizedString(@"The chosen file “%@” contains ‘%@’ data.", @"message while reading a spf file which matches non-supported formats."), path, [spf objectForKey:SPFFormatKey]];
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Unknown file format", @"warning")] message:message callback:nil];
        [self closeAndDisconnect];
        return NO;
    }

    // Error if the expected data source wasn't present in the file
    if (![spf objectForKey:@"data"]) {
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")] message:NSLocalizedString(@"No data found.", @"no data found") callback:nil];
        [self closeAndDisconnect];
        return NO;
    }

    // Ask for a password if SPF file passwords were encrypted, via a sheet
    if ([spf objectForKey:@"encrypted"] && [[spf valueForKey:@"encrypted"] boolValue]) {
        if([self isSaveInBundle] && [[SPAppDelegate spfSessionDocData] objectForKey:@"e_string"]) {
            encryptpw = [[SPAppDelegate spfSessionDocData] objectForKey:@"e_string"];
        } else {
            [inputTextWindowHeader setStringValue:NSLocalizedString(@"Connection file is encrypted", @"Connection file is encrypted")];
            [inputTextWindowMessage setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Please enter the password for ‘%@’:", @"Please enter the password"), [path lastPathComponent]]];
            [inputTextWindowSecureTextField setStringValue:@""];
            [inputTextWindowSecureTextField selectText:nil];

            [[self.parentWindowController window] beginSheet:inputTextWindow completionHandler:nil];
            // wait for encryption password
            NSModalSession session = [NSApp beginModalSessionForWindow:inputTextWindow];
            for (;;) {

                // Execute code on DefaultRunLoop
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];

                // Break the run loop if editSheet was closed
                if ([NSApp runModalSession:session] != NSModalResponseContinue || ![inputTextWindow isVisible]) break;

                // Execute code on DefaultRunLoop
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];

            }
            [NSApp endModalSession:session];
            [inputTextWindow orderOut:nil];
            [NSApp endSheet:inputTextWindow];

            if (passwordSheetReturnCode) {
                encryptpw = [inputTextWindowSecureTextField stringValue];
                if ([self isSaveInBundle]) {
                    NSMutableDictionary *spfSessionData = [NSMutableDictionary dictionary];
                    [spfSessionData addEntriesFromDictionary:[SPAppDelegate spfSessionDocData]];
                    [spfSessionData setObject:encryptpw forKey:@"e_string"];
                    [SPAppDelegate setSpfSessionDocData:spfSessionData];
                }
            } else {
                [self closeAndDisconnect];
                return NO;
            }
        }
    }

    if ([[spf objectForKey:@"data"] isKindOfClass:[NSDictionary class]])
        data = [NSMutableDictionary dictionaryWithDictionary:[spf objectForKey:@"data"]];

    // If a content selection data key exists in the session, decode it
    if ([[[data objectForKey:@"session"] objectForKey:@"contentSelection"] isKindOfClass:[NSData class]]) {
        NSMutableDictionary *sessionInfo = [NSMutableDictionary dictionaryWithDictionary:[data objectForKey:@"session"]];
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:[sessionInfo objectForKey:@"contentSelection"]];
        [sessionInfo setObject:[unarchiver decodeObjectForKey:@"data"] forKey:@"contentSelection"];
        [unarchiver finishDecoding];
        [data setObject:sessionInfo forKey:@"session"];
    }

    else if ([[spf objectForKey:@"data"] isKindOfClass:[NSData class]]) {
        NSData *decryptdata = nil;
        decryptdata = [[NSMutableData alloc] initWithData:[(NSData *)[spf objectForKey:@"data"] dataDecryptedWithPassword:encryptpw]];
        if (decryptdata != nil && [decryptdata length]) {
            NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:decryptdata];
            data = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)[unarchiver decodeObjectForKey:@"data"]];
            [unarchiver finishDecoding];
        }
        if (data == nil) {
            [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")] message:NSLocalizedString(@"Wrong data format or password.", @"wrong data format or password") callback:nil];
            [self closeAndDisconnect];
            return NO;
        }
    }

    // Ensure the data was read correctly, and has connection details
    if (!data || ![data objectForKey:@"connection"]) {
        NSString *informativeText;
        if (!data) {
            informativeText = NSLocalizedString(@"Wrong data format.", @"wrong data format");
        } else {
            informativeText = NSLocalizedString(@"No connection data found.", @"no connection data found");
        }
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")] message:informativeText callback:nil];
        [self closeAndDisconnect];
        return NO;
    }

    // Move favourites and history into the data dictionary to pass to setState:
    // SPQueryHistory is no longer saved to the SPF file, so it was causing an exception here (it was adding nil to the spf dict), skipping out of the method and not connecting
    // or restoring the query screen content. See commit 96063541
    if([spf objectForKey:SPQueryFavorites]){
        [data setObject:[spf objectForKey:SPQueryFavorites] forKey:SPQueryFavorites];
    }
    if([spf objectForKey:SPQueryHistory]){
        [data setObject:[spf objectForKey:SPQueryHistory] forKey:SPQueryHistory];
    }
    if([spf objectForKey:SPContentFilters]){
        [data setObject:[spf objectForKey:SPContentFilters] forKey:SPContentFilters];
    }

    // Ensure the encryption status is stored in the spfDocData store for future saves
    [spfDocData setObject:@NO forKey:@"encrypted"];
    if (encryptpw != nil) {
        [spfDocData setObject:@YES forKey:@"encrypted"];
        [spfDocData setObject:encryptpw forKey:@"e_string"];
    }
    encryptpw = nil;

    // If session data is available, ensure it is marked for save
    if ([data objectForKey:@"session"]) {
        [spfDocData setObject:@YES forKey:@"include_session"];
    }

    if (![self isSaveInBundle]) {
        NSURL *newURL = [NSURL fileURLWithPath:path];
        [self setFileURL:newURL];
    }

    [spfDocData setObject:[NSNumber numberWithBool:([[data objectForKey:@"connection"] objectForKey:@"password"]) ? YES : NO] forKey:@"save_password"];

    [spfDocData setObject:@NO forKey:@"auto_connect"];

    if([spf objectForKey:@"auto_connect"] && [[spf valueForKey:@"auto_connect"] boolValue]) {
        [spfDocData setObject:@YES forKey:@"auto_connect"];
        [data setObject:@YES forKey:@"auto_connect"];
    }

    // Set the state dictionary, triggering an autoconnect if appropriate
    [self setState:data];

    return YES;
}

/**
 * Restore the session from SPF file if given.
 */
- (void)restoreSession
{
    @autoreleasepool {
        // Check and set the table
        NSArray *tables = [tablesListInstance tables];

        NSUInteger tableIndex = [tables indexOfObject:[spfSession objectForKey:@"table"]];

        // Restore toolbar setting
        if ([spfSession objectForKey:@"isToolbarVisible"]) {
            [[self.mainToolbar onMainThread] setVisible:[[spfSession objectForKey:@"isToolbarVisible"] boolValue]];
        }

        // Reset database view encoding if differs from default
        if ([spfSession objectForKey:@"connectionEncoding"] && ![[postgresConnection encodingName] isEqualToString:[spfSession objectForKey:@"connectionEncoding"]]) {
            [self setConnectionEncoding:[spfSession objectForKey:@"connectionEncoding"] reloadingViews:YES];
        }

        if (tableIndex != NSNotFound) {
            // Set table content details for restore
            if ([spfSession objectForKey:@"contentSortCol"])    [tableContentInstance setSortColumnNameToRestore:[spfSession objectForKey:@"contentSortCol"] isAscending:[[spfSession objectForKey:@"contentSortColIsAsc"] boolValue]];
            if ([spfSession objectForKey:@"contentPageNumber"]) [tableContentInstance setPageToRestore:[[spfSession objectForKey:@"pageNumber"] integerValue]];
            if ([spfSession objectForKey:@"contentViewport"])   [tableContentInstance setViewportToRestore:NSRectFromString([spfSession objectForKey:@"contentViewport"])];
            if ([spfSession objectForKey:@"contentFilterV2"])   [tableContentInstance setFiltersToRestore:[spfSession objectForKey:@"contentFilterV2"]];

            // Select table
            [[tablesListInstance onMainThread] selectTableAtIndex:@(tableIndex)];

            // Restore table selection indexes
            if ([spfSession objectForKey:@"contentSelection"]) {
                [tableContentInstance setSelectionToRestore:[spfSession objectForKey:@"contentSelection"]];
            }

            // Scroll to table
            [[tablesListInstance->tablesListView onMainThread] scrollRowToVisible:tableIndex];
        }

        // update UI on main thread
        SPMainQSync(^{
            // Select view
            NSString *view = [self->spfSession objectForKey:@"view"];

            if ([view isEqualToString:@"SP_VIEW_STRUCTURE"]) {
                [self viewStructure];
            } else if ([view isEqualToString:@"SP_VIEW_CONTENT"]) {
                [self viewContent];
            } else if ([view isEqualToString:@"SP_VIEW_CUSTOMQUERY"]) {
                [self viewQuery];
            } else if ([view isEqualToString:@"SP_VIEW_STATUS"]) {
                [self viewStatus];
            } else if ([view isEqualToString:@"SP_VIEW_RELATIONS"]) {
                [self viewRelations];
            } else if ([view isEqualToString:@"SP_VIEW_TRIGGERS"]) {
                [self viewTriggers];
            }
            [self updateWindowTitle:self];
        });

        // End the task
        [self endTask];
    }
}


@end

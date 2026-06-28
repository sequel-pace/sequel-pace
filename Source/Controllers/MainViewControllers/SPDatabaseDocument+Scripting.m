//
//  SPDatabaseDocument+Scripting.m
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
#import "SPPostgresGeometryData.h"

@implementation SPDatabaseDocument (Scripting)

#pragma mark Scheme scripting methods

/**
 * Called by handleSchemeCommand: to break a while loop
 */
- (void)setTimeout
{
    _workingTimeout = YES;
}

/**
 * Process passed URL scheme command and wait (timeouted) for the document if it's busy or not yet connected
 */
- (void)handleSchemeCommand:(NSDictionary*)commandDict
{
    if(!commandDict) return;

    NSArray *params = [commandDict objectForKey:@"parameter"];
    if(![params count]) {
        NSLog(@"No URL scheme command passed");
        NSBeep();
        return;
    }

    NSString *command = [params objectAtIndex:0];
    NSString *docProcessID = [self processID];
    if(!docProcessID) docProcessID = @"";

    // Wait for self
    _workingTimeout = NO;
    // the following while loop waits maximal 5secs
    [self performSelector:@selector(setTimeout) withObject:nil afterDelay:5.0];
    while (_isWorkingLevel || !_isConnected) {
        if(_workingTimeout) break;
        // Do not block self
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:[NSDate distantPast]
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES];
        if(event) [NSApp sendEvent:event];

    }

    if ([command isEqualToString:@"SelectDocumentView"]) {
        if([params count] == 2) {
            NSString *view = [params objectAtIndex:1];
            if([view length]) {
                NSString *viewName = [view lowercaseString];
                if ([viewName hasPrefix:@"str"]) {
                    [self viewStructure];
                } else if([viewName hasPrefix:@"con"]) {
                    [self viewContent];
                } else if([viewName hasPrefix:@"que"]) {
                    [self viewQuery];
                } else if([viewName hasPrefix:@"tab"]) {
                    [self viewStatus];
                } else if([viewName hasPrefix:@"rel"]) {
                    [self viewRelations];
                } else if([viewName hasPrefix:@"tri"]) {
                    [self viewTriggers];
                }
                [self updateWindowTitle:self];
            }
        }
        return;
    }

    if([command isEqualToString:@"SelectTable"]) {
        if([params count] == 2) {
            NSString *tableName = [params objectAtIndex:1];
            if([tableName length]) {
                [tablesListInstance selectItemWithName:tableName];
            }
        }
        return;
    }

    if([command isEqualToString:@"SelectTables"]) {
        if([params count] > 1) {
            [tablesListInstance selectItemsWithNames:[params subarrayWithRange:NSMakeRange(1, [params count]-1)]];
        }
        return;
    }

    if([command isEqualToString:@"SelectDatabase"]) {
        if([params count] > 1) {
            NSString *dbName = [params objectAtIndex:1];
            NSString *tableName = nil;
            if([dbName length]) {
                if([params count] == 3) {
                    tableName = [params objectAtIndex:2];
                }
                [self selectDatabase:dbName item:tableName];
            }
        }
        return;
    }

    // ==== the following commands need an authentication for safety reasons

    // Authenticate command
    if(![docProcessID isEqualToString:[commandDict objectForKey:@"id"]]) {
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Remote Error", @"remote error") message:NSLocalizedString(@"URL scheme command couldn't authenticated", @"URL scheme command couldn't authenticated") callback:nil];
        return;
    }

    if([command isEqualToString:@"SetSelectedTextRange"]) {
        if([params count] > 1) {
            id firstResponder = [[self.parentWindowController window] firstResponder];
            if([firstResponder isKindOfClass:[NSTextView class]]) {
                NSRange theRange = NSIntersectionRange(NSRangeFromString([params objectAtIndex:1]), NSMakeRange(0, [[firstResponder string] length]));
                if(theRange.location != NSNotFound) {
                    [firstResponder setSelectedRange:theRange];
                }
                return;
            }
            NSBeep();
        }
        return;
    }

    if([command isEqualToString:@"InsertText"]) {
        if([params count] > 1) {
            id firstResponder = [[self.parentWindowController window] firstResponder];
            if([firstResponder isKindOfClass:[NSTextView class]]) {
                [((NSTextView *)firstResponder).textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:[params objectAtIndex:1]]];
                return;
            }
            NSBeep();
        }
        return;
    }

    if([command isEqualToString:@"SetText"]) {
        if([params count] > 1) {
            id firstResponder = [[self.parentWindowController window] firstResponder];
            if([firstResponder isKindOfClass:[NSTextView class]]) {
                [(NSTextView *)firstResponder setSelectedRange:NSMakeRange(0, [[firstResponder string] length])];
                [((NSTextView *)firstResponder).textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:[params objectAtIndex:1]]];
                return;
            }
            NSBeep();
        }
        return;
    }

    if([command isEqualToString:@"SelectTableRows"]) {
        id firstResponder = [[NSApp keyWindow] firstResponder];
        if([params count] > 1 && [firstResponder respondsToSelector:@selector(selectTableRows:)]) {
            [(SPCopyTable *)firstResponder selectTableRows:[params subarrayWithRange:NSMakeRange(1, [params count]-1)]];
        }
        return;
    }

    if([command isEqualToString:@"ReloadContentTable"]) {
        [tableContentInstance reloadTable:self];
        return;
    }

    if([command isEqualToString:@"ReloadTablesList"]) {
        [tablesListInstance updateTables:self];
        return;
    }

    if([command isEqualToString:@"ReloadContentTableWithWHEREClause"]) {
        NSString *queryFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryInputPathHeader stringByExpandingTildeInPath], docProcessID];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL isDir;
        if([fileManager fileExistsAtPath:queryFileName isDirectory:&isDir] && !isDir) {
            NSError *inError = nil;
            NSString *query = [NSString stringWithContentsOfFile:queryFileName encoding:NSUTF8StringEncoding error:&inError];
            [fileManager removeItemAtPath:queryFileName error:nil];
            if(inError == nil && query && [query length]) {
                [tableContentInstance filterTable:query];
            }
        }
        return;
    }

    if([command isEqualToString:@"RunQueryInQueryEditor"]) {
        NSString *queryFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryInputPathHeader stringByExpandingTildeInPath], docProcessID];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL isDir;
        if([fileManager fileExistsAtPath:queryFileName isDirectory:&isDir] && !isDir) {
            NSError *inError = nil;
            NSString *query = [NSString stringWithContentsOfFile:queryFileName encoding:NSUTF8StringEncoding error:&inError];
            [fileManager removeItemAtPath:queryFileName error:nil];
            if(inError == nil && query && [query length]) {
                [customQueryInstance performQueries:@[query] withCallback:NULL];
            }
        }
        return;
    }

    if([command isEqualToString:@"CreateSyntaxForTables"]) {

        if([params count] > 1) {

            NSString *queryFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryInputPathHeader stringByExpandingTildeInPath], docProcessID];
            NSString *resultFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryResultPathHeader stringByExpandingTildeInPath], docProcessID];
            NSString *metaFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryResultMetaPathHeader stringByExpandingTildeInPath], docProcessID];
            NSString *statusFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryResultStatusPathHeader stringByExpandingTildeInPath], docProcessID];
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSString *status = @"0";
            BOOL userTerminated = NO;
            BOOL doSyntaxHighlighting = NO;
            BOOL doSyntaxHighlightingViaCSS = NO;

            if([[params lastObject] hasPrefix:@"html"]) {
                doSyntaxHighlighting = YES;
                if([[params lastObject] hasSuffix:@"css"]) {
                    doSyntaxHighlightingViaCSS = YES;
                }
            }

            if(doSyntaxHighlighting && [params count] < 3) return;

            BOOL changeEncoding = ![[postgresConnection encodingName] hasPrefix:@"utf8"];


            NSArray *items = [params subarrayWithRange:NSMakeRange(1, [params count]-( (doSyntaxHighlighting) ? 2 : 1) )];
            NSArray *availableItems = [tablesListInstance tables];
            NSArray *availableItemTypes = [tablesListInstance tableTypes];
            NSMutableString *result = [NSMutableString string];

            for(NSString* item in items) {

                NSEvent* event = [NSApp currentEvent];
                if ([event type] == NSEventTypeKeyDown) {
                    unichar key = [[event characters] length] == 1 ? [[event characters] characterAtIndex:0] : 0;
                    if (([event modifierFlags] & NSEventModifierFlagCommand) && key == '.') {
                        userTerminated = YES;
                        break;
                    }
                }

                NSInteger itemType = SPTableTypeNone;
                NSUInteger i;

                // Loop through the unfiltered tables/views to find the desired item
                for (i = 0; i < [availableItems count]; i++) {
                    itemType = [[availableItemTypes objectAtIndex:i] integerValue];
                    if (itemType == SPTableTypeNone) continue;
                    if ([[availableItems objectAtIndex:i] isEqualToString:item]) {
                        break;
                    }
                }
                // If no match found, continue
                if (itemType == SPTableTypeNone) continue;

                NSString *itemTypeStr;
                NSInteger queryCol;

                switch(itemType) {
                    case SPTableTypeTable:
                    case SPTableTypeView:
                        itemTypeStr = @"TABLE";
                        queryCol = 1;
                        break;
                    case SPTableTypeProc:
                        itemTypeStr = @"PROCEDURE";
                        queryCol = 2;
                        break;
                    case SPTableTypeFunc:
                        itemTypeStr = @"FUNCTION";
                        queryCol = 2;
                        break;
                    default:
                        NSLog(@"%s: Unhandled SPTableType=%ld for item=%@ (skipping)", __func__, itemType, item);
                        continue;
                }

                // Ensure that queries are made in UTF8
                if (changeEncoding) {
                    [postgresConnection storeEncodingForRestoration];
                    [postgresConnection setEncoding:@"utf8mb4"];
                }

                // Get create syntax
                // SHOW CREATE TABLE not supported directly. Using pg_get_viewdef for views or custom logic.
                // For now, simple select to avoid crash
                SPPostgresResult *queryResult = nil; /* [postgresConnection queryString:[NSString stringWithFormat:@"SHOW CREATE %@ %@",
                                                                           itemTypeStr,
                                                                           [item postgresQuotedIdentifier]]]; */
                [queryResult setReturnDataAsStrings:YES];

                if (changeEncoding) [postgresConnection restoreStoredEncoding];

                if ( ![queryResult numberOfRows] ) {
                    //error while getting table structure
                    [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't get create syntax.\nPostgreSQL said: %@", @"message of panel when table information cannot be retrieved"), [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
                    status = @"1";
                } else {
                    NSString *syntaxString = [[queryResult getRowAsArray] objectAtIndex:queryCol];

                    // A NULL value indicates that the user does not have permission to view the syntax
                    if ([syntaxString isNSNull]) {
                        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Permission Denied", @"Permission Denied") message:NSLocalizedString(@"The creation syntax could not be retrieved due to a permissions error.\n\nPlease check your user permissions with an administrator.", @"Create syntax permission denied detail") callback:nil];
                        return;
                    }
                    if(doSyntaxHighlighting) {
                        [result appendFormat:@"%@<br>", [SPAppDelegate doSQLSyntaxHighlightForString:[syntaxString createViewSyntaxPrettifier] cssLike:doSyntaxHighlightingViaCSS]];
                    } else {
                        [result appendFormat:@"%@\n", [syntaxString createViewSyntaxPrettifier]];
                    }
                }
            }

            [fileManager removeItemAtPath:queryFileName error:nil];
            [fileManager removeItemAtPath:resultFileName error:nil];
            [fileManager removeItemAtPath:metaFileName error:nil];
            [fileManager removeItemAtPath:statusFileName error:nil];

            if(userTerminated)
                status = @"1";

            if(![result writeToFile:resultFileName atomically:YES encoding:NSUTF8StringEncoding error:nil])
                status = @"1";

            // write status file as notification that query was finished
            BOOL succeed = [status writeToFile:statusFileName atomically:YES encoding:NSUTF8StringEncoding error:nil];
            if (!succeed) {
                NSBeep();
                [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"BASH Error", @"bash error") message:NSLocalizedString(@"Status file for sequelace url scheme command couldn't be written!", @"status file for sequelace url scheme command couldn't be written error message") callback:nil];
            }

        }
        return;
    }

    if([command isEqualToString:@"ExecuteQuery"]) {

        NSString *outputFormat = @"tab";
        if([params count] == 2)
            outputFormat = [params objectAtIndex:1];

        BOOL writeAsCsv = ([outputFormat isEqualToString:@"csv"]) ? YES : NO;

        NSString *queryFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryInputPathHeader stringByExpandingTildeInPath], docProcessID];
        NSString *resultFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryResultPathHeader stringByExpandingTildeInPath], docProcessID];
        NSString *metaFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryResultMetaPathHeader stringByExpandingTildeInPath], docProcessID];
        NSString *statusFileName = [NSString stringWithFormat:@"%@%@", [SPURLSchemeQueryResultStatusPathHeader stringByExpandingTildeInPath], docProcessID];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *status = @"0";
        BOOL isDir;
        BOOL userTerminated = NO;
        if([fileManager fileExistsAtPath:queryFileName isDirectory:&isDir] && !isDir) {

            NSError *inError = nil;
            NSString *query = [NSString stringWithContentsOfFile:queryFileName encoding:NSUTF8StringEncoding error:&inError];

            [fileManager removeItemAtPath:queryFileName error:nil];
            [fileManager removeItemAtPath:resultFileName error:nil];
            [fileManager removeItemAtPath:metaFileName error:nil];
            [fileManager removeItemAtPath:statusFileName error:nil];

            if(inError == nil && query && [query length]) {

                SPFileHandle *fh = [SPFileHandle fileHandleForWritingAtPath:resultFileName];
                if(!fh){
                    SPLog(@"Couldn't create file handle to %@", resultFileName);
                }

                SPPostgresResult *theResult = [postgresConnection queryString:query];
                [theResult setReturnDataAsStrings:YES];
                if ([postgresConnection queryErrored]) {
                    [fh writeData:[[NSString stringWithFormat:@"PostgreSQL said: %@", [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] dataUsingEncoding:NSUTF8StringEncoding]];
                    status = @"1";
                } else {

                    // write header
                    if(writeAsCsv)
                        [fh writeData:[[[theResult fieldNames] componentsJoinedAsCSV] dataUsingEncoding:NSUTF8StringEncoding]];
                    else
                        [fh writeData:[[[theResult fieldNames] componentsJoinedByString:@"\t"] dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];

                    NSArray *columnDefinition = [theResult fieldDefinitions];

                    // Write table meta data
                    NSMutableString *tableMetaData = [NSMutableString string];
                    for(NSDictionary* col in columnDefinition) {
                        [tableMetaData appendFormat:@"%@\t", [col objectForKey:@"type"]];
                        [tableMetaData appendFormat:@"%@\t", [col objectForKey:@"typegrouping"]];
                        [tableMetaData appendFormat:@"%@\t", ([col objectForKey:@"char_length"]) ? : @""];
                        [tableMetaData appendFormat:@"%@\t", [col objectForKey:@"UNSIGNED_FLAG"]];
                        [tableMetaData appendFormat:@"%@\t", [col objectForKey:@"AUTO_INCREMENT_FLAG"]];
                        [tableMetaData appendFormat:@"%@\t", [col objectForKey:@"PRI_KEY_FLAG"]];
                        [tableMetaData appendString:@"\n"];
                    }
                    NSError *err = nil;
                    [tableMetaData writeToFile:metaFileName
                                    atomically:YES
                                      encoding:NSUTF8StringEncoding
                                         error:&err];
                    if(err != nil) {
                        NSLog(@"Error while writing “%@”", tableMetaData);
                        NSBeep();
                        return;
                    }

                    // write data
                    NSUInteger i, j;
                    NSArray *theRow;
                    NSMutableString *result = [NSMutableString string];
                    if(writeAsCsv) {
                        for ( i = 0 ; i < [theResult numberOfRows]; i++ ) {
                            [result setString:@""];
                            theRow = [theResult getRowAsArray];
                            for( j = 0 ; j < [theRow count]; j++ ) {

                                NSEvent* event = [NSApp currentEvent];
                                if ([event type] == NSEventTypeKeyDown) {
                                    unichar key = [[event characters] length] == 1 ? [[event characters] characterAtIndex:0] : 0;
                                    if (([event modifierFlags] & NSEventModifierFlagCommand) && key == '.') {
                                        userTerminated = YES;
                                        break;
                                    }
                                }

                                if([result length]) [result appendString:@","];
                                id cell = [theRow safeObjectAtIndex:j];
                                if([cell isNSNull])
                                    [result appendString:@"\"NULL\""];
                                else if([cell isKindOfClass:[SPPostgresGeometryData class]])
                                    [result appendFormat:@"\"%@\"", [cell wktString]];
                                else if([cell isKindOfClass:[NSData class]]) {
                                    NSString *displayString = [[NSString alloc] initWithData:cell encoding:[postgresConnection stringEncoding]];
                                    if (!displayString) displayString = [[NSString alloc] initWithData:cell encoding:NSASCIIStringEncoding];
                                    if (displayString) {
                                        [result appendFormat:@"\"%@\"", [displayString stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
                                    } else {
                                        [result appendString:@"\"\""];
                                    }
                                }
                                else
                                    [result appendFormat:@"\"%@\"", [[cell description] stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
                            }
                            if(userTerminated) break;
                            [result appendString:@"\n"];
                            [fh writeData:[result dataUsingEncoding:NSUTF8StringEncoding]];
                        }
                    }
                    else {
                        for ( i = 0 ; i < [theResult numberOfRows]; i++ ) {
                            [result setString:@""];
                            theRow = [theResult getRowAsArray];
                            for( j = 0 ; j < [theRow count]; j++ ) {

                                NSEvent* event = [NSApp currentEvent];
                                if ([event type] == NSEventTypeKeyDown) {
                                    unichar key = [[event characters] length] == 1 ? [[event characters] characterAtIndex:0] : 0;
                                    if (([event modifierFlags] & NSEventModifierFlagCommand) && key == '.') {
                                        userTerminated = YES;
                                        break;
                                    }
                                }

                                if([result length]) [result appendString:@"\t"];
                                id cell = [theRow safeObjectAtIndex:j];
                                if([cell isNSNull])
                                    [result appendString:@"NULL"];
                                else if([cell isKindOfClass:[SPPostgresGeometryData class]])
                                    [result appendFormat:@"%@", [cell wktString]];
                                else if([cell isKindOfClass:[NSData class]]) {
                                    NSString *displayString = [[NSString alloc] initWithData:cell encoding:[postgresConnection stringEncoding]];
                                    if (!displayString) displayString = [[NSString alloc] initWithData:cell encoding:NSASCIIStringEncoding];
                                    if (displayString) {
                                        [result appendFormat:@"%@", [[displayString stringByReplacingOccurrencesOfString:@"\n" withString:@"↵"] stringByReplacingOccurrencesOfString:@"\t" withString:@"⇥"]];
                                    } else {
                                        [result appendString:@""];
                                    }
                                }
                                else
                                    [result appendString:[[[cell description] stringByReplacingOccurrencesOfString:@"\n" withString:@"↵"] stringByReplacingOccurrencesOfString:@"\t" withString:@"⇥"]];
                            }
                            if(userTerminated) break;
                            [result appendString:@"\n"];
                            [fh writeData:[result dataUsingEncoding:NSUTF8StringEncoding]];
                        }
                    }
                }
                [fh closeFile];
            }
        }

        if(userTerminated) {
            [SPTooltip showWithObject:NSLocalizedString(@"URL scheme command was terminated by user", @"URL scheme command was terminated by user") atLocation:[NSEvent mouseLocation]];
            status = @"1";
        }

        // write status file as notification that query was finished
        BOOL succeed = [status writeToFile:statusFileName atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if(!succeed) {
            NSBeep();
            [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"BASH Error", @"bash error") message:NSLocalizedString(@"Status file for sequelace url scheme command couldn't be written!", @"status file for sequelace url scheme command couldn't be written error message") callback:nil];
        }
        return;
    }

    [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Remote Error", @"remote error") message:[NSString stringWithFormat:NSLocalizedString(@"URL scheme command “%@” unsupported", @"URL scheme command “%@” unsupported"), command] callback:nil];
}

- (void)registerActivity:(NSDictionary *)commandDict
{
    [runningActivitiesArray addObject:commandDict];
    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:SPActivitiesUpdateNotification object:self];

    if([runningActivitiesArray count] || [[SPAppDelegate runningActivities] count])
        [self performSelector:@selector(setActivityPaneHidden:) withObject:@0 afterDelay:1.0];
    else {
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(setActivityPaneHidden:)
                                                   object:@0];
        [self setActivityPaneHidden:@1];
    }

}

- (void)removeRegisteredActivity:(NSInteger)pid
{

    for(id cmd in runningActivitiesArray) {
        if([[cmd objectForKey:@"pid"] integerValue] == pid) {
            [runningActivitiesArray removeObject:cmd];
            break;
        }
    }

    if([runningActivitiesArray count] || [[SPAppDelegate runningActivities] count])
        [self performSelector:@selector(setActivityPaneHidden:) withObject:@0 afterDelay:1.0];
    else {
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(setActivityPaneHidden:)
                                                   object:@0];
        [self setActivityPaneHidden:@1];
    }

    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:SPActivitiesUpdateNotification object:self];
}

- (void)setActivityPaneHidden:(NSNumber *)hide
{
    if (hide.boolValue) {
        [documentActivityScrollView setHidden:YES];
        [tableInfoScrollView setHidden:NO];
    }
    else {
        [tableInfoScrollView setHidden:YES];
        [documentActivityScrollView setHidden:NO];
    }
}

- (NSArray *)runningActivities
{
    return runningActivitiesArray;
}

- (NSDictionary *)shellVariables
{
    if (!_isConnected) return @{};

    NSMutableDictionary *env = [NSMutableDictionary dictionary];

    if (tablesListInstance) {

        if ([tablesListInstance selectedDatabase]) {
            [env setObject:[tablesListInstance selectedDatabase] forKey:SPBundleShellVariableSelectedDatabase];
        }

        if ([tablesListInstance tableName]) {
            [env setObject:[tablesListInstance tableName] forKey:SPBundleShellVariableSelectedTable];
        }

        if ([tablesListInstance selectedTableItems]) {
            [env setObject:[[tablesListInstance selectedTableItems] componentsJoinedByString:@"\t"] forKey:SPBundleShellVariableSelectedTables];
        }

        if ([tablesListInstance allDatabaseNames]) {
            [env setObject:[[tablesListInstance allDatabaseNames] componentsJoinedByString:@"\t"] forKey:SPBundleShellVariableAllDatabases];
        }

        if ([self user]) {
            [env setObject:[self user] forKey:SPBundleShellVariableCurrentUser];
        }

        if ([self host]) {
            [env setObject:[self host] forKey:SPBundleShellVariableCurrentHost];
        }

        if ([self port]) {
            [env setObject:[self port] forKey:SPBundleShellVariableCurrentPort];
        }

        [env setObject:[[tablesListInstance allTableNames] componentsJoinedByString:@"\t"] forKey:SPBundleShellVariableAllTables];
        [env setObject:[[tablesListInstance allViewNames] componentsJoinedByString:@"\t"] forKey:SPBundleShellVariableAllViews];
        [env setObject:[[tablesListInstance allFunctionNames] componentsJoinedByString:@"\t"] forKey:SPBundleShellVariableAllFunctions];
        [env setObject:[[tablesListInstance allProcedureNames] componentsJoinedByString:@"\t"] forKey:SPBundleShellVariableAllProcedures];

        [env setObject:([self databaseEncoding]) ? : @"" forKey:SPBundleShellVariableDatabaseEncoding];
    }

    [env setObject:@"postgresql" forKey:SPBundleShellVariableRDBMSType];

    if ([self postgresVersion]) {
        [env setObject:[self postgresVersion] forKey:SPBundleShellVariableRDBMSVersion];
    }

    return env;
}


@end

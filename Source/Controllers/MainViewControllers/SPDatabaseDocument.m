//
//  SPDatabaseDocument.m
//  sequel-pro
//
//  Created by Lorenz Textor (lorenz@textor.ch) on May 1, 2002.
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
//  More info at <https://github.com/sequelpro/sequelpro>

#import "SPDatabaseDocument.h"
#import "SPConnectionController.h"
#import "SPTablesList.h"
#import "SPDatabaseStructure.h"
#import "SPFileHandle.h"
#import "SPKeychain.h"
#import "SPTableContent.h"
#import "SPCustomQuery.h"
#import "SPDataImport.h"
#import "ImageAndTextCell.h"
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
#import "YRKSpinningProgressIndicator.h"
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

#include <stdatomic.h>

// Constants
static NSString *SPNewDatabaseDetails = @"SPNewDatabaseDetails";
static NSString *SPNewDatabaseName = @"SPNewDatabaseName";
static NSString *SPNewDatabaseCopyContent = @"SPNewDatabaseCopyContent";

static _Atomic int SPDatabaseDocumentInstanceCounter = 0;

@interface SPDatabaseDocument ()

// Privately redeclare as read/write to get the synthesized setter
@property (readwrite, assign) BOOL allowSplitViewResizing;

// images
@property (nonatomic, strong) NSImage *hideConsoleImage;
@property (nonatomic, strong) NSImage *showConsoleImage;
@property (nonatomic, strong) NSImage *textAndCommandMacwindowImage API_AVAILABLE(macos(11.0));
@property (nonatomic, weak, readwrite) SPWindowController *parentWindowController;
@property (assign) BOOL appIsTerminating;

@property (readwrite, nonatomic, strong) NSToolbar *mainToolbar;

- (void)_addDatabase;
- (void)_alterDatabase;
- (void)_copyDatabase;
- (void)_renameDatabase;
- (void)_removeDatabase;
- (void)_selectDatabaseAndItem:(NSDictionary *)selectionDetails;
- (void)_processDatabaseChangedBundleTriggerActions;
- (void)_addPreferenceObservers;
- (void)_removePreferenceObservers;

#pragma mark - SPDatabaseViewControllerPrivateAPI

- (void)_loadTabTask:(NSNumber *)tabViewItemIndexNumber;
- (void)_loadTableTask;

#pragma mark - SPConnectionDelegate

- (void) closeAndDisconnect;

- (NSString *)keychainPasswordForConnection:(SPPostgresConnection *)connection;
- (NSString *)keychainPasswordForSSHConnection:(SPPostgresConnection *)connection;

@end

@implementation SPDatabaseDocument

@synthesize sqlFileURL;
@synthesize sqlFileEncoding;
@synthesize isProcessing;
@synthesize serverSupport;
@synthesize databaseStructureRetrieval;
@synthesize processID;
@synthesize instanceId;
@synthesize dbTablesTableView;
@synthesize tableDumpInstance;
@synthesize tablesListInstance;
@synthesize tableContentInstance;
@synthesize customQueryInstance;
@synthesize allowSplitViewResizing;
@synthesize hideConsoleImage;
@synthesize showConsoleImage;
@synthesize textAndCommandMacwindowImage;
@synthesize appIsTerminating;
@synthesize multipleLineEditingButton;

#pragma mark -

+ (void)initialize {
}

- (instancetype)initWithWindowController:(SPWindowController *)windowController {
    if (self = [super init]) {
        _parentWindowController = windowController;

        instanceId = atomic_fetch_add(&SPDatabaseDocumentInstanceCounter, 1);

        _mainNibLoaded = NO;
        _isConnected = NO;
        _isWorkingLevel = 0;
        _isSavedInBundle = NO;
        _supportsEncoding = NO;
        databaseListIsSelectable = YES;
        _queryMode = SPInterfaceQueryMode;

        initComplete = NO;
        allowSplitViewResizing = NO;

        chooseDatabaseButton = nil;
        chooseDatabaseToolbarItem = nil;
        connectionController = nil;

        selectedTableName = nil;
        selectedTableType = SPTableTypeNone;

        structureLoaded = NO;
        contentLoaded = NO;
        statusLoaded = NO;
        triggersLoaded = NO;
        relationsLoaded = NO;
        appIsTerminating = NO;

        hideConsoleImage = [NSImage imageNamed:@"hideconsole"];
        showConsoleImage = [NSImage imageNamed:@"showconsole"];
        if (@available(macOS 11.0, *)) {
            textAndCommandMacwindowImage = [NSImage imageWithSystemSymbolName:@"text.and.command.macwindow" accessibilityDescription:nil];
        }

        selectedDatabase = nil;
        selectedDatabaseEncoding = @"latin1";
        postgresConnection = nil;
        postgresVersion = nil;
        allDatabases = nil;
        allSystemDatabases = nil;
        gotoDatabaseController = nil;

        isProcessing = NO;

        printWebView = [[WebView alloc] init];
        [printWebView setFrameLoadDelegate:self];

        prefs = [NSUserDefaults standardUserDefaults];
        undoManager = [[NSUndoManager alloc] init];
        queryEditorInitString = nil;

        sqlFileURL = nil;
        spfFileURL = nil;
        spfSession = nil;
        spfPreferences = [[NSMutableDictionary alloc] init];
        spfDocData = [[NSMutableDictionary alloc] init];
        runningActivitiesArray = [[NSMutableArray alloc] init];

        taskProgressWindow = nil;
        taskDisplayIsIndeterminate = YES;
        taskDisplayLastValue = 0;
        taskProgressValue = 0;
        taskProgressValueDisplayInterval = 1;
        taskDrawTimer = nil;
        taskFadeInStartDate = nil;
        taskCanBeCancelled = NO;
        taskCancellationCallbackObject = nil;
        taskCancellationCallbackSelector = NULL;
        alterDatabaseCharsetHelper = nil; //init in awakeFromNib
        addDatabaseCharsetHelper = nil;

        statusValues = nil;
        printThread = nil;
        windowTitleStatusViewIsVisible = NO;

        // As this object is not an NSWindowController subclass, top-level objects in loaded nibs aren't
        // automatically released.  Keep track of the top-level objects for release on dealloc.
        NSArray *dbViewTopLevelObjects = nil;
        NSNib *nibLoader = [[NSNib alloc] initWithNibNamed:@"DBView" bundle:[NSBundle mainBundle]];
        [nibLoader instantiateWithOwner:self topLevelObjects:&dbViewTopLevelObjects];

        databaseStructureRetrieval = [[SPDatabaseStructure alloc] initWithDelegate:self];
    }

    return self;
}

- (void)awakeFromNib
{
    if (_mainNibLoaded) return;
    [super awakeFromNib];

    _mainNibLoaded = YES;

    // Update the toolbar
    [self.parentWindowControllerWindow setToolbar:self.mainToolbar];

    // The history controller needs to track toolbar item state - trigger setup.
    [spHistoryControllerInstance setupInterface];

    // Set collapsible behaviour on the table list so collapsing behaviour handles resize issus
    [contentViewSplitter setCollapsibleSubviewIndex:0];

    // Set a minimum size on both text views on the table info page
    [tableInfoSplitView setMinSize:20 ofSubviewAtIndex:0];
    [tableInfoSplitView setMinSize:20 ofSubviewAtIndex:1];

    // Set up the connection controller
    connectionController = [[SPConnectionController alloc] initWithDocument:self];

    // Set the connection controller's delegate
    [connectionController setDelegate:self];

    // Register preference observers to allow live UI-linked preference changes
    [self _addPreferenceObservers];

    // Register for notifications
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(willPerformQuery:)
               name:@"SPQueryWillBePerformed"
             object:self];

    [nc addObserver:self
           selector:@selector(hasPerformedQuery:)
               name:@"SPQueryHasBeenPerformed"
             object:self];

    [nc addObserver:self
           selector:@selector(applicationWillTerminate:)
               name:@"NSApplicationWillTerminateNotification"
             object:nil];

    [nc addObserver:self selector:@selector(documentWillClose:) name:SPDocumentWillCloseNotification object:nil];

    // Find the Database -> Database Encoding menu (it's not in our nib, so we can't use interface builder)
    selectEncodingMenu = [[[[[NSApp mainMenu] itemWithTag:SPMainMenuDatabase] submenu] itemWithTag:1] submenu];

    // Hide the tabs in the tab view (we only show them to allow switching tabs in interface builder)
    [tableTabView setTabViewType:NSNoTabsNoBorder];

    // Hide the activity list
    [self setActivityPaneHidden:@1];

    // Load additional nibs, keeping track of the top-level objects to allow correct release
    NSArray *connectionDialogTopLevelObjects = nil;
    NSNib *nibLoader = [[NSNib alloc] initWithNibNamed:@"ConnectionErrorDialog" bundle:[NSBundle mainBundle]];
    [nibLoader instantiateWithOwner:self topLevelObjects:&connectionDialogTopLevelObjects];

    NSArray *progressIndicatorLayerTopLevelObjects = nil;
    nibLoader = [[NSNib alloc] initWithNibNamed:@"ProgressIndicatorLayer" bundle:[NSBundle mainBundle]];
    [nibLoader instantiateWithOwner:self topLevelObjects:&progressIndicatorLayerTopLevelObjects];

    // Set up the progress indicator child window and layer - change indicator color and size
    [taskProgressIndicator setForeColor:[NSColor whiteColor]];
    NSShadow *progressIndicatorShadow = [[NSShadow alloc] init];
    [progressIndicatorShadow setShadowOffset:NSMakeSize(1.0f, -1.0f)];
    [progressIndicatorShadow setShadowBlurRadius:1.0f];
    [progressIndicatorShadow setShadowColor:[NSColor colorWithCalibratedWhite:0.0f alpha:0.75f]];
    [taskProgressIndicator setShadow:progressIndicatorShadow];
    taskProgressWindow = [[NSWindow alloc] initWithContentRect:[taskProgressLayer bounds] styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    [taskProgressWindow setReleasedWhenClosed:NO];
    [taskProgressWindow setOpaque:NO];
    [taskProgressWindow setBackgroundColor:[NSColor clearColor]];
    [taskProgressWindow setAlphaValue:0.0f];
    [taskProgressWindow setContentView:taskProgressLayer];

    alterDatabaseCharsetHelper = [[SPCharsetCollationHelper alloc] initWithCharsetButton:databaseAlterEncodingButton CollationButton:databaseAlterCollationButton];
    addDatabaseCharsetHelper   = [[SPCharsetCollationHelper alloc] initWithCharsetButton:databaseEncodingButton CollationButton:databaseCollationButton];

    // Update the window's title and represented document
    [self updateWindowTitle:self];
    [self.parentWindowControllerWindow setRepresentedURL:(spfFileURL && [spfFileURL isFileURL] ? spfFileURL : nil)];

    // Add the progress window to this window
    [self centerTaskWindow];

    // If not connected, update the favorite selection
    if (!_isConnected) {
        [connectionController updateFavoriteNextKeyView];
    }

    initComplete = YES;
}

#pragma mark - Accessors

- (NSToolbar *)mainToolbar {
    if (!_mainToolbar) {
        _mainToolbar = [[NSToolbar alloc] initWithIdentifier:@"TableWindowToolbar"];
        [_mainToolbar setAllowsUserCustomization:YES];
        [_mainToolbar setAutosavesConfiguration:YES];
        [_mainToolbar setDelegate:self];
    }
    return _mainToolbar;
}

#pragma mark -

/**
 * Set the return code for entering the encryption passowrd sheet
 */
- (IBAction)closePasswordSheet:(id)sender {
    passwordSheetReturnCode = 0;
    if ([sender tag]) {
        [NSApp stopModal];
        passwordSheetReturnCode = 1;
    }
    [NSApp abortModal];
}

/**
 * Go backward or forward in the history depending on the menu item selected.
 */
- (void)backForwardInHistory:(id)sender {
    // Ensure history navigation is permitted - trigger end editing and any required saves
    if (![self couldCommitCurrentViewActions]) {
        return;
    }

    switch ([sender tag]) {
        case 0: // Go backward
            [spHistoryControllerInstance goBackInHistory];
            break;
        case 1: // Go forward
            [spHistoryControllerInstance goForwardInHistory];
            break;
    }
}

#pragma mark -
#pragma mark Connection callback and methods

/**
 *
 * This method *MUST* be called from the UI thread!
 */
- (void)setConnection:(SPPostgresConnection *)theConnection
{
    if (!theConnection) {
        return;
    }

    _isConnected = YES;
    postgresConnection = theConnection;

    // Now that we have a connection, determine what functionality the database supports.
    // Note that this must be done before anything else as it's used by nearly all of the main controllers.
    serverSupport = [[SPServerSupport alloc] initWithMajorVersion:[postgresConnection serverMajorVersion]
                                                            minor:[postgresConnection serverMinorVersion]
                                                          release:[postgresConnection serverReleaseVersion]];

    // Set the fileURL and init the preferences (query favs, filters, and history) if available for that URL
    NSURL *newURL = [[SPQueryController sharedQueryController] registerDocumentWithFileURL:[self fileURL] andContextInfo:spfPreferences];
    [self setFileURL:newURL];

    // ...but hide the icon while the document is temporary
    if ([self isUntitled]) {
        [[[self.parentWindowController window] standardWindowButton:NSWindowDocumentIconButton] setImage:nil];
    }

    // Get the postgres version
    postgresVersion = [postgresConnection serverVersionString] ;

    NSString *tmpDb = [connectionController database];

    // Update the selected database if appropriate
    if (tmpDb != nil && ![tmpDb isEqualToString:@""]) {
        selectedDatabase = tmpDb;
        [spHistoryControllerInstance updateHistoryEntries];
    }

    // Ensure the connection encoding is set to utf8 for database/table name retrieval
    [postgresConnection setEncoding:@"UTF8"];

    // Check if skip-show-database is set to ON
    /*
    if ( [prefs boolForKey:SPShowWarningSkipShowDatabase] ) {
        SPPostgresResult *result = [postgresConnection queryString:@"SHOW allow_system_table_mods"]; // Dummy query for now
        // [result setReturnDataAsStrings:YES];
        if(![postgresConnection queryErrored] && [result numberOfRows] == 1) {
            // Logic to check permissions
        }
    }
    */
    /*
            NSString *skip_show_database = [[result getRowAsDictionary] objectForKey:@"Value"];
            if ([skip_show_database.lowercaseString isEqualToString:@"on"]) {
                [NSAlert createAlertWithTitle:NSLocalizedString(@"Warning",@"warning")
                                      message:NSLocalizedString(@"The skip-show-database variable of the database server is set to ON. Thus, you won't be able to list databases unless you have the SHOW DATABASES privilege.\n\nHowever, the databases are still accessible directly through SQL queries depending on your privileges.", @"Warning message during connection in case the variable skip-show-database is set to ON")
                           primaryButtonTitle:NSLocalizedString(@"OK", @"OK button")
                         secondaryButtonTitle:NSLocalizedString(@"Never show this again", @"Never show this again")
                         primaryButtonHandler:^{ }
                       secondaryButtonHandler:^{ [self->prefs setBool:false forKey:SPShowWarningSkipShowDatabase]; }
                 ];
            }
        }
    }
    */

    // Update the database list
    [self setDatabases];

    [chooseDatabaseButton setEnabled:!_isWorkingLevel];

    // Set the connection on the database structure builder
    [databaseStructureRetrieval setConnectionToClone:postgresConnection];

    [databaseDataInstance setConnection:postgresConnection];

    // Pass the support class to the data instance
    [databaseDataInstance setServerSupport:serverSupport];

    // Set the connection on the tables list instance - this updates the table list while the connection
    // is still UTF8
    [tablesListInstance setConnection:postgresConnection];

    // Set the connection encoding if necessary
    NSNumber *encodingType = [prefs objectForKey:SPDefaultEncoding];

    if ([encodingType intValue] != SPEncodingAutodetect) {
        [self setConnectionEncoding:[self postgresEncodingFromEncodingTag:encodingType] reloadingViews:NO];
    } else {
        // [[self onMainThread] updateEncodingMenuWithSelectedEncoding:[self encodingTagFromMySQLEncoding:[postgresConnection encoding]]];
    }

    // For each of the main controllers, assign the current connection
    SPLog(@"setConnection for each of main controllers");
    [tableSourceInstance setConnection:postgresConnection];
    [tableContentInstance setConnection:postgresConnection];
    [tableRelationsInstance setConnection:postgresConnection];
    [tableTriggersInstance setConnection:postgresConnection];
    [customQueryInstance setConnection:postgresConnection];
    [tableDumpInstance setConnection:postgresConnection];
    [exportControllerInstance setConnection:postgresConnection];
    [exportControllerInstance setServerSupport:serverSupport];
    [tableDataInstance setConnection:postgresConnection];
    [extendedTableInfoInstance setConnection:postgresConnection];

    // Set the custom query editor's PostgreSQL version
    [customQueryInstance setPostgresVersion:postgresVersion];

    [helpViewerClientInstance setConnection:postgresConnection];

    [self updateWindowTitle:self];

    NSString *serverDisplayName = [[self.parentWindowController window] title];
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = @"Connected";
    notification.informativeText=[NSString stringWithFormat:NSLocalizedString(@"Connected to %@", @"description for connected notification"), serverDisplayName];
    notification.soundName = NSUserNotificationDefaultSoundName;

    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];

    // Init Custom Query editor with the stored queries in a spf file if given.
    [spfDocData setObject:@NO forKey:@"save_editor_content"];

    if (spfSession != nil && [spfSession objectForKey:@"queries"]) {
        [spfDocData setObject:@YES forKey:@"save_editor_content"];
        if ([[spfSession objectForKey:@"queries"] isKindOfClass:[NSData class]]) {
            NSString *q = [[NSString alloc] initWithData:[[spfSession objectForKey:@"queries"] decompress] encoding:NSUTF8StringEncoding];
            [self initQueryEditorWithString:q];
        }
        else {
            [self initQueryEditorWithString:[spfSession objectForKey:@"queries"]];
        }
    }

    // Insert queryEditorInitString into the Query Editor if defined
    if (queryEditorInitString && [queryEditorInitString length]) {
        [self viewQuery];
        [customQueryInstance doPerformLoadQueryService:queryEditorInitString];

    }

    if (spfSession != nil) {

        // Restore vertical split view divider for tables' list and right view (Structure, Content, etc.)
        if([spfSession objectForKey:@"windowVerticalDividerPosition"]) [contentViewSplitter setPosition:[[spfSession objectForKey:@"windowVerticalDividerPosition"] floatValue] ofDividerAtIndex:0];

        // Start a task to restore the session details
        [self startTaskWithDescription:NSLocalizedString(@"Restoring session...", @"Restoring session task description")];

        if ([NSThread isMainThread]) [NSThread detachNewThreadWithName:SPCtxt(@"SPDatabaseDocument session load task",self) target:self selector:@selector(restoreSession) object:nil];
        else                         [self restoreSession];
    }
    else {
        switch ([prefs integerForKey:SPDefaultViewMode] > 0 ? [prefs integerForKey:SPDefaultViewMode] : [prefs integerForKey:SPLastViewMode]) {
            default:
            case SPStructureViewMode:
                [self viewStructure];
                break;
            case SPContentViewMode:
                [self viewContent];
                break;
            case SPRelationsViewMode:
                [self viewRelations];
                break;
            case SPTableInfoViewMode:
                [self viewStatus];
                break;
            case SPQueryEditorViewMode:
                [self viewQuery];
                break;
            case SPTriggersViewMode:
                [self viewTriggers];
                break;
        }
    }

    if ([self database]) [self detectDatabaseEncoding];

    // If not on the query view, alter initial focus - set focus to table list filter
    // field if visible, otherwise set focus to Table List view
    if (![[self selectedToolbarItemIdentifier] isEqualToString:SPMainToolbarCustomQuery]) {
        [[tablesListInstance onMainThread] makeTableListFilterHaveFocus];
    }

}

/**
 * Returns the current connection associated with this document.
 *
 * @return The document's connection
 */
- (SPPostgresConnection *)getConnection
{
    return postgresConnection;
}

#pragma mark -
#pragma mark Database methods

/**
 * sets up the database select toolbar item
 *
 * This method *MUST* be called from the UI thread!
 */
- (void)setDatabases {
    if (!chooseDatabaseButton) {
        return;
    }

    [chooseDatabaseButton removeAllItems];

    [chooseDatabaseButton addItemWithTitle:NSLocalizedString(@"Choose Database...", @"menu item for choose db")];
    [[chooseDatabaseButton menu] addItem:[NSMenuItem separatorItem]];
    [[chooseDatabaseButton menu] addItemWithTitle:NSLocalizedString(@"Add Database...", @"menu item to add db") action:@selector(addDatabase:) keyEquivalent:@""];
    [[chooseDatabaseButton menu] addItemWithTitle:NSLocalizedString(@"Refresh Databases", @"menu item to refresh databases") action:@selector(setDatabases:) keyEquivalent:@""];
    [[chooseDatabaseButton menu] addItem:[NSMenuItem separatorItem]];


    NSArray *theDatabaseList = [postgresConnection databases];

    allDatabases = [[NSMutableArray alloc] initWithCapacity:[theDatabaseList count]];
    allSystemDatabases = [[NSMutableArray alloc] initWithCapacity:2];

    for (NSString *databaseName in theDatabaseList)
    {
        // If the database is either information_schema or mysql then it is classed as a
        // system database; similarly, performance_schema in 5.5.3+ and sys in 5.7.7+
        if ([databaseName isEqualToString:@"postgres"] ||
            [databaseName isEqualToString:@"information_schema"] ||
            [databaseName isEqualToString:@"pg_catalog"] ||
            [databaseName isEqualToString:@"pg_toast"]) {
            [allSystemDatabases addObject:databaseName];
        }
        else {
            [allDatabases addObject:databaseName];
        }
    }

    // Add system databases
    for (NSString *database in allSystemDatabases)
    {
        [chooseDatabaseButton safeAddItemWithTitle:database];
    }

    // Add a separator between the system and user databases
    if ([allSystemDatabases count] > 0) {
        [[chooseDatabaseButton menu] addItem:[NSMenuItem separatorItem]];
    }

    // Add user databases
    for (NSString *database in allDatabases)
    {
        [chooseDatabaseButton safeAddItemWithTitle:database];
    }

    (![self database]) ? [chooseDatabaseButton selectItemAtIndex:0] : [chooseDatabaseButton selectItemWithTitle:[self database]];
}

/**
 * Selects the database choosen by the user, using a child task if necessary,
 * and displaying errors in an alert sheet on failure.
 */
- (IBAction)chooseDatabase:(id)sender
{
    if (![tablesListInstance selectionShouldChangeInTableView:nil]) {
        [chooseDatabaseButton selectItemWithTitle:[self database]];
        return;
    }

    if ( [chooseDatabaseButton indexOfSelectedItem] == 0 ) {
        if ([self database]) {
            [chooseDatabaseButton selectItemWithTitle:[self database]];
        }

        return;
    }

    // Lock editability again if performing a task
    if (_isWorkingLevel) databaseListIsSelectable = NO;

    // Select the database
    [self selectDatabase:[chooseDatabaseButton titleOfSelectedItem] item: nil];
}

/**
 * Select the specified database and, optionally, table.
 */
/**
 * Select the specified database and, optionally, table.
 */
- (void)selectDatabase:(NSString *)database item:(NSString *)item
{
    // Do not update the navigator since nothing is changed
    [[SPNavigatorController sharedNavigatorController] setIgnoreUpdate:NO];

    // Check if we are actually changing the database
    BOOL databaseChanged = ![database isEqualToString:[self database]];

    // If Navigator runs in syncMode let it follow the selection
    if ([[[SPNavigatorController sharedNavigatorController] onMainThread] syncMode]) {
        NSMutableString *schemaPath = [NSMutableString string];

        [schemaPath setString:[self connectionID]];

        if([chooseDatabaseButton titleOfSelectedItem] && [[chooseDatabaseButton titleOfSelectedItem] length]) {
            [schemaPath appendString:SPUniqueSchemaDelimiter];
            [schemaPath appendString:[chooseDatabaseButton titleOfSelectedItem]];
        }

        [[SPNavigatorController sharedNavigatorController] selectPath:schemaPath];
    }

    // Start a task
    [self startTaskWithDescription:[NSString stringWithFormat:NSLocalizedString(@"Loading database '%@'...", @"Loading database task string"), database]];

    NSDictionary *selectionDetails = [NSDictionary dictionaryWithObjectsAndKeys:database, @"database", item ? item : @"", @"item", nil];

    if ([NSThread isMainThread]) {
        [NSThread detachNewThreadWithName:SPCtxt(@"SPDatabaseDocument database and table load task",self)
                                   target:self
                                 selector:@selector(_selectDatabaseAndItem:)
                                   object:selectionDetails];
    }
    else {
        [self _selectDatabaseAndItem:selectionDetails];
    }
}

/**
 * Background task to select database and item
 */
- (void)_selectDatabaseAndItem:(NSDictionary *)selectionDetails
{
    @autoreleasepool {
        NSString *database = [selectionDetails objectForKey:@"database"];
        NSString *item = [selectionDetails objectForKey:@"item"];
        if ([item isEqualToString:@""]) item = nil;

        // Perform the reconnection if the database has changed
        NSString *currentDB = [postgresConnection database];
        
        if (![database isEqualToString:currentDB]) {
            BOOL success = [postgresConnection reconnectWithNewDatabase:database];
            
            if (!success) {
                SPMainQSync(^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    [alert setMessageText:NSLocalizedString(@"Connection Failed", @"Connection failed alert title")];
                    [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Could not connect to database '%@'.\n\nError: %@", @"Connection failed alert message"), database, [self->postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")]];
                    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                    [alert runModal];
                    
                    [self endTask];
                    
                    // Reset selection logic if needed
                    [self->chooseDatabaseButton selectItemWithTitle:currentDB ? currentDB : @""];
                });
                return;
            }
            
            // Update internal state
            selectedDatabase = [database copy];

            // Reset schema to public for the new database (schema from the old DB may not exist here)
            [tablesListInstance setSelectedSchema:@"public"];
            [postgresConnection setSearchPathToSchema:@"public"];

            // Re-detect encoding for the new database
            [self detectDatabaseEncoding];
        }

        // Continue with normal loading logic (checking tables, etc) -> This usually calls setTableDetails eventually
        
        // Update history
        SPMainQSync(^{
            [self->spHistoryControllerInstance updateHistoryEntries];
            [self updateWindowTitle:self];
        });
        
        // Now generic "use database" logic is done via reconnection.
        // We still need to refresh the table list for this new database.
        [tablesListInstance setConnection:postgresConnection]; // Re-set connection to force refresh? Or just refresh?
        [tablesListInstance updateTables:self]; // This should fetch new tables from information_schema

        // If an item (table) was specified, select it
        if (item) {
            SPMainQSync(^{
                 [self->tablesListInstance selectTableName:item];
            });
        }
        
        [self endTask];
    }
}

/**
 * opens the add-db sheet and creates the new db
 */
- (void)addDatabase:(id)sender
{
    if (![tablesListInstance selectionShouldChangeInTableView:nil]) return;

    [databaseNameField setStringValue:@""];

    NSString *defaultCharset   = [databaseDataInstance getServerDefaultCharacterSet];
    NSString *defaultCollation = [databaseDataInstance getServerDefaultCollation];

    // Setup the charset and collation dropdowns
    [addDatabaseCharsetHelper setDatabaseData:databaseDataInstance];
    [addDatabaseCharsetHelper setDefaultCharsetFormatString:NSLocalizedString(@"Server Default (%@)", @"Add Database : Charset dropdown : default item ($1 = charset name)")];
    [addDatabaseCharsetHelper setDefaultCollationFormatString:NSLocalizedString(@"Server Default (%@)", @"Add Database : Collation dropdown : default item ($1 = collation name)")];
    [addDatabaseCharsetHelper setServerSupport:serverSupport];
    [addDatabaseCharsetHelper setPromoteUTF8:YES];
    [addDatabaseCharsetHelper setSelectedCharset:nil];
    [addDatabaseCharsetHelper setSelectedCollation:nil];
    [addDatabaseCharsetHelper setDefaultCharset:defaultCharset];
    [addDatabaseCharsetHelper setDefaultCollation:defaultCollation];
    [addDatabaseCharsetHelper setEnabled:YES];

    [[self.parentWindowController window] beginSheet:databaseSheet completionHandler:^(NSModalResponse returnCode) {
        [self->addDatabaseCharsetHelper setEnabled:NO];

        if (returnCode == NSModalResponseOK) {
            [self _addDatabase];

            // Query the structure of all databases in the background (mainly for completion)
            [self->databaseStructureRetrieval queryDbStructureInBackgroundWithUserInfo:@{@"forceUpdate" : @YES}];
        } else {
            // Reset chooseDatabaseButton
            if ([[self database] length]) {
                [self->chooseDatabaseButton selectItemWithTitle:[self database]];
            } else {
                [self->chooseDatabaseButton selectItemAtIndex:0];
            }
        }
    }];
}

/**
 * Show UI for the ALTER DATABASE statement
 */
- (void)alterDatabase {
    //once the database is created the charset and collation are written
    //to the db.opt file regardless if they were explicity given or not.
    //So there is no longer a "Default" option.

    NSString *currentCharset = [databaseDataInstance getDatabaseDefaultCharacterSet];
    NSString *currentCollation = [databaseDataInstance getDatabaseDefaultCollation];

    // Setup the charset and collation dropdowns
    [alterDatabaseCharsetHelper setDatabaseData:databaseDataInstance];
    [alterDatabaseCharsetHelper setServerSupport:serverSupport];
    [alterDatabaseCharsetHelper setPromoteUTF8:YES];
    [alterDatabaseCharsetHelper setSelectedCharset:currentCharset];
    [alterDatabaseCharsetHelper setSelectedCollation:currentCollation];
    [alterDatabaseCharsetHelper setEnabled:YES];

    [[self.parentWindowController window] beginSheet:databaseAlterSheet completionHandler:^(NSModalResponse returnCode) {

        [self->alterDatabaseCharsetHelper setEnabled:NO];
        if (returnCode == NSModalResponseOK) {
            [self _alterDatabase];
        }
    }];
}

- (IBAction)compareDatabase:(id)sender
{
    /*


     This method is a basic experiment to see how long it takes to read an string compare an entire database. It works,
     well, good performance and very little memory usage.

     Next we need to ask the user to select another connection (from the favourites list) and compare chunks of ~1000 rows
     at a time, ordered by primary key, between the two databases, using three threads (one for each database and one for
     comparisons).

     We will the write to disk every difference that has been found and open the result in FileMerge.

     In future, add the ability to write all difference to the current database.


     */
    NSLog(@"=================");

    NSString *currentSchema = [tablesListInstance selectedSchema] ?: @"public";
    SPPostgresResult *showTablesQuery = [postgresConnection queryString:[NSString stringWithFormat:@"SELECT table_name FROM information_schema.tables WHERE table_schema = %@", [currentSchema tickQuotedString]]];

    NSArray *tableRow;
    while ((tableRow = [showTablesQuery getRowAsArray]) != nil) {
        @autoreleasepool {
            NSString *table = tableRow[0];

            NSLog(@"-----------------");
            NSLog(@"Scanning %@", table);


            // PostgreSQL: Use pg_stat_user_tables for row estimates and pg_total_relation_size for table size
            NSDictionary *tableStatus = [[postgresConnection queryString:[NSString stringWithFormat:
                @"SELECT relname AS \"Name\", "
                @"pg_total_relation_size(relid) AS \"Data_length\", "
                @"n_live_tup AS \"Rows\" "
                @"FROM pg_stat_user_tables "
                @"WHERE relname = %@",
                [table tickQuotedString]]] getRowAsDictionary];
            NSInteger rowCountEstimate = [tableStatus[@"Rows"] integerValue];
            NSLog(@"Estimated row count: %li", rowCountEstimate);



            SPPostgresResult *tableContentsQuery = [postgresConnection queryString:[NSString stringWithFormat:@"select * from %@", [table postgresQuotedIdentifier]]];
            //NSDate *lastProgressUpdate = [NSDate date];
            time_t lastProgressUpdate = time(NULL);
            NSInteger rowCount = 0;
            NSArray *row;
            while (true) {
                @autoreleasepool {
                    row = [tableContentsQuery getRowAsArray];
                    if (!row) {
                        break;
                    }

                    [row isEqualToArray:row]; // TODO: compare to the other database, instead of the same one (just doing that to test performance)

                    rowCount++;
                    if ((time(NULL) - lastProgressUpdate) > 0) {
                        NSLog(@"Progress: %.1f%%", (((float)rowCount) / ((float)rowCountEstimate)) * 100);
                        lastProgressUpdate = time(NULL);
                    }
                }
            }
            NSLog(@"Done. Actual row count: %li", rowCount);
        }
    }

    NSLog(@"=================");
}

/**
 * Opens the copy database sheet and copies the databsae.
 */
- (void)copyDatabase {
    if (![tablesListInstance selectionShouldChangeInTableView:nil]) {
        return;
    }

    // Inform the user that we don't support copying objects other than tables and ask them if they'd like to proceed
    if ([tablesListInstance hasNonTableObjects]) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Only Partially Supported", @"partial copy database support message")];
        [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Duplicating the database '%@' is only partially supported as it contains objects other than tables (i.e. views, procedures, functions, etc.), which will not be copied.\n\nWould you like to continue?", @"partial copy database support informative message"), selectedDatabase]];

        // Order of buttons matters! first button has "firstButtonReturn" return value from runModal()
        [alert addButtonWithTitle:NSLocalizedString(@"Continue", "continue button")];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];

        if ([alert runModal] == NSAlertSecondButtonReturn) {
            return;
        }
    }

    [databaseCopyNameField setStringValue:selectedDatabase];
    [copyDatabaseMessageField setStringValue:selectedDatabase];

    [[self.parentWindowController window] beginSheet:databaseCopySheet completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSModalResponseOK) {
            [self _copyDatabase];
        }
    }];
}

/**
 * Opens the rename database sheet and renames the databsae.
 */
- (void)renameDatabase {
    if (![tablesListInstance selectionShouldChangeInTableView:nil]) {
        return;
    }

    // We currently don't support moving any objects other than tables (i.e. views, functions, procs, etc.) from one database to another
    // so inform the user and don't allow them to proceed. Copy/duplicate is more appropriate in this case, but with the same limitation.
    if ([tablesListInstance hasNonTableObjects]) {
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Database Rename Unsupported", @"databsse rename unsupported message") message:[NSString stringWithFormat:NSLocalizedString(@"Renaming the database '%@' is currently unsupported as it contains objects other than tables (i.e. views, procedures, functions, etc.).\n\nIf you would like to rename a database please use the 'Duplicate Database', move any non-table objects manually then drop the old database.", @"databsse rename unsupported informative message"), selectedDatabase] callback:nil];
        return;
    }

    [databaseRenameNameField setStringValue:selectedDatabase];
    [renameDatabaseMessageField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Rename database '%@' to:", @"rename database message"), selectedDatabase]];

    [[self.parentWindowController window] beginSheet:databaseRenameSheet completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSModalResponseOK) {
            [self _renameDatabase];
        }
    }];
}

/**
 * opens sheet to ask user if he really wants to delete the db
 */
- (void)removeDatabase:(id)sender {
    // No database selected, bail
    if ([chooseDatabaseButton indexOfSelectedItem] == 0) {
        return;
    }

    if (![tablesListInstance selectionShouldChangeInTableView:nil]) {
        return;
    }

    NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Delete database '%@'?", @"delete database message"), [self database]];
    NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the database '%@'? This operation cannot be undone.", @"delete database informative message"), [self database]];
    [NSAlert createDefaultAlertWithTitle:title message:message primaryButtonTitle:NSLocalizedString(@"Delete", @"delete button") primaryButtonHandler:^{
        [self _removeDatabase];
    } cancelButtonHandler:nil];
}

/**
 * Refreshes the tables list by calling SPTablesList's updateTables.
 */
- (void)refreshTables {
    [tablesListInstance updateTables:self];
}

/**
 * Displays the database server variables sheet.
 */
- (void)showServerVariables {
    if (!serverVariablesController) {
        serverVariablesController = [[SPServerVariablesController alloc] init];

        [serverVariablesController setConnection:postgresConnection];
    }

    [serverVariablesController displayServerVariablesSheetAttachedToWindow:[self.parentWindowController window]];
}

/**
 * Displays the database process list sheet.
 */
- (void)showServerProcesses {
    if (!processListController) {
        processListController = [[SPProcessListController alloc] init];

        [processListController setConnection:postgresConnection];
    }

    [processListController displayProcessListWindow];
}

- (void)shutdownServer {
    [NSAlert createDefaultAlertWithTitle:NSLocalizedString(@"Do you really want to shutdown the server?", @"shutdown server : confirmation dialog : title") message:NSLocalizedString(@"This will wait for open transactions to complete and then stop the PostgreSQL server. Afterwards neither you nor anyone else can connect to this database!\n\nFull management access to the server's operating system is required to restart PostgreSQL.", @"shutdown server : confirmation dialog : message") primaryButtonTitle:NSLocalizedString(@"Shutdown", @"shutdown server : confirmation dialog : shutdown button") primaryButtonHandler:^{
        if (![self->postgresConnection serverShutdown]) {
            if ([self->postgresConnection isConnected]) {
                [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Shutdown failed!", @"shutdown server : error dialog : title") message:[NSString stringWithFormat:NSLocalizedString(@"PostgreSQL said:\n%@", @"shutdown server : error dialog : message"), [self->postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
            }
        }
    } cancelButtonHandler:nil];
}

/**
 * Returns an array of all available database names
 */
- (NSArray *)allDatabaseNames
{
    return allDatabases;
}

/**
 * Returns an array of all available system database names
 */
- (NSArray *)allSystemDatabaseNames
{
    return allSystemDatabases;
}

/**
 * Show Error sheet (can be called from inside of a endSheet selector)
 * via [self performSelector:@selector(showErrorSheetWithTitle:) withObject: afterDelay:]
 */
-(void)showErrorSheetWith:(NSArray *)error {
    // error := first object is the title, second the message, only one button OK
    [NSAlert createWarningAlertWithTitle:[error objectAtIndex:0] message:[error objectAtIndex:1] callback:nil];
}

/**
 * Reset the current selected database name
 *
 * This method MAY be called from UI and background threads!
 */
- (void)refreshCurrentDatabase
{
    NSString *dbName = nil;

    // Notify listeners that a query has started
    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:@"SPQueryWillBePerformed" object:self];

    SPPostgresResult *theResult = [postgresConnection queryString:@"SELECT current_database()"];
    [theResult setDefaultRowReturnType:SPPostgresResultRowAsArray];
    if (![postgresConnection queryErrored]) {

        for (NSArray *eachRow in theResult)
        {
            dbName = [eachRow firstObject];
        }

        SPMainQSync(^{
            // TODO: there have been crash reports because dbName == nil at this point. When could that happen?
            if([dbName unboxNull]) {
                if([dbName respondsToSelector:@selector(isEqualToString:)]) {
                    if(![dbName isEqualToString:self->selectedDatabase]) {
                        self->selectedDatabase = [[NSString alloc] initWithString:dbName];
                        [self->chooseDatabaseButton selectItemWithTitle:self->selectedDatabase];
                        [self updateWindowTitle:self];
                    }
                }

            } else {

                [self->chooseDatabaseButton selectItemAtIndex:0];
                [self updateWindowTitle:self];
            }
        });
    }

    //query finished
    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:@"SPQueryHasBeenPerformed" object:self];
}

- (BOOL)navigatorSchemaPathExistsForDatabase:(NSString*)dbname
{
    return [[SPNavigatorController sharedNavigatorController] schemaPathExistsForConnection:[self connectionID] andDatabase:dbname];
}

- (NSDictionary*)getDbStructure
{
    return [[SPNavigatorController sharedNavigatorController] dbStructureForConnection:[self connectionID]];
}

- (NSArray *)allSchemaKeys
{
    return [[SPNavigatorController sharedNavigatorController] allSchemaKeysForConnection:[self connectionID]];
}

- (void)showGotoDatabase {
    if(!gotoDatabaseController) {
        gotoDatabaseController = [[SPGotoDatabaseController alloc] init];
    }

    NSMutableArray *dbList = [[NSMutableArray alloc] init];
    [dbList addObjectsFromArray:[self allSystemDatabaseNames]];
    [dbList addObjectsFromArray:[self allDatabaseNames]];
    [gotoDatabaseController setDatabaseList:dbList];

    if ([gotoDatabaseController runModal]) {
        NSString *database =[gotoDatabaseController selectedDatabase];
        if ([database rangeOfString:@"."].location != NSNotFound){
            NSArray *components = [database componentsSeparatedByString:@"."];
            [self selectDatabase:[components firstObject] item:[components lastObject]];
        }else{
            [self selectDatabase:database item:nil];
        }
    }
}

#pragma mark -
#pragma mark Console methods

/**
 * Shows or hides the console
 */
- (void)toggleConsole {
    // Toggle Console will show the Console window if it isn't visible or if it isn't
    // the front most window and hide it if it is the front most window
    if ([[[SPQueryController sharedQueryController] window] isVisible]
        && [[[NSApp keyWindow] windowController] isKindOfClass:[SPQueryController class]]) {

        [[[SPQueryController sharedQueryController] window] setIsVisible:NO];
    }
    else {
        [self showConsole];
    }
}

/**
 * Brings the console to the front
 */
- (void)showConsole {
    SPQueryController *queryController = [SPQueryController sharedQueryController];
    // If the Console window is not visible data are not reloaded (for speed).
    // Due to that update list if user opens the Console window.
    if (![[queryController window] isVisible]) {
        [queryController updateEntries];
    }

    [[queryController window] makeKeyAndOrderFront:self];
}

/**
 * Clears the console by removing all of its messages
 */
- (void)clearConsole:(id)sender {
    [[SPQueryController sharedQueryController] clearConsole:sender];
}

/**
 * Set a query mode, used to control logging dependant on preferences
 */
- (void) setQueryMode:(NSInteger)theQueryMode
{
    _queryMode = theQueryMode;
}

#pragma mark -
#pragma mark Navigator methods

/**
 * Shows or hides the navigator
 */
- (void)toggleNavigator {
    BOOL isNavigatorVisible = [[[SPNavigatorController sharedNavigatorController] window] isVisible];

    // Show or hide the navigator
    [[[SPNavigatorController sharedNavigatorController] window] setIsVisible:(!isNavigatorVisible)];

    if (!isNavigatorVisible) {
        [[SPNavigatorController sharedNavigatorController] updateEntriesForConnection:self];
    }
}

#pragma mark -
#pragma mark Task progress and notification methods

/**
 * Start a document-wide task, providing a short task description for
 * display to the user.  This sets the document into working mode,
 * preventing many actions, and shows an indeterminate progress interface
 * to the user.
 */
- (void) startTaskWithDescription:(NSString *)description
{
    SPLog(@"startTaskWithDescription: %@", description);

    // Ensure a call on the main thread
    if (![NSThread isMainThread]){
        SPLog(@"not on main thread, calling self again on main");
        return [[self onMainThread] startTaskWithDescription:description];
    }

    // Set the task text. If a nil string was supplied, a generic query notification is occurring -
    // if a task is not already active, use default text.
    if (!description) {
        if (!_isWorkingLevel) [self setTaskDescription:NSLocalizedString(@"Working...", @"Generic working description")];

        // Otherwise display the supplied string
    } else {
        [self setTaskDescription:description];
    }

    // Increment the task level
    _isWorkingLevel++;

    // Reset the progress indicator if necessary
    if (_isWorkingLevel == 1 || !taskDisplayIsIndeterminate) {
        taskDisplayIsIndeterminate = YES;
        [taskProgressIndicator setIndeterminate:YES];
        [taskProgressIndicator startAnimation:self];
        taskDisplayLastValue = 0;
    }

    // If the working level just moved to start a task, set up the interface
    if (_isWorkingLevel == 1) {
        [taskCancelButton setHidden:YES];

        // Set flags and prevent further UI interaction in this window
        databaseListIsSelectable = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:SPDocumentTaskStartNotification object:self];
        [self.mainToolbar validateVisibleItems];

        SPLog(@"Schedule appearance of the task window in the near future, using a frame timer");

        // Schedule appearance of the task window in the near future, using a frame timer.
        taskFadeInStartDate = [[NSDate alloc] init];
        queryStartDate = [[NSDate alloc] init];
        taskDrawTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 target:self selector:@selector(fadeInTaskProgressWindow:) userInfo:nil repeats:YES];
        queryExecutionTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(showQueryExecutionTime) userInfo:nil repeats:YES];

    }
}

/**
 * Show query execution time on progress window.
 */
-(void)showQueryExecutionTime{

    double timeSinceQueryStarted = [[NSDate date] timeIntervalSinceDate:queryStartDate];

    NSString *queryRunningTime = [NSDateComponentsFormatter.hourMinSecFormatter stringFromTimeInterval:timeSinceQueryStarted];

    SPLog(@"showQueryExecutionTime: %@", queryRunningTime);

    NSShadow *textShadow = [[NSShadow alloc] init];
    [textShadow setShadowColor:[NSColor colorWithCalibratedWhite:0.0f alpha:0.75f]];
    [textShadow setShadowOffset:NSMakeSize(1.0f, -1.0f)];
    [textShadow setShadowBlurRadius:3.0f];

    NSMutableDictionary *attributes = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                       [NSFont boldSystemFontOfSize:13.0f], NSFontAttributeName,
                                       textShadow, NSShadowAttributeName,
                                       nil];
    NSAttributedString *queryRunningTimeString = [[NSAttributedString alloc] initWithString:queryRunningTime attributes:attributes];

    [taskDurationTime setAttributedStringValue:queryRunningTimeString];

}

/**
 * Show the task progress window, after a small delay to minimise flicker.
 */
- (void) fadeInTaskProgressWindow:(NSTimer *)theTimer
{
    SPLog(@"fadeInTaskProgressWindow");

    double timeSinceFadeInStart = [[NSDate date] timeIntervalSinceDate:taskFadeInStartDate];

    // Keep the window hidden for the first ~0.5 secs
    if (timeSinceFadeInStart < 0.5) return;

    if ([taskProgressWindow parentWindow] == nil) {
        [self.parentWindowControllerWindow addChildWindow:taskProgressWindow ordered:NSWindowAbove];
    }

    CGFloat alphaValue = [taskProgressWindow alphaValue];

    // If the task progress window is still hidden, center it before revealing it
    if (alphaValue == 0) [self centerTaskWindow];

    SPLog(@"Fade in the task window over 0.6 seconds");

    // Fade in the task window over 0.6 seconds
    alphaValue = (float)(timeSinceFadeInStart - 0.5) / 0.6f;
    if (alphaValue > 1.0f) alphaValue = 1.0f;
    [taskProgressWindow setAlphaValue:alphaValue];

    // If the window has been fully faded in, clean up the timer.
    if (alphaValue == 1.0) {
        [taskDrawTimer invalidate];
    }
}

/**
 * Updates the task description shown to the user.
 */
- (void) setTaskDescription:(NSString *)description
{
    NSShadow *textShadow = [[NSShadow alloc] init];
    [textShadow setShadowColor:[NSColor colorWithCalibratedWhite:0.0f alpha:0.75f]];
    [textShadow setShadowOffset:NSMakeSize(1.0f, -1.0f)];
    [textShadow setShadowBlurRadius:3.0f];

    NSMutableDictionary *attributes = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                       [NSFont boldSystemFontOfSize:13.0f], NSFontAttributeName,
                                       textShadow, NSShadowAttributeName,
                                       nil];
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:description attributes:attributes];

    [taskDescriptionText setAttributedStringValue:string];
}

/**
 * Sets the task percentage progress - the first call to this automatically
 * switches the progress display to determinate.
 * Can be called from background threads - forwards to main thread as appropriate.
 */
- (void) setTaskPercentage:(CGFloat)taskPercentage
{

    SPLog(@"setTaskPercentage = %f", taskPercentage);

    // If the task display is currently indeterminate, set it to determinate on the main thread.
    if (taskDisplayIsIndeterminate) {
        if (![NSThread isMainThread]) return [[self onMainThread] setTaskPercentage:taskPercentage];

        taskDisplayIsIndeterminate = NO;
        [taskProgressIndicator stopAnimation:self];
        [taskProgressIndicator setDoubleValue:0.5];
    }

    // Check the supplied progress.  Compare it to the display interval - how often
    // the interface is updated - and update the interface if the value has changed enough.
    taskProgressValue = taskPercentage;
    if (taskProgressValue >= taskDisplayLastValue + taskProgressValueDisplayInterval
        || taskProgressValue <= taskDisplayLastValue - taskProgressValueDisplayInterval)
    {
        if ([NSThread isMainThread]) {
            [taskProgressIndicator setDoubleValue:taskProgressValue];
        } else {
            [taskProgressIndicator performSelectorOnMainThread:@selector(setNumberValue:) withObject:[NSNumber numberWithDouble:taskProgressValue] waitUntilDone:NO];
        }
        taskDisplayLastValue = taskProgressValue;
    }
}

/**
 * Sets the task progress indicator back to indeterminate (also performed
 * automatically whenever a new task is started).
 * This can optionally be called with afterDelay set, in which case the intederminate
 * switch will be made after a short pause to minimise flicker for short actions.
 * Should be called on the main thread.
 */
- (void) setTaskProgressToIndeterminateAfterDelay:(BOOL)afterDelay
{
    SPLog(@"setTaskProgressToIndeterminateAfterDelay");

    if (afterDelay) {
        [self performSelector:@selector(setTaskProgressToIndeterminateAfterDelay:) withObject:nil afterDelay:0.5];
        return;
    }

    if (taskDisplayIsIndeterminate) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:taskProgressIndicator];
    taskDisplayIsIndeterminate = YES;
    [taskProgressIndicator setIndeterminate:YES];
    [taskProgressIndicator startAnimation:self];
    taskDisplayLastValue = 0;
}

/**
 * Hide the task progress and restore the document to allow actions again.
 */
- (void) endTask
{
    NSLog(@"SPDatabaseDocument: endTask called. _isWorkingLevel=%ld", (long)_isWorkingLevel);
    SPLog(@"endTask");

    // Ensure a call on the main thread
    if (![NSThread isMainThread]) return [[self onMainThread] endTask];

    SPLog(@"_isWorkingLevel = %li", (long)_isWorkingLevel);

    // Decrement the working level
    _isWorkingLevel--;
    assert(_isWorkingLevel >= 0);

    SPLog(@"_isWorkingLevel = %li", (long)_isWorkingLevel);

    // Ensure cancellation interface is reset
    [self disableTaskCancellation];

    // If all tasks have ended, re-enable the interface
    if (!_isWorkingLevel) {

        SPLog(@"!_isWorkingLevel, all tasks have ended");

        // Cancel the draw timer if it exists
        if (taskDrawTimer) {
            SPLog(@"Cancel the draw timer if it exists");
            [taskDrawTimer invalidate];
        }

        if (queryExecutionTimer) {
            queryStartDate = [[NSDate alloc] init];
            SPLog(@"self showQueryExecutionTime");
            [self showQueryExecutionTime];
            SPLog(@"queryExecutionTimer invalidate");
            [queryExecutionTimer invalidate];
        }

        // Hide the task interface and reset to indeterminate
        if (taskDisplayIsIndeterminate){
            SPLog(@"taskDisplayIsIndeterminate,stopAnimation ");
            [taskProgressIndicator stopAnimation:self];
        }
        [taskProgressWindow setAlphaValue:0.0f];
        [taskProgressWindow orderOut:self];
        taskDisplayIsIndeterminate = YES;
        [taskProgressIndicator setIndeterminate:YES];

        // Re-enable window interface
        databaseListIsSelectable = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:SPDocumentTaskEndNotification object:self];
        [self.mainToolbar validateVisibleItems];
        [chooseDatabaseButton setEnabled:_isConnected];
    }
}

/**
 * Allow a task to be cancelled, enabling the button with a supplied title
 * and optionally supplying a callback object and function.
 */
- (void) enableTaskCancellationWithTitle:(NSString *)buttonTitle callbackObject:(id)callbackObject callbackFunction:(SEL)callbackFunction
{
    // Ensure call on the main thread
    if (![NSThread isMainThread]) return [[self onMainThread] enableTaskCancellationWithTitle:buttonTitle callbackObject:callbackObject callbackFunction:callbackFunction];

    // If no task is active, return
    if (!_isWorkingLevel) return;

    if (callbackObject && callbackFunction) {
        taskCancellationCallbackObject = callbackObject;
        taskCancellationCallbackSelector = callbackFunction;
    }
    taskCanBeCancelled = YES;

    NSMutableAttributedString *colorTitle = [[NSMutableAttributedString alloc]
                                             initWithString:buttonTitle
                                             attributes:@{NSForegroundColorAttributeName: [NSColor whiteColor]}
                                             ];
    [taskCancelButton setAttributedTitle:colorTitle];
    [taskCancelButton setEnabled:YES];
    [taskCancelButton setHidden:NO];
}

/**
 * Disable task cancellation.  Called automatically at the end of a task.
 */
- (void)disableTaskCancellation
{
    // Ensure call on the main thread
    if (![NSThread isMainThread]) return [[self onMainThread] disableTaskCancellation];

    // If no task is active, return
    if (!_isWorkingLevel) return;

    taskCanBeCancelled = NO;
    taskCancellationCallbackObject = nil;
    taskCancellationCallbackSelector = NULL;
    [taskCancelButton setHidden:YES];
    NSLog(@"SPDatabaseDocument: disableTaskCancellation finished. Cancel button hidden.");
}

/**
 * Action sent by the cancel button when it's active.
 */
- (IBAction)cancelTask:(id)sender {
    if (!taskCanBeCancelled) return;

    [taskCancelButton setEnabled:NO];

    // See whether there is an active database structure task and whether it can be used
    // to cancel the query, for speed (no connection overhead!)
    if (databaseStructureRetrieval && [databaseStructureRetrieval connection]) {
        [postgresConnection setLastQueryWasCancelled:YES];
        [[databaseStructureRetrieval connection] killQueryOnThreadID:[postgresConnection connectionThreadId]];
    } else {
        [postgresConnection cancelCurrentQuery];
    }

    if (taskCancellationCallbackObject && taskCancellationCallbackSelector) {
        [taskCancellationCallbackObject performSelector:taskCancellationCallbackSelector];
    }
}

/**
 * Returns whether the document is busy performing a task - allows UI or actions
 * to be restricted as appropriate.
 */
- (BOOL)isWorking
{
    return (_isWorkingLevel > 0);
}

/**
 * Set whether the database list is selectable or not during the task process.
 */
- (void)setDatabaseListIsSelectable:(BOOL)isSelectable
{
    databaseListIsSelectable = isSelectable;
}

/**
 * Reposition the task window within the main window.
 */
- (void)centerTaskWindow
{
    NSPoint newBottomLeftPoint;
    NSRect mainWindowRect = [[self.parentWindowController window] frame];
    NSRect taskWindowRect = [taskProgressWindow frame];

    newBottomLeftPoint.x = roundf(mainWindowRect.origin.x + mainWindowRect.size.width/2 - taskWindowRect.size.width/2);
    newBottomLeftPoint.y = roundf(mainWindowRect.origin.y + mainWindowRect.size.height/2 - taskWindowRect.size.height/2);

    [taskProgressWindow setFrameOrigin:newBottomLeftPoint];
}

/**
 * Support pausing and restarting the task progress indicator.
 * Only works while the indicator is in indeterminate mode.
 */
- (void)setTaskIndicatorShouldAnimate:(BOOL)shouldAnimate
{
    if (shouldAnimate) {
        [[taskProgressIndicator onMainThread] startAnimation:self];
    } else {
        [[taskProgressIndicator onMainThread] stopAnimation:self];
    }
}

#pragma mark -
#pragma mark Encoding Methods

/**
 * Set the encoding for the database connection
 */
- (void)setConnectionEncoding:(NSString *)encoding reloadingViews:(BOOL)reloadViews
{
    BOOL useLatin1Transport = NO;

    // Special-case UTF-8 over latin 1 to allow viewing/editing of mangled data.
    if ([encoding isEqualToString:@"utf8-"]) {
        useLatin1Transport = YES;
        encoding = @"UTF8";
    }

    // Set the connection encoding
    [postgresConnection setEncoding:encoding];
    [postgresConnection setEncodingUsesLatin1Transport:useLatin1Transport];

    // Update the selected menu item - use PostgreSQL encoding method
    if (useLatin1Transport) {
        [[self onMainThread] updateEncodingMenuWithSelectedEncoding:[self encodingTagFromPostgresEncoding:[NSString stringWithFormat:@"%@-", encoding]]];
    } else {
        [[self onMainThread] updateEncodingMenuWithSelectedEncoding:[self encodingTagFromPostgresEncoding:encoding]];
    }

    // Update the stored connection encoding to prevent switches
    [postgresConnection storeEncodingForRestoration];

    // Reload views as appropriate
    if (reloadViews) {
        [self setStructureRequiresReload:YES];
        [self setContentRequiresReload:YES];
        [self setStatusRequiresReload:YES];
    }
}

/**
 * updates the currently selected item in the encoding menu
 *
 * @param NSString *encoding - the title of the menu item which will be selected
 */
- (void)updateEncodingMenuWithSelectedEncoding:(NSNumber *)encodingTag
{
    NSInteger itemToSelect = [encodingTag integerValue];
    NSInteger correctStateForMenuItem;

    for (NSMenuItem *aMenuItem in [selectEncodingMenu itemArray]) {
        correctStateForMenuItem = ([aMenuItem tag] == itemToSelect) ? NSControlStateValueOn : NSControlStateValueOff;

        if ([aMenuItem state] == correctStateForMenuItem) continue; // don't re-apply state incase it causes performance issues

        [aMenuItem setState:correctStateForMenuItem];
    }
}

/**
 * Returns the display name for a PostgreSQL encoding
 */
- (NSNumber *)encodingTagFromPostgresEncoding:(NSString *)postgresEncoding
{
    if (!postgresEncoding) return @(SPEncodingAutodetect);

    NSDictionary *translationMap = @{
        @"UTF8"      : @(SPEncodingUTF8),
        @"LATIN1"    : @(SPEncodingLatin1),
        @"SQL_ASCII" : @(SPEncodingASCII),
        @"MULE_INTERNAL" : @(SPEncodingAutodetect) // Fallback
    };
    NSNumber *encodingTag = [translationMap valueForKey:postgresEncoding.uppercaseString];

    if (!encodingTag)
        return @(SPEncodingAutodetect);

    return encodingTag;
}

/**
 * Returns the postgres encoding for an encoding string that is displayed to the user
 */
- (NSString *)postgresEncodingFromEncodingTag:(NSNumber *)encodingTag
{
    NSDictionary *translationMap = [NSDictionary dictionaryWithObjectsAndKeys:
                                    @"UTF8",     [NSString stringWithFormat:@"%i", SPEncodingUTF8],
                                    @"SQL_ASCII",[NSString stringWithFormat:@"%i", SPEncodingASCII],
                                    @"LATIN1",   [NSString stringWithFormat:@"%i", SPEncodingLatin1],
                                    @"UTF8",     [NSString stringWithFormat:@"%i", SPEncodingUTF8MB4],
                                    nil];
    NSString *postgresEncoding = [translationMap valueForKey:[NSString stringWithFormat:@"%i", [encodingTag intValue]]];

    if (!postgresEncoding) return @"UTF8";

    return postgresEncoding;
}

/**
 * Retrieve the current database encoding.  This will return Latin-1
 * for unknown encodings.
 */
- (NSString *)databaseEncoding
{
    return selectedDatabaseEncoding;
}

/**
 * Detect and store the encoding of the currently selected database.
 * Falls back to UTF8 if the encoding cannot be retrieved.
 */
- (void)detectDatabaseEncoding
{
    _supportsEncoding = YES;

    NSString *dbEncoding = [databaseDataInstance getDatabaseDefaultCharacterSet];

    // Fallback -> set encoding to PostgreSQL default encoding UTF8
    if (!dbEncoding) {
        NSLog(@"Error: no character encoding found for db, PostgreSQL version is %@", [self postgresVersion]);

        selectedDatabaseEncoding = @"UTF8";

        _supportsEncoding = NO;
    }
    else {
        selectedDatabaseEncoding = dbEncoding;
    }
}

/**
 * When sent by an NSMenuItem, will set the encoding based on the title of the menu item
 */
- (void)chooseEncoding:(id)sender {
    [self setConnectionEncoding:[self postgresEncodingFromEncodingTag:[NSNumber numberWithInteger:[(NSMenuItem *)sender tag]]] reloadingViews:YES];
}

/**
 * return YES if PostgreSQL server supports choosing connection and table encodings
 */
- (BOOL)supportsEncoding
{
    return _supportsEncoding;
}

#pragma mark -
#pragma mark Table Methods

/**
 * Copies if sender == self or displays or the CREATE TABLE syntax of the selected table(s) to the user .
 */
- (void)showCreateTableSyntax:(SPDatabaseDocument *)sender {
    NSInteger colOffs = 1;
    NSString *query = nil;
    NSString *typeString = @"";
    NSString *header = @"";
    NSMutableString *createSyntax = [NSMutableString string];

    NSIndexSet *indexes = [[tablesListInstance valueForKeyPath:@"tablesListView"] selectedRowIndexes];

    NSUInteger currentIndex = [indexes firstIndex];
    NSUInteger counter = 0;
    NSInteger type;

    NSArray *types = [tablesListInstance selectedTableTypes];
    NSArray *items = [tablesListInstance selectedTableItems];

    while (currentIndex != NSNotFound)
    {
        type = [[types objectAtIndex:counter] intValue];
        query = nil;

        if( type == SPTableTypeTable ) {
            // Postgres doesn't support SHOW CREATE TABLE. Using a placeholder.
            query = [NSString stringWithFormat:@"SELECT 'CREATE TABLE %@ ... (Not fully implemented for Postgres)'", [[items objectAtIndex:counter] postgresQuotedIdentifier]];
            typeString = @"TABLE";
        }
        else if( type == SPTableTypeView ) {
            query = [NSString stringWithFormat:@"SELECT 'CREATE OR REPLACE VIEW ' || %@ || ' AS ' || pg_get_viewdef(%@, true)", [[items objectAtIndex:counter] postgresQuotedIdentifier], [[items objectAtIndex:counter] postgresQuotedIdentifier]];
            typeString = @"VIEW";
        }
        else if( type == SPTableTypeProc ) {
            query = [NSString stringWithFormat:@"SELECT pg_get_functiondef(%@::regproc)", [[items objectAtIndex:counter] postgresQuotedIdentifier]];
            typeString = @"PROCEDURE";
            colOffs = 0; // pg_get_functiondef returns 1 column
        }
        else if( type == SPTableTypeFunc ) {
            query = [NSString stringWithFormat:@"SELECT pg_get_functiondef(%@::regproc)", [[items objectAtIndex:counter] postgresQuotedIdentifier]];
            typeString = @"FUNCTION";
            colOffs = 0; // pg_get_functiondef returns 1 column
        }

        if (query == nil) {
            NSLog(@"Unknown type for selected item while getting the create syntax for '%@'", [items objectAtIndex:counter]);
            NSBeep();
            return;
        }

        SPPostgresResult *theResult = [postgresConnection queryString:query];
        [theResult setReturnDataAsStrings:YES];

        // Check for errors, only displaying if the connection hasn't been terminated
        if ([postgresConnection queryErrored]) {
            if ([postgresConnection isConnected]) {
                [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error message title") message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while creating table syntax.\n\n: %@", @"Error shown when unable to show create table syntax"), [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
            }

            return;
        }

        NSString *tableSyntax;
        // PostgreSQL functions don't use MySQL's DELIMITER syntax — use the raw pg_get_functiondef output
        tableSyntax = [[theResult getRowAsArray] objectAtIndex:colOffs];

        // A NULL value indicates that the user does not have permission to view the syntax
        if ([tableSyntax isNSNull]) {
            [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Permission Denied", @"Permission Denied") message:NSLocalizedString(@"The creation syntax could not be retrieved due to a permissions error.\n\nPlease check your user permissions with an administrator.", @"Create syntax permission denied detail") callback:nil];
            return;
        }

        if([indexes count] > 1)
            header = [NSString stringWithFormat:@"-- Create syntax for %@ '%@'\n", typeString, [items objectAtIndex:counter]];

        [createSyntax appendFormat:@"%@%@;%@", header, (type == SPTableTypeView) ? [tableSyntax createViewSyntaxPrettifier] : tableSyntax, (counter < [indexes count]-1) ? @"\n\n" : @""];

        counter++;

        // Get next index (beginning from the end)
        currentIndex = [indexes indexGreaterThanIndex:currentIndex];

    }

    // copy to the clipboard if sender was self, otherwise
    // show syntax(es) in sheet
    if (sender == self) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb declareTypes:@[NSPasteboardTypeString] owner:self];
        [pb setString:createSyntax forType:NSPasteboardTypeString];

        // Table syntax copied notification
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"Syntax Copied";
        notification.informativeText=[NSString stringWithFormat:NSLocalizedString(@"Syntax for %@ table copied", @"description for table syntax copied notification"), [self table]];
        notification.soundName = NSUserNotificationDefaultSoundName;

        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];

        return;
    }

    if ([indexes count] == 1) [createTableSyntaxTextField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Create syntax for %@ '%@'", @"Create syntax label"), typeString, [self table]]];
    else                      [createTableSyntaxTextField setStringValue:NSLocalizedString(@"Create syntaxes for selected items", @"Create syntaxes for selected items label")];

    [createTableSyntaxTextView setEditable:YES];
    [createTableSyntaxTextView setString:@""];
    [createTableSyntaxTextView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:createSyntax]];
    [createTableSyntaxTextView setEditable:NO];

    [createTableSyntaxWindow makeFirstResponder:createTableSyntaxTextField];

    // Show variables sheet
    [[self.parentWindowController window] beginSheet:createTableSyntaxWindow completionHandler:nil];
}

/**
 * Copies the CREATE TABLE syntax of the selected table to the pasteboard.
 */
- (void)copyCreateTableSyntax:(SPDatabaseDocument *)sender {
    [self showCreateTableSyntax:self];

    return;
}

/**
 * Performs a PostgreSQL check table on the selected table and presents the result to the user via an alert sheet.
 */
- (void)checkTable {
    NSArray *selectedItems = [tablesListInstance selectedTableItems];
    id message = nil;

    if([selectedItems count] == 0) return;

    // CHECK TABLE not supported in Postgres
    SPPostgresResult *theResult = nil; // [postgresConnection queryString:[NSString stringWithFormat:@"CHECK TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];
    [theResult setReturnDataAsStrings:YES];

    NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

    // Check for errors, only displaying if the connection hasn't been terminated
    if ([postgresConnection queryErrored]) {
        NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to check selected items", @"unable to check selected items message") : NSLocalizedString(@"Unable to check table", @"unable to check table message");
        if ([postgresConnection isConnected]) {
            [NSAlert createWarningAlertWithTitle:mText message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while trying to check the %@.\n\nPostgreSQL said:%@",@"an error occurred while trying to check the %@.\n\nPostgreSQL said:%@"), what, [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
        }

        return;
    }

    NSArray *resultStatuses = [theResult getAllRows];
    BOOL statusOK = YES;
    for (NSDictionary *eachRow in theResult) {
        if (![[eachRow objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
            statusOK = NO;
            break;
        }
    }

    // Process result
    if([selectedItems count] == 1) {
        NSDictionary *lastresult = [resultStatuses lastObject];

        message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Check table successfully passed.",@"check table successfully passed message") : NSLocalizedString(@"Check table failed.", @"check table failed message");

        message = [NSString stringWithFormat:NSLocalizedString(@"%@\n\nPostgreSQL said: %@", @"Error display text, showing original PostgreSQL error"), message, [lastresult objectForKey:@"Msg_text"]];
    } else if(statusOK) {
        message = NSLocalizedString(@"Check of all selected items successfully passed.",@"check of all selected items successfully passed message");
    }

    if(message) {
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Check %@", @"CHECK one or more tables - result title"), what] message:message callback:nil];
    } else {
        message = NSLocalizedString(@"PostgreSQL said:",@"PostgreSQL error message");
        statusValues = resultStatuses;

        [NSAlert createAccessoryWarningAlertWithTitle:NSLocalizedString(@"Error while checking selected items", @"error while checking selected items message") message:message accessoryView:statusTableAccessoryView callback:^{
            if (self->statusValues) {
                self->statusValues = nil;
            }
        }];
    }
}

/**
 * Analyzes the selected table and presents the result to the user via an alert sheet.
 */
- (void)analyzeTable {
    NSArray *selectedItems = [tablesListInstance selectedTableItems];
    id message = nil;

    if([selectedItems count] == 0) return;

    SPPostgresResult *theResult = [postgresConnection queryString:[NSString stringWithFormat:@"ANALYZE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];
    [theResult setReturnDataAsStrings:YES];

    NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

    // Check for errors, only displaying if the connection hasn't been terminated
    if ([postgresConnection queryErrored]) {
        NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to analyze selected items", @"unable to analyze selected items message") : NSLocalizedString(@"Unable to analyze table", @"unable to analyze table message");
        if ([postgresConnection isConnected]) {
            [NSAlert createWarningAlertWithTitle:mText message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while analyzing the %@.\n\nPostgreSQL said:%@",@"an error occurred while analyzing the %@.\n\nPostgreSQL said:%@"), what, [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
        }

        return;
    }

    NSArray *resultStatuses = [theResult getAllRows];
    BOOL statusOK = YES;
    for (NSDictionary *eachRow in resultStatuses) {
        if(![[eachRow objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
            statusOK = NO;
            break;
        }
    }

    // Process result
    if([selectedItems count] == 1) {
        NSDictionary *lastresult = [resultStatuses lastObject];

        message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Successfully analyzed table.",@"analyze table successfully passed message") : NSLocalizedString(@"Analyze table failed.", @"analyze table failed message");

        message = [NSString stringWithFormat:NSLocalizedString(@"%@\n\nPostgreSQL said: %@", @"Error display text, showing original PostgreSQL error"), message, [lastresult objectForKey:@"Msg_text"]];
    } else if(statusOK) {
        message = NSLocalizedString(@"Successfully analyzed all selected items.",@"successfully analyzed all selected items message");
    }

    if(message) {
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Analyze %@", @"ANALYZE one or more tables - result title"), what] message:message callback:nil];
    } else {
        message = NSLocalizedString(@"PostgreSQL said:",@"PostgreSQL error message");

        statusValues = resultStatuses;
        [NSAlert createAccessoryWarningAlertWithTitle:NSLocalizedString(@"Error while analyzing selected items", @"error while analyzing selected items message") message:message accessoryView:statusTableAccessoryView callback:^{
            if (self->statusValues) {
                self->statusValues = nil;
            }
        }];
    }
}

/**
 * Optimizes the selected table and presents the result to the user via an alert sheet.
 */
- (void)optimizeTable {

    NSArray *selectedItems = [tablesListInstance selectedTableItems];
    id message = nil;

    if([selectedItems count] == 0) return;

    SPPostgresResult *theResult = [postgresConnection queryString:[NSString stringWithFormat:@"VACUUM %@", [selectedItems componentsJoinedAndBacktickQuoted]]];
    [theResult setReturnDataAsStrings:YES];

    NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

    // Check for errors, only displaying if the connection hasn't been terminated
    if ([postgresConnection queryErrored]) {
        NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to optimze selected items", @"unable to optimze selected items message") : NSLocalizedString(@"Unable to optimze table", @"unable to optimze table message");
        if ([postgresConnection isConnected]) {
            [NSAlert createWarningAlertWithTitle:mText message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while optimzing the %@.\n\nPostgreSQL said:%@",@"an error occurred while trying to optimze the %@.\n\nPostgreSQL said:%@"), what, [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
        }
        return;
    }

    NSArray *resultStatuses = [theResult getAllRows];
    BOOL statusOK = YES;
    for (NSDictionary *eachRow in resultStatuses) {
        if (![[eachRow objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
            statusOK = NO;
            break;
        }
    }

    // Process result
    if([selectedItems count] == 1) {
        NSDictionary *lastresult = [resultStatuses lastObject];

        message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Successfully optimized table.",@"optimize table successfully passed message") : NSLocalizedString(@"Optimize table failed.", @"optimize table failed message");

        message = [NSString stringWithFormat:NSLocalizedString(@"%@\n\nPostgreSQL said: %@", @"Error display text, showing original PostgreSQL error"), message, [lastresult objectForKey:@"Msg_text"]];
    } else if(statusOK) {
        message = NSLocalizedString(@"Successfully optimized all selected items.",@"successfully optimized all selected items message");
    }

    if(message) {
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Optimize %@", @"OPTIMIZE one or more tables - result title"), what] message:message callback:nil];
    } else {
        message = NSLocalizedString(@"PostgreSQL said:",@"PostgreSQL error message");

        statusValues = resultStatuses;

        [NSAlert createAccessoryWarningAlertWithTitle:NSLocalizedString(@"Error while optimizing selected items", @"error while optimizing selected items message") message:message accessoryView:statusTableAccessoryView callback:^{
            if (self->statusValues) {
                self->statusValues = nil;
            }
        }];
    }
}

/**
 * Repairs the selected table and presents the result to the user via an alert sheet.
 */
- (void)repairTable {
    NSArray *selectedItems = [tablesListInstance selectedTableItems];
    id message = nil;

    if([selectedItems count] == 0) return;

    // REPAIR TABLE not supported in Postgres
    SPPostgresResult *theResult = nil; // [postgresConnection queryString:[NSString stringWithFormat:@"REPAIR TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];
    [theResult setReturnDataAsStrings:YES];

    NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

    // Check for errors, only displaying if the connection hasn't been terminated
    if ([postgresConnection queryErrored]) {
        NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to repair selected items", @"unable to repair selected items message") : NSLocalizedString(@"Unable to repair table", @"unable to repair table message");
        if ([postgresConnection isConnected]) {
            [NSAlert createWarningAlertWithTitle:mText message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while repairing the %@.\n\nPostgreSQL said:%@",@"an error occurred while trying to repair the %@.\n\nPostgreSQL said:%@"), what, [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
        }
        return;
    }

    NSArray *resultStatuses = [theResult getAllRows];
    BOOL statusOK = YES;
    for (NSDictionary *eachRow in resultStatuses) {
        if (![[eachRow objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
            statusOK = NO;
            break;
        }
    }

    // Process result
    if([selectedItems count] == 1) {
        NSDictionary *lastresult = [resultStatuses lastObject];

        message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Successfully repaired table.",@"repair table successfully passed message") : NSLocalizedString(@"Repair table failed.", @"repair table failed message");

        message = [NSString stringWithFormat:NSLocalizedString(@"%@\n\nPostgreSQL said: %@", @"Error display text, showing original PostgreSQL error"), message, [lastresult objectForKey:@"Msg_text"]];
    } else if(statusOK) {
        message = NSLocalizedString(@"Successfully repaired all selected items.",@"successfully repaired all selected items message");
    }

    if(message) {
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Repair %@", @"REPAIR one or more tables - result title"), what] message:message callback:nil];
    } else {
        message = NSLocalizedString(@"PostgreSQL said:",@"PostgreSQL error message");

        statusValues = resultStatuses;

        [NSAlert createAccessoryWarningAlertWithTitle:NSLocalizedString(@"Error while repairing selected items", @"error while repairing selected items message") message:message accessoryView:statusTableAccessoryView callback:^{
            if (self->statusValues) {
                self->statusValues = nil;
            }
        }];
    }
}

/**
 * Flush the selected table and inform the user via a dialog sheet.
 */
- (void)flushTable {
    NSArray *selectedItems = [tablesListInstance selectedTableItems];
    id message = nil;

    if([selectedItems count] == 0) return;

    // FLUSH TABLE not supported in Postgres
    SPPostgresResult *theResult = nil; // [postgresConnection queryString:[NSString stringWithFormat:@"FLUSH TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];
    [theResult setReturnDataAsStrings:YES];

    NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

    // Check for errors, only displaying if the connection hasn't been terminated
    if ([postgresConnection queryErrored]) {
        NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to flush selected items", @"unable to flush selected items message") : NSLocalizedString(@"Unable to flush table", @"unable to flush table message");
        if ([postgresConnection isConnected]) {
            [NSAlert createWarningAlertWithTitle:mText message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while flushing the %@.\n\nPostgreSQL said:%@",@"an error occurred while trying to flush the %@.\n\nPostgreSQL said:%@"), what, [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
        }

        return;
    }

    NSArray *resultStatuses = [theResult getAllRows];
    BOOL statusOK = YES;
    for (NSDictionary *eachRow in resultStatuses) {
        if (![[eachRow objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
            statusOK = NO;
            break;
        }
    }

    // Process result
    if([selectedItems count] == 1) {
        NSDictionary *lastresult = [resultStatuses lastObject];

        message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Successfully flushed table.",@"flush table successfully passed message") : NSLocalizedString(@"Flush table failed.", @"flush table failed message");

        message = [NSString stringWithFormat:NSLocalizedString(@"%@\n\nPostgreSQL said: %@", @"Error display text, showing original PostgreSQL error"), message, [lastresult objectForKey:@"Msg_text"]];
    } else if(statusOK) {
        message = NSLocalizedString(@"Successfully flushed all selected items.",@"successfully flushed all selected items message");
    }

    if(message) {
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Flush %@", @"FLUSH one or more tables - result title"), what] message:message callback:nil];
    } else {
        message = NSLocalizedString(@"PostgreSQL said:",@"PostgreSQL error message");

        statusValues = resultStatuses;

        [NSAlert createAccessoryWarningAlertWithTitle:NSLocalizedString(@"Error while flushing selected items", @"error while flushing selected items message") message:message accessoryView:statusTableAccessoryView callback:^{
            if (self->statusValues) {
                self->statusValues = nil;
            }
        }];
    }
}

/**
 * Runs a PostgreSQL checksum on the selected table and present the result to the user via an alert sheet.
 */
- (void)checksumTable {
    NSArray *selectedItems = [tablesListInstance selectedTableItems];
    id message = nil;

    if([selectedItems count] == 0) return;

    // CHECKSUM TABLE not supported in Postgres
    SPPostgresResult *theResult = nil; // [postgresConnection queryString:[NSString stringWithFormat:@"CHECKSUM TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];

    NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

    // Check for errors, only displaying if the connection hasn't been terminated
    if ([postgresConnection queryErrored]) {
        if ([postgresConnection isConnected]) {
            NSString *alertMessage = [NSString stringWithFormat:NSLocalizedString(@"An error occurred while performing the checksum on %@.\n\nPostgreSQL said:%@",@"an error occurred while performing the checksum on the %@.\n\nPostgreSQL said:%@"), what, [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")];
            [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Unable to perform the checksum", @"unable to perform the checksum") message:alertMessage callback:nil];
        }

        return;
    }

    // Process result
    NSArray *resultStatuses = [theResult getAllRows];
    if([selectedItems count] == 1) {
        message = [[resultStatuses lastObject] objectForKey:@"Checksum"];
        NSString *alertMessage = [NSString stringWithFormat:NSLocalizedString(@"Table checksum: %@", @"table checksum: %@"), message];
        [NSAlert createWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Checksum %@", @"checksum %@ message"), what] message:alertMessage callback:nil];
    } else {

        statusValues = resultStatuses;

        [NSAlert createAccessoryWarningAlertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Checksums of %@",@"Checksums of %@ message"), what] message:message accessoryView:statusTableAccessoryView callback:^{
            if (self->statusValues) {
                self->statusValues = nil;
            }
        }];
    }
}

/**
 * Saves the current tables create syntax to the selected file.
 */
- (IBAction)saveCreateSyntax:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];

    [panel setAllowedFileTypes:@[SPFileExtensionSQL]];

    [panel setExtensionHidden:NO];
    [panel setAllowsOtherFileTypes:YES];
    [panel setCanSelectHiddenExtension:YES];

    [panel setNameFieldStringValue:[NSString stringWithFormat:@"CreateSyntax-%@", [self table]]];
    [panel beginSheetModalForWindow:createTableSyntaxWindow completionHandler:^(NSInteger returnCode) {
        if (returnCode == NSModalResponseOK) {
            NSString *createSyntax = [self->createTableSyntaxTextView string];

            if ([createSyntax length] > 0) {
                NSString *output = [NSString stringWithFormat:@"-- %@ '%@'\n\n%@\n", NSLocalizedString(@"Create syntax for", @"create syntax for table comment"), [self table], createSyntax];

                [output writeToURL:[panel URL] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
        }
    }];
}

/**
 * Copy the create syntax in the create syntax text view to the pasteboard.
 */
- (IBAction)copyCreateTableSyntaxFromSheet:(id)sender
{
    NSString *createSyntax = [createTableSyntaxTextView string];

    if ([createSyntax length] > 0) {
        // Copy to the clipboard
        NSPasteboard *pb = [NSPasteboard generalPasteboard];

        [pb declareTypes:@[NSPasteboardTypeString] owner:self];
        [pb setString:createSyntax forType:NSPasteboardTypeString];

        // Table syntax copied notification
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"Syntax Copied";
        notification.informativeText=[NSString stringWithFormat:NSLocalizedString(@"Syntax for %@ table copied", @"description for table syntax copied notification"), [self table]];
        notification.soundName = NSUserNotificationDefaultSoundName;

        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    }
}

/**
 * Switches to the content view and makes the filter field the first responder (has focus).
 */
- (void)focusOnTableContentFilter {
    [self viewContent];

    [tableContentInstance performSelector:@selector(makeContentFilterHaveFocus) withObject:nil afterDelay:0.1];
}

/**
 * Switches to the content view and makes the advanced filter view the first responder
 */
- (void)showFilterTable {
    [self viewContent];

    [tableContentInstance toggleRuleEditorVisible:nil];
}

/**
 * Allow Command-F to set the focus to the content view filter if that view is active
 */
- (void)performFindPanelAction:(id)sender
{
    [tableContentInstance makeContentFilterHaveFocus];
}

/**
 * Exports the selected tables in the chosen file format.
 */

- (IBAction)exportSelectedTablesAs:(id)sender
{
    [exportControllerInstance exportTables:[tablesListInstance selectedTableItems] asFormat:[sender tag] usingSource:SPTableExport];
}

/**
 * Opens the data export dialog.
 */
- (void)exportData {
    if (_isConnected) {
        [exportControllerInstance exportData];
    }
}

#pragma mark -
#pragma mark Other Methods

- (IBAction)multipleLineEditingButtonClicked:(NSButton *)sender{
    SPLog(@"multipleLineEditingButtonClicked. State: %ld",(long)[sender state]);
    user_defaults_set_bool(SPEditInSheetEnabled,[sender state]);
}

/**
 * Set that query which will be inserted into the Query Editor
 * after establishing the connection
 */

- (void)initQueryEditorWithString:(NSString *)query
{
    queryEditorInitString = query;
}

/**
 * Invoked when user hits the cancel button or close button in
 * dialogs such as the variableSheet or the createTableSyntaxSheet
 */
- (IBAction)closeSheet:(id)sender
{
    [NSApp stopModalWithCode:0];
}

/**
 * Closes either the server variables or create syntax sheets.
 */
- (IBAction)closePanelSheet:(id)sender
{
    [NSApp endSheet:[sender window] returnCode:[sender tag]];
    [[sender window] orderOut:self];
}

/**
 * Displays the user account manager.
 */
- (void)showUserManager {
    if (!userManagerInstance) {
        userManagerInstance = [[SPUserManager alloc] init];

        [userManagerInstance setDatabaseDocument:self];
        [userManagerInstance setConnection:postgresConnection];
        [userManagerInstance setServerSupport:serverSupport];
    }

    // Before displaying the user manager make sure the current user has access to the pg_catalog.pg_user view.
    SPPostgresResult *result = [postgresConnection queryString:@"SELECT usename FROM pg_user LIMIT 1"];

    if ([postgresConnection queryErrored] && ([result numberOfRows] == 0)) {

        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Unable to get list of users", @"unable to get list of users message") message:NSLocalizedString(@"An error occurred while trying to get the list of users. Please make sure you have the necessary privileges to perform user management, including access to the pg_catalog.pg_user view.", @"unable to get list of users informative message") callback:nil];
        return;
    }

    [userManagerInstance beginSheetModalForWindow:[self.parentWindowController window] completionHandler:^(){
        //Release the UserManager instance after completion
        self->userManagerInstance = nil;
    }];
}

/**
 * Passes query to tablesListInstance
 */
- (void)doPerformQueryService:(NSString *)query {
    [self viewQuery];
    [customQueryInstance doPerformQueryService:query];
}

/**
 * Inserts query into the Custom Query editor
 */
- (void)doPerformLoadQueryService:(NSString *)query {
    [self viewQuery];
    [customQueryInstance doPerformLoadQueryService:query];
}

/**
 * Flushes the mysql privileges
 */
- (void)flushPrivileges {
    [postgresConnection queryString:@"FLUSH PRIVILEGES"];

    if (![postgresConnection queryErrored]) {
        //flushed privileges without errors
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Flushed Privileges", @"title of panel when successfully flushed privs") message:NSLocalizedString(@"Successfully flushed privileges.", @"message of panel when successfully flushed privs") callback:nil];
    } else {
        //error while flushing privileges
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't flush privileges.\nPostgreSQL said: %@", @"message of panel when flushing privs failed"), [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
    }
}

/**
 * Ask the connection controller to initiate connection, if it hasn't
 * already.  Used to support automatic connections on window open,
 */
- (void)connect
{
    SPLog(@"connect in dbdoc");

    if (postgresVersion) return;
    [connectionController initiateConnection:self];
}

- (void)closeConnection {
    SPLog(@"closeConnection");
    [postgresConnection setDelegate:nil];

    SPLog(@"Closing postgresConnection");
    [postgresConnection disconnect];
  
    SPLog(@"Closing databaseStructureRetrieval");
    [[databaseStructureRetrieval connection] disconnect];

    _isConnected = NO;

    // Disconnected notification
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = @"Disconnected";
    notification.soundName = NSUserNotificationDefaultSoundName;

    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

/**
 * This method is called as part of Key Value Observing which is used to watch for prefernce changes which effect the interface.
 */
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:SPConsoleEnableLogging]) {
        [postgresConnection setDelegateQueryLogging:[[change objectForKey:NSKeyValueChangeNewKey] boolValue]];
    }
    else if ([keyPath isEqualToString:SPEditInSheetEnabled]) {
        multipleLineEditingButton.state = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
    }
}

- (SPHelpViewerClient *)helpViewerClient
{
    return helpViewerClientInstance;
}

/**
 * Is current document Untitled?
 */
- (BOOL)isUntitled
{
    return (!_isSavedInBundle && [self fileURL] && [[self fileURL] isFileURL]) ? NO : YES;
}

/**
 * Asks any currently editing views to commit their changes;
 * returns YES if changes were successfully committed, and NO
 * if an error occurred or user interaction is required.
 */
- (BOOL)couldCommitCurrentViewActions
{
    [[self.parentWindowController window] endEditingFor:nil];
    switch ([self currentlySelectedView]) {

        case SPTableViewStructure:
            return [tableSourceInstance saveRowOnDeselect];

        case SPTableViewContent:
            return [tableContentInstance saveRowOnDeselect];

        default:
            break;
    }

    return YES;
}

#pragma mark -
#pragma mark Accessor methods

/**
 * Returns the host
 */
- (NSString *)host
{
    if ([connectionController type] == SPSocketConnection) return @"localhost";

    NSString *host = [connectionController host];

    if (!host) host = @"";

    return host;
}

/**
 * Returns the name
 */
- (NSString *)name
{
    if ([connectionController name] && [[connectionController name] length]) {
        return [connectionController name];
    }

    if ([connectionController type] == SPSocketConnection) {
        return [NSString stringWithFormat:@"%@@localhost", ([connectionController user] && [[connectionController user] length])?[connectionController user]:@"anonymous"];
    }

    return [NSString stringWithFormat:@"%@@%@", ([connectionController user] && [[connectionController user] length])?[connectionController user]:@"anonymous", [connectionController host]?[connectionController host]:@""];
}

/**
 * Returns a string to identify the connection uniquely (mainly used to set up db structure with unique keys)
 */
- (NSString *)connectionID
{
    if (!_isConnected) return @"_";

    NSString *port = [[self port] length] ? [NSString stringWithFormat:@":%@", [self port]] : @"";

    switch ([connectionController type])
    {
        case SPSocketConnection:
            return [NSString stringWithFormat:@"%@@localhost%@", ([connectionController user] && [[connectionController user] length])?[connectionController user]:@"anonymous", port];
            break;
        case SPTCPIPConnection:
            return [NSString stringWithFormat:@"%@@%@%@",
                    ([connectionController user] && [[connectionController user] length]) ? [connectionController user] : @"anonymous",
                    [connectionController host] ? [connectionController host] : @"",
                    port];
            break;
        case SPSSHTunnelConnection:
            return [NSString stringWithFormat:@"%@@%@%@&SSH&%@@%@:%@",
                    ([connectionController user] && [[connectionController user] length]) ? [connectionController user] : @"anonymous",
                    [connectionController host] ? [connectionController host] : @"", port,
                    ([connectionController sshUser] && [[connectionController sshUser] length]) ? [connectionController sshUser] : @"anonymous",
                    [connectionController sshHost] ? [connectionController sshHost] : @"",
                    ([[connectionController sshPort] length]) ? [connectionController sshPort] : @"22"];
    }

    return @"_";
}

/**
 * Returns the full window title which is mainly used for tab tooltips
 */

- (NSString *)tabTitleForTooltip
{
    NSMutableString *tabTitle;

    // Determine name details
    NSString *pathName = @"";
    if ([[[self fileURL] path] length] && ![self isUntitled]) {
        pathName = [NSString stringWithFormat:@"%@ — ", [[[self fileURL] path] lastPathComponent]];
    }

    if ([connectionController isConnecting]) {
        return NSLocalizedString(@"Connecting…", @"window title string indicating that sp is connecting");
    }

    if ([self getConnection] == nil) return [NSString stringWithFormat:@"%@%@", pathName, [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString*)kCFBundleNameKey]];

    tabTitle = [NSMutableString string];

    // Add the PostgreSQL version to the window title if enabled in prefs
    if ([prefs boolForKey:SPDisplayServerVersionInWindowTitle]) [tabTitle appendFormat:@"(PostgreSQL %@)\n", [self postgresVersion]];

    [tabTitle appendString:[self name]];
    if ([self database]) {
        if ([tabTitle length]) [tabTitle appendString:@"/"];
        [tabTitle appendString:[self database]];
    }
    if ([[self table] length]) {
        if ([tabTitle length]) [tabTitle appendString:@"/"];
        [tabTitle appendString:[self table]];
    }
    return tabTitle;
}

/**
 * Returns the currently selected database
 */
- (NSString *)database
{
    return selectedDatabase;
}

/**
 * Returns the PostgreSQL version
 */
- (NSString *)postgresVersion
{
    return postgresVersion;
}

/**
 * Returns the current user
 */
- (NSString *)user
{
    NSString *theUser = [connectionController user];
    if (!theUser) theUser = @"";
    return theUser;
}

/**
 * Returns the current host's port
 */
- (NSString *)port
{
    NSString *thePort = [connectionController port];
    if (!thePort) return @"";
    return thePort;
}

- (BOOL)isSaveInBundle
{
    return _isSavedInBundle;
}

- (NSArray *)allTableNames
{
    return [tablesListInstance allTableNames];
}

- (SPCreateDatabaseInfo *)createDatabaseInfo
{
    SPCreateDatabaseInfo *dbInfo = [[SPCreateDatabaseInfo alloc] init];

    [dbInfo setDatabaseName:[self database]];
    [dbInfo setDefaultEncoding:[databaseDataInstance getDatabaseDefaultCharacterSet]];
    [dbInfo setDefaultCollation:[databaseDataInstance getDatabaseDefaultCollation]];

    return dbInfo;
}

/**
 * Retrieve the view that is currently selected from the database
 *
 * MUST BE CALLED ON THE UI THREAD!
 */
- (SPTableViewType)currentlySelectedView
{
    SPTableViewType theView = NSNotFound;

    // -selectedTabViewItem is a UI method according to Xcode 9.2!
    // jamesstout note - this is called a LOT.
    // using tableViewTypeEnumFromString is 5-7x faster than if/else isEqualToString:
    NSString *viewName = [[[tableTabView onMainThread] selectedTabViewItem] identifier];

    SPTableViewType enumValue = [viewName tableViewTypeEnumFromString];

    switch (enumValue) {
        case SPTableViewStructure:
            theView = SPTableViewStructure;
            break;
        case SPTableViewContent:
            theView = SPTableViewContent;
            break;
        case SPTableViewCustomQuery:
            theView = SPTableViewCustomQuery;
            break;
        case SPTableViewStatus:
            theView = SPTableViewStatus;
            break;
        case SPTableViewRelations:
            theView = SPTableViewRelations;
            break;
        case SPTableViewTriggers:
            theView = SPTableViewTriggers;
            break;
        default:
            theView = SPTableViewInvalid;
    }

    return theView;
}

#pragma mark -
#pragma mark Notification center methods

/**
 * Invoked before a query is performed
 */
- (void)willPerformQuery:(NSNotification *)notification
{
    [self setIsProcessing:YES];
    [queryProgressBar startAnimation:self];
}

/**
 * Invoked after a query has been performed
 */
- (void)hasPerformedQuery:(NSNotification *)notification
{
    [self setIsProcessing:NO];
    [queryProgressBar stopAnimation:self];
}

/**
 * Invoked when the application will terminate
 */
- (void)applicationWillTerminate:(NSNotification *)notification
{

    SPLog(@"applicationWillTerminate");
    appIsTerminating = YES;
    // Auto-save preferences to spf file based connection
    if([self fileURL] && [[[self fileURL] path] length] && ![self isUntitled]) {
        if (_isConnected && ![self saveDocumentWithFilePath:nil inBackground:YES onlyPreferences:YES contextInfo:nil]) {
            NSLog(@"Preference data for file ‘%@’ could not be saved.", [[self fileURL] path]);
            NSBeep();
        }
    }

    [tablesListInstance selectionShouldChangeInTableView:nil];

    // Note that this call does not need to be removed in release builds as leaks analysis output is only
    // dumped if [[SPLogger logger] setDumpLeaksOnTermination]; has been called first.
    [[SPLogger logger] dumpLeaks];
}

#pragma mark -
#pragma mark Tab methods

/**
 * Invoked to determine whether the parent tab is allowed to close
 */
- (BOOL)parentTabShouldClose {

    // If no connection is available, always return YES.  Covers initial setup and disconnections.
    if(!_isConnected) {
        return YES;
    }

    // If tasks are active, return NO to allow tasks to complete
    if (_isWorkingLevel) {
        return NO;
    }

    // If the table list considers itself to be working, return NO. This catches open alerts, and
    // edits in progress in various views.
    if (![tablesListInstance selectionShouldChangeInTableView:nil]) {
        return NO;
    }

    // Auto-save spf file based connection and return if the save was not successful
    if ([self fileURL] && [[[self fileURL] path] length] && ![self isUntitled]) {
        BOOL isSaved = [self saveDocumentWithFilePath:nil inBackground:YES onlyPreferences:YES contextInfo:nil];
        if (isSaved) {
            [[SPQueryController sharedQueryController] removeRegisteredDocumentWithFileURL:[self fileURL]];
        } else {
            return NO;
        }
    }

    // Terminate all running BASH commands
    for (NSDictionary* cmd in [self runningActivities]) {
        NSInteger pid = [[cmd objectForKey:@"pid"] integerValue];
        NSTask *killTask = [[NSTask alloc] init];
        [killTask setLaunchPath:@"/bin/sh"];
        [killTask setArguments:[NSArray arrayWithObjects:@"-c", [NSString stringWithFormat:@"kill -9 -%ld", (long)pid], nil]];
        [killTask launch];
        [killTask waitUntilExit];
    }

    [[SPNavigatorController sharedNavigatorController] performSelectorOnMainThread:@selector(removeConnection:) withObject:[self connectionID] waitUntilDone:YES];

    // Note that this call does not need to be removed in release builds as leaks analysis output is only
    // dumped if [[SPLogger logger] setDumpLeaksOnTermination]; has been called first.
    [[SPLogger logger] dumpLeaks];
    // Return YES by default
    return YES;
}

#pragma mark -
#pragma mark Connection controller delegate methods

/**
 * Invoked by the connection controller when it starts the process of initiating a connection.
 */
- (void)connectionControllerInitiatingConnection:(SPConnectionController *)controller
{
    [[self.parentWindowController window] setTitle:NSLocalizedString(@"Connecting…", @"window title string indicating that sp is connecting")];
}

/**
 * Invoked by the connection controller when the attempt to initiate a connection failed.
 */
- (void)connectionControllerConnectAttemptFailed:(SPConnectionController *)controller
{
    // Reset the window title
    [self updateWindowTitle:self];
}

- (SPConnectionController*)connectionController
{
    return connectionController;
}

#pragma mark -
#pragma mark -
#pragma mark Text field delegate methods

/**
 * When adding a database, enable the button only if the new name has a length.
 */
- (void)controlTextDidChange:(NSNotification *)notification
{
    id object = [notification object];

    if (object == databaseNameField) {
        [addDatabaseButton setEnabled:([[databaseNameField stringValue] length] > 0 && ![allDatabases containsObject: [databaseNameField stringValue]])];
    }
    else if (object == databaseCopyNameField) {
        [copyDatabaseButton setEnabled:([[databaseCopyNameField stringValue] length] > 0 && ![allDatabases containsObject: [databaseCopyNameField stringValue]])];
    }
    else if (object == databaseRenameNameField) {
        [renameDatabaseButton setEnabled:([[databaseRenameNameField stringValue] length] > 0 && ![allDatabases containsObject: [databaseRenameNameField stringValue]])];
    }
    else if (object == self.saveConnectionEncryptString) {
        [self.saveConnectionEncryptString setStringValue:[self.saveConnectionEncryptString stringValue]];
    }
}

#pragma mark -
#pragma mark General sheet delegate methods

- (NSRect)window:(NSWindow *)window willPositionSheet:(NSWindow *)sheet usingRect:(NSRect)rect {

    // Locate the sheet "Reset Auto Increment" just centered beneath the chosen index row
    // if Structure Pane is active
    if([self currentlySelectedView] == SPTableViewStructure
       && [[sheet title] isEqualToString:@"Reset Auto Increment"]) {

        id it = [tableSourceInstance valueForKeyPath:@"indexesTableView"];
        NSRect mwrect = [[NSApp mainWindow] frame];
        NSRect ltrect = [[tablesListInstance valueForKeyPath:@"tablesListView"] frame];
        NSRect rowrect = [it rectOfRow:[it selectedRow]];
        rowrect.size.width = mwrect.size.width - ltrect.size.width;
        rowrect.origin.y -= [it rowHeight]/2.0f+2;
        rowrect.origin.x -= 8;
        return [it convertRect:rowrect toView:nil];

    }

    return rect;
}

#pragma mark -
#pragma mark SplitView delegate methods

- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMinimumPosition ofSubviewAt:(NSInteger)dividerIndex
{
    if (dividerIndex == 0 && proposedMinimumPosition < 40) {
        return 40;
    }
    return proposedMinimumPosition;
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMaximumPosition ofSubviewAt:(NSInteger)dividerIndex
{
    //the right side of the SP window must be at least 505px wide or the UI will break!
    if(dividerIndex == 0) {
        return proposedMaximumPosition - 505;
    }
    return proposedMaximumPosition;
}

#pragma mark -
#pragma mark Datasource methods

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
    return (statusTableView && aTableView == statusTableView) ? [statusValues count] : 0;
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
    if (statusTableView && aTableView == statusTableView && rowIndex < (NSInteger)[statusValues count]) {
        if ([[aTableColumn identifier] isEqualToString:@"table_name"]) {
            if([[statusValues objectAtIndex:rowIndex] objectForKey:@"table_name"])
                return [[statusValues objectAtIndex:rowIndex] objectForKey:@"table_name"];
            else if([[statusValues objectAtIndex:rowIndex] objectForKey:@"Table"])
                return [[statusValues objectAtIndex:rowIndex] objectForKey:@"Table"];
            return @"";
        }
        else if ([[aTableColumn identifier] isEqualToString:@"msg_status"]) {
            if([[statusValues objectAtIndex:rowIndex] objectForKey:@"Msg_type"])
                return [[[statusValues objectAtIndex:rowIndex] objectForKey:@"Msg_type"] capitalizedString];
            return @"";
        }
        else if ([[aTableColumn identifier] isEqualToString:@"msg_text"]) {
            if([[statusValues objectAtIndex:rowIndex] objectForKey:@"Msg_text"]) {
                [[aTableColumn headerCell] setStringValue:NSLocalizedString(@"Message",@"message column title")];
                return [[statusValues objectAtIndex:rowIndex] objectForKey:@"Msg_text"];
            }
            else if([[statusValues objectAtIndex:rowIndex] objectForKey:@"Checksum"]) {
                [[aTableColumn headerCell] setStringValue:@"Checksum"];
                return [[statusValues objectAtIndex:rowIndex] objectForKey:@"Checksum"];
            }
            return @"";
        }
    }
    return nil;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldEditTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
    return NO;
}

#pragma mark -
#pragma mark Status accessory view

- (IBAction)copyChecksumFromSheet:(id)sender
{
    NSMutableString *tmp = [NSMutableString string];
    for(id row in statusValues) {
        if ([row objectForKey:@"Msg_type"]) {
            [tmp appendFormat:@"%@\t%@\t%@\n",
             [[row objectForKey:@"Table"] description],
             [[row objectForKey:@"Msg_type"] description],
             [[row objectForKey:@"Msg_text"] description]];
        } else {
            [tmp appendFormat:@"%@\t%@\n",
             [[row objectForKey:@"Table"] description],
             [[row objectForKey:@"Checksum"] description]];
        }
    }

    if ( [tmp length] )
    {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];

        [pb declareTypes:@[NSPasteboardTypeTabularText, NSPasteboardTypeString] owner:nil];

        [pb setString:tmp forType:NSPasteboardTypeString];
        [pb setString:tmp forType:NSPasteboardTypeTabularText];
    }
}

- (void)setIsSavedInBundle:(BOOL)savedInBundle
{
    _isSavedInBundle = savedInBundle;
}

#pragma mark -
#pragma mark Private API

/**
 * Copies the current database (and optionally it's content) on a separate thread.
 *
 * This method *MUST* be called from the UI thread!
 */
- (void)_copyDatabase
{
    NSString *newDatabaseName = [databaseCopyNameField stringValue];

    if ([newDatabaseName isEqualToString:@""]) {
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:NSLocalizedString(@"Database must have a name.", @"message of panel when no db name is given") callback:nil];
        return;
    }

    NSDictionary *databaseDetails = @{
        SPNewDatabaseDetails : [self createDatabaseInfo],
        SPNewDatabaseName : newDatabaseName,
        SPNewDatabaseCopyContent : @([copyDatabaseDataButton state] == NSControlStateValueOn)
    };

    [self startTaskWithDescription:[NSString stringWithFormat:NSLocalizedString(@"Copying database '%@'...", @"Copying database task description"), [self database]]];

    if ([NSThread isMainThread]) {
        [NSThread detachNewThreadWithName:SPCtxt(@"SPDatabaseDocument copy database task", self)
                                   target:self
                                 selector:@selector(_copyDatabaseWithDetails:)
                                   object:databaseDetails];;
    }
    else {
        [self _copyDatabaseWithDetails:databaseDetails];
    }
}

- (void)_copyDatabaseWithDetails:(NSDictionary *)databaseDetails
{
    @autoreleasepool
    {
        SPDatabaseCopy *databaseCopy = [[SPDatabaseCopy alloc] init];

        [databaseCopy setConnection:[self getConnection]];

        NSString *newDatabaseName = [databaseDetails objectForKey:SPNewDatabaseName];

        BOOL success = [databaseCopy copyDatabaseFrom:[databaseDetails objectForKey:SPNewDatabaseDetails]
                                                   to:newDatabaseName
                                          withContent:[[databaseDetails objectForKey:SPNewDatabaseCopyContent] boolValue]];

        // Select newly created database
        [[self onMainThread] selectDatabase:newDatabaseName item:nil];

        // Update database list
        [[self onMainThread] setDatabases];

        // inform observers that a new database was added
        [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:SPDatabaseCreatedRemovedRenamedNotification object:nil];

        [self endTask];

        if (!success) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Unable to copy database", @"unable to copy database message") message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while trying to copy the database '%@' to '%@'.", @"unable to copy database message informative message"), [databaseDetails[SPNewDatabaseDetails] databaseName], newDatabaseName] callback:nil];
            });
        }
    }
}

/**
 * This method *MUST* be called from the UI thread!
 */
- (void)_renameDatabase
{
    NSString *newDatabaseName = [databaseRenameNameField stringValue];

    if ([newDatabaseName isEqualToString:@""]) {
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:NSLocalizedString(@"Database must have a name.", @"message of panel when no db name is given") callback:nil];
        return;
    }

    SPLog(@"_renameDatabase");
    SPDatabaseRename *dbActionRename = [[SPDatabaseRename alloc] init];

    [dbActionRename setTablesList:tablesListInstance];
    [dbActionRename setConnection:[self getConnection]];

    if ([dbActionRename renameDatabaseFrom:[self createDatabaseInfo] to:newDatabaseName]) {
        [self setDatabases];
        [self selectDatabase:newDatabaseName item:nil];
        // inform observers that a new database was added
        [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:SPDatabaseCreatedRemovedRenamedNotification object:nil];
    }
    else {
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Unable to rename database", @"unable to rename database message") message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while trying to rename the database '%@' to '%@'.", @"unable to rename database message informative message"), [self database], newDatabaseName] callback:nil];
    }
}

/**
 * Adds a new database.
 *
 * This method *MUST* be called from the UI thread!
 */
- (void)_addDatabase
{
    // This check is not necessary anymore as the add database button is now only enabled if the name field
    // has a length greater than zero. We'll leave it in just in case.
    if ([[databaseNameField stringValue] isEqualToString:@""]) {
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:NSLocalizedString(@"Database must have a name.", @"message of panel when no db name is given") callback:nil];
        return;
    }

    // As we're amending identifiers, ensure UTF8
    if (![[postgresConnection encodingName] hasPrefix:@"utf8"]) {
        [postgresConnection setEncoding:@"utf8mb4"];
    }

    SPDatabaseAction *dbAction = [[SPDatabaseAction alloc] init];
    [dbAction setConnection:postgresConnection];
    BOOL res = [dbAction createDatabase:[databaseNameField stringValue]
                           withEncoding:[addDatabaseCharsetHelper selectedCharset]
                              collation:[addDatabaseCharsetHelper selectedCollation]];

    if (!res) {
        // An error occurred
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't create database.\nPostgreSQL said: %@", @"message of panel when creation of db failed"), [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
        return;
    }

    // this refreshes the allDatabases array
    [self setDatabases];

    // inform observers that a new database was added
    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:SPDatabaseCreatedRemovedRenamedNotification object:nil];

    // Select the database
    [self selectDatabase:[databaseNameField stringValue] item:nil];
}

/**
 * Run ALTER statement against current db.
 */
- (void)_alterDatabase {
    //we'll always run the alter statement, even if old == new because after all that is what the user requested

    NSString *newCharset   = [alterDatabaseCharsetHelper selectedCharset];
    NSString *newCollation = [alterDatabaseCharsetHelper selectedCollation];

    // Postgres uses ENCODING and LC_COLLATE/LC_CTYPE.
    // NSString *alterStatement = [NSString stringWithFormat:@"ALTER DATABASE %@ DEFAULT CHARACTER SET %@", [[self database] postgresQuotedIdentifier],[newCharset postgresQuotedIdentifier]];
    NSString *alterStatement = @""; // Placeholder

    //technically there is an issue here: If a user had a non-default collation and now wants to switch to the default collation this cannot be specidifed (default == nil).
    //However if you just do an ALTER with CHARACTER SET == oldCharset MySQL will still reset the collation therefore doing exactly what we want.
    if(newCollation) {
        // alterStatement = [NSString stringWithFormat:@"%@ DEFAULT COLLATE %@",alterStatement,[newCollation postgresQuotedIdentifier]];
    }

    //run alter
    [postgresConnection queryString:alterStatement];

    if ([postgresConnection queryErrored]) {
        // An error occurred
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't alter database.\nPostgreSQL said: %@", @"Alter Database : Query Failed ($1 = PostgreSQL error message)"), [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")] callback:nil];
        return;
    }

    //invalidate old cache values
    [databaseDataInstance resetAllData];
}

/**
 * Removes the current database.
 *
 * This method *MUST* be called from the UI thread!
 */
- (void)_removeDatabase
{
    // Drop the database from the server
    [postgresConnection queryString:[NSString stringWithFormat:@"DROP DATABASE %@", [[self database] postgresQuotedIdentifier]]];

    if ([postgresConnection queryErrored]) {
        // An error occurred
        [self performSelector:@selector(showErrorSheetWith:)
                   withObject:[NSArray arrayWithObjects:NSLocalizedString(@"Error", @"error"),
                               [NSString stringWithFormat:NSLocalizedString(@"Couldn't delete the database.\nPostgreSQL said: %@", @"message of panel when deleting db failed"), [postgresConnection lastErrorMessage] ?: NSLocalizedString(@"Unknown error", @"unknown error")],
                               nil]
                   afterDelay:0.3];

        return;
    }

    // Remove db from navigator and completion list array,
    // do to threading we have to delete it from 'allDatabases' directly
    // before calling navigator
    [allDatabases removeObject:[self database]];

    // This only deletes the db and refreshes the navigator since nothing is changed
    // that's why we can run this on main thread
    [databaseStructureRetrieval queryDbStructureWithUserInfo:nil];

    [self setDatabases];

    [tablesListInstance setConnection:postgresConnection];

    // inform observers that a database was dropped
    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:SPDatabaseCreatedRemovedRenamedNotification object:nil];

    [self updateWindowTitle:self];
}

- (void)_processDatabaseChangedBundleTriggerActions
{
    NSArray __block *triggeredCommands = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
        triggeredCommands = [SPBundleManager.shared bundleCommandsForTrigger:SPBundleTriggerActionDatabaseChanged];
    });


    for (NSString* cmdPath in triggeredCommands)
    {
        NSArray *data = [cmdPath componentsSeparatedByString:@"|"];
        NSMenuItem *aMenuItem = [[NSMenuItem alloc] init];

        [aMenuItem setTag:0];
        [aMenuItem setToolTip:[data objectAtIndex:0]];

        // For HTML output check if corresponding window already exists
        BOOL stopTrigger = NO;

        if ([(NSString *)[data objectAtIndex:2] length]) {
            BOOL correspondingWindowFound = NO;
            NSString *uuid = [data objectAtIndex:2];

            for (id win in [NSApp windows])
            {
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
                if ([[[firstResponder class] description] isEqualToString:@"SPCopyTable"]) {
                    [[firstResponder onMainThread] executeBundleItemForDataTable:aMenuItem];
                }
            }
            else if([[data objectAtIndex:1] isEqualToString:SPBundleScopeInputField]) {
                if ([firstResponder isKindOfClass:[NSTextView class]]) {
                    [[firstResponder onMainThread] executeBundleItemForInputField:aMenuItem];
                }
            }
        }
    }
}

/**
 * Add any necessary preference observers to allow live updating on changes.
 */
- (void)_addPreferenceObservers
{
    // Register observers for when the DisplayTableViewVerticalGridlines preference changes
    [prefs addObserver:self forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
    [prefs addObserver:tableSourceInstance forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
    [prefs addObserver:customQueryInstance forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
    [prefs addObserver:tableRelationsInstance forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
    [prefs addObserver:self forKeyPath:SPEditInSheetEnabled options:NSKeyValueObservingOptionNew context:NULL];
    [prefs addObserver:[SPQueryController sharedQueryController] forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];

    // Register observers for when the logging preference changes
    [prefs addObserver:[SPQueryController sharedQueryController] forKeyPath:SPConsoleEnableLogging options:NSKeyValueObservingOptionNew context:NULL];

    // Register a second observer for when the logging preference changes so we can tell the current connection about it
    [prefs addObserver:self forKeyPath:SPConsoleEnableLogging options:NSKeyValueObservingOptionNew context:NULL];
}

/**
 * Remove any previously added preference observers.
 */
- (void)_removePreferenceObservers
{
    [prefs removeObserver:self forKeyPath:SPConsoleEnableLogging];
    [prefs removeObserver:self forKeyPath:SPEditInSheetEnabled];
    [prefs removeObserver:self forKeyPath:SPDisplayTableViewVerticalGridlines];

    [prefs removeObserver:customQueryInstance forKeyPath:SPDisplayTableViewVerticalGridlines];
    [prefs removeObserver:tableRelationsInstance forKeyPath:SPDisplayTableViewVerticalGridlines];
    [prefs removeObserver:tableSourceInstance forKeyPath:SPDisplayTableViewVerticalGridlines];

    [prefs removeObserver:[SPQueryController sharedQueryController] forKeyPath:SPConsoleEnableLogging];
    [prefs removeObserver:[SPQueryController sharedQueryController] forKeyPath:SPDisplayTableViewVerticalGridlines];
}

#pragma mark -
#pragma mark -

- (void)dealloc {
    NSLog(@"Dealloc called %s", __FILE_NAME__);
}

@end


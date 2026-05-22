//
//  SPTableCopyTest.h
//  sequel-pro
//
//  Created by David Rekowski.
//  Copyright (c) 2010 David Rekowski. All rights reserved.
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

#import "SPTableCopy.h"
#import "SPPostgresConnection.h"
#import "SPPostgresResult.h"

#import <XCTest/XCTest.h>
#import <OCMock/OCMock.h>

#define USE_APPLICATION_UNIT_TEST 1

@interface SPTableCopyTest : XCTestCase

- (void)testCopyTableFromToWithData;
- (void)testCopyTableFromTo_NoPermissions;

@end

@implementation SPTableCopyTest

- (void)testCopyTableFromToWithData
{
	id mockConnection = OCMClassMock([SPPostgresConnection class]);

	OCMExpect([mockConnection queryString:@"CREATE TABLE \"target_db\".\"table_name\" (LIKE \"source_db\".\"table_name\" INCLUDING ALL)"]);
	OCMExpect([mockConnection queryString:@"INSERT INTO \"target_db\".\"table_name\" SELECT * FROM \"source_db\".\"table_name\""]);
	OCMStub([mockConnection queryErrored]).andReturn(NO);

	{
		SPTableCopy *tableCopy = [[SPTableCopy alloc] init];
		[tableCopy setConnection:mockConnection];
		[tableCopy copyTable:@"table_name" from:@"source_db" to:@"target_db" withContent:YES];
	}

	OCMVerifyAll(mockConnection);
}

- (void)testCopyTableFromTo_NoPermissions
{
	id mockConnection = OCMStrictClassMock([SPPostgresConnection class]);

	OCMExpect([mockConnection queryString:@"CREATE TABLE \"target_db\".\"table_name\" (LIKE \"source_db\".\"table_name\" INCLUDING ALL)"]);
	OCMStub([mockConnection queryErrored]).andReturn(YES);
	OCMStub([mockConnection lastErrorMessage]).andReturn(@"permission denied for table table_name");
	OCMStub([mockConnection lastErrorID]).andReturn(42501);
	OCMStub([mockConnection lastSqlstate]).andReturn(@"42501");

	{
		SPTableCopy *tableCopy = [[SPTableCopy alloc] init];
		[tableCopy setConnection:mockConnection];

		XCTAssertFalse([tableCopy copyTable:@"table_name" from:@"source_db" to:@"target_db"], @"copy operation must fail.");
	}

	[mockConnection verify];
}

@end

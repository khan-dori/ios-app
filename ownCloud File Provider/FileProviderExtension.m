//
//  FileProviderExtension.m
//  ownCloud File Provider
//
//  Created by Felix Schwarz on 07.06.18.
//  Copyright © 2018 ownCloud GmbH. All rights reserved.
//

/*
 * Copyright (C) 2018, ownCloud GmbH.
 *
 * This code is covered by the GNU Public License Version 3.
 *
 * For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 * You should have received a copy of this license along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 *
 */

#import <ownCloudSDK/ownCloudSDK.h>

#import "FileProviderExtension.h"
#import "FileProviderEnumerator.h"
#import "OCItem+FileProviderItem.h"
#import "FileProviderExtensionThumbnailRequest.h"

@interface FileProviderExtension ()

@property (nonatomic, readonly, strong) NSFileManager *fileManager;

@end

@implementation FileProviderExtension

@synthesize core;
@synthesize bookmark;

- (instancetype)init
{
	NSDictionary *bundleInfoDict = [[NSBundle bundleForClass:[FileProviderExtension class]] infoDictionary];

	OCLogger.logLevel = OCLogLevelDebug;

	OCAppIdentity.sharedAppIdentity.appIdentifierPrefix = bundleInfoDict[@"OCAppIdentifierPrefix"];
	OCAppIdentity.sharedAppIdentity.keychainAccessGroupIdentifier = bundleInfoDict[@"OCKeychainAccessGroupIdentifier"];
	OCAppIdentity.sharedAppIdentity.appGroupIdentifier = bundleInfoDict[@"OCAppGroupIdentifier"];

	if (self = [super init]) {
		_fileManager = [[NSFileManager alloc] init];
	}

	[OCCoreManager sharedCoreManager].postFileProviderNotifications = YES;

	return self;
}

- (void)dealloc
{
	if (_core != nil)
	{
		[[OCCoreManager sharedCoreManager] returnCoreForBookmark:self.bookmark completionHandler:nil];
	}
}

#pragma mark - ItemIdentifier & URL lookup
- (NSFileProviderItem)itemForIdentifier:(NSFileProviderItemIdentifier)identifier error:(NSError *__autoreleasing  _Nullable *)outError
{
	__block NSFileProviderItem item = nil;
	dispatch_group_t waitForDatabaseGroup = dispatch_group_create();

	dispatch_group_enter(waitForDatabaseGroup);

	// Resolve the given identifier to a record in the model
	if ([identifier isEqual:NSFileProviderRootContainerItemIdentifier])
	{
		// Root item
		[self.core.vault.database retrieveCacheItemsAtPath:@"/" itemOnly:YES completionHandler:^(OCDatabase *db, NSError *error, OCSyncAnchor syncAnchor, NSArray<OCItem *> *items) {
			item = items.firstObject;

			if (outError != NULL)
			{
				*outError = error;
			}

			dispatch_group_leave(waitForDatabaseGroup);
		}];
	}
	else
	{
		// Other item
		[self.core retrieveItemFromDatabaseForFileID:(OCFileID)identifier completionHandler:^(NSError *error, OCSyncAnchor syncAnchor, OCItem *itemFromDatabase) {
			item = itemFromDatabase;

			if (outError != NULL)
			{
				*outError = error;
			}

			dispatch_group_leave(waitForDatabaseGroup);
		}];
	}

	dispatch_group_wait(waitForDatabaseGroup, DISPATCH_TIME_FOREVER);

	NSLog(@"-itemForIdentifier:error: %@ => %@", identifier, item);

	return item;
}

- (NSURL *)URLForItemWithPersistentIdentifier:(NSFileProviderItemIdentifier)identifier
{
	OCItem *item;
	NSURL *url = nil;

	if ((item = (OCItem *)[self itemForIdentifier:identifier error:NULL]) != nil)
	{
		url = [self.core localURLForItem:item];
	}

	NSLog(@"-URLForItemWithPersistentIdentifier: %@ => %@", identifier, url);

	return (url);

	/*
	// resolve the given identifier to a file on disk

	// in this implementation, all paths are structured as <base storage directory>/<item identifier>/<item file name>
	NSFileProviderManager *manager = [NSFileProviderManager defaultManager];
	NSURL *perItemDirectory = [manager.documentStorageURL URLByAppendingPathComponent:identifier isDirectory:YES];

	return [perItemDirectory URLByAppendingPathComponent:item.filename isDirectory:NO];
	*/
}

- (NSFileProviderItemIdentifier)persistentIdentifierForItemAtURL:(NSURL *)url
{
	// resolve the given URL to a persistent identifier using a database
	NSArray <NSString *> *pathComponents = [url pathComponents];

	// exploit the fact that the path structure has been defined as
	// <base storage directory>/<item identifier>/<item file name> above
	NSParameterAssert(pathComponents.count > 2);

	NSLog(@"-persistentIdentifierForItemAtURL: %@", (pathComponents[pathComponents.count - 2]));

	return pathComponents[pathComponents.count - 2];
}

- (void)providePlaceholderAtURL:(NSURL *)url completionHandler:(void (^)(NSError * _Nullable))completionHandler
{
	NSFileProviderItemIdentifier identifier = [self persistentIdentifierForItemAtURL:url];
	if (!identifier) {
		completionHandler([NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorNoSuchItem userInfo:nil]);
		return;
	}

	NSError *error = nil;
	NSFileProviderItem fileProviderItem = [self itemForIdentifier:identifier error:&error];
	if (!fileProviderItem) {
		completionHandler(error);
		return;
	}
	NSURL *placeholderURL = [NSFileProviderManager placeholderURLForURL:url];

	[[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];

	if (![NSFileProviderManager writePlaceholderAtURL:placeholderURL withMetadata:fileProviderItem error:&error]) {
		completionHandler(error);
		return;
	}
	completionHandler(nil);
}

- (void)startProvidingItemAtURL:(NSURL *)provideAtURL completionHandler:(void (^)(NSError * _Nullable))completionHandler
{
	NSError *error = nil;
	NSFileProviderItemIdentifier itemIdentifier = nil;
	NSFileProviderItem item = nil;

	if ((itemIdentifier = [self persistentIdentifierForItemAtURL:provideAtURL]) != nil)
	{
		 if ((item = [self itemForIdentifier:itemIdentifier error:&error]) != nil)
		 {
			[self.core downloadItem:(OCItem *)item options:nil resultHandler:^(NSError *error, OCCore *core, OCItem *item, OCFile *file) {
				NSError *provideError = error;

				if (provideError == nil)
				{
					[[NSFileManager defaultManager] createDirectoryAtURL:provideAtURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
					if ([[NSFileManager defaultManager] fileExistsAtPath:provideAtURL.path])
					{
						[[NSFileManager defaultManager] removeItemAtURL:provideAtURL error:&provideError];
					}
					[[NSFileManager defaultManager] moveItemAtURL:file.url toURL:provideAtURL error:&provideError];
				}

				NSLog(@"Starting to provide file:\nPAU: %@\nURL: %@\nErr: %@", provideAtURL, [self URLForItemWithPersistentIdentifier:item.itemIdentifier], provideError);

				completionHandler(provideError);
			}];

			return;
		 }
	}

	// Should ensure that the actual file is in the position returned by URLForItemWithIdentifier:, then call the completion handler

	/* TODO:
	 This is one of the main entry points of the file provider. We need to check whether the file already exists on disk,
	 whether we know of a more recent version of the file, and implement a policy for these cases. Pseudocode:

	 if (!fileOnDisk) {
	 downloadRemoteFile();
	 callCompletion(downloadErrorOrNil);
	 } else if (fileIsCurrent) {
	 callCompletion(nil);
	 } else {
	 if (localFileHasChanges) {
	 // in this case, a version of the file is on disk, but we know of a more recent version
	 // we need to implement a strategy to resolve this conflict
	 moveLocalFileAside();
	 scheduleUploadOfLocalFile();
	 downloadRemoteFile();
	 callCompletion(downloadErrorOrNil);
	 } else {
	 downloadRemoteFile();
	 callCompletion(downloadErrorOrNil);
	 }
	 }
	 */

	completionHandler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:@{}]);
}


- (void)itemChangedAtURL:(NSURL *)url
{
	// Called at some point after the file has changed; the provider may then trigger an upload

	/* TODO:
	 - mark file at <url> as needing an update in the model
	 - if there are existing NSURLSessionTasks uploading this file, cancel them
	 - create a fresh background NSURLSessionTask and schedule it to upload the current modifications
	 - register the NSURLSessionTask with NSFileProviderManager to provide progress updates
	 */
}

- (void)stopProvidingItemAtURL:(NSURL *)url
{
	// Called after the last claim to the file has been released. At this point, it is safe for the file provider to remove the content file.

	// TODO: look up whether the file has local changes
	BOOL fileHasLocalChanges = NO;

	if (!fileHasLocalChanges) {
		// remove the existing file to free up space
		[[NSFileManager defaultManager] removeItemAtURL:url error:NULL];

		// write out a placeholder to facilitate future property lookups
		[self providePlaceholderAtURL:url completionHandler:^(NSError * __nullable error) {
			// TODO: handle any error, do any necessary cleanup
		}];
	}
}

#pragma mark - Actions

/* TODO: implement the actions for items here
 each of the actions follows the same pattern:
 - make a note of the change in the local model
 - schedule a server request as a background task to inform the server of the change
 - call the completion block with the modified item in its post-modification state
 */

- (void)createDirectoryWithName:(NSString *)directoryName inParentItemIdentifier:(NSFileProviderItemIdentifier)parentItemIdentifier completionHandler:(void (^)(NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler
{
	NSError *error = nil;
	OCItem *parentItem;

	if ((parentItem = (OCItem *)[self itemForIdentifier:parentItemIdentifier error:&error]) != nil)
	{
		[self.core createFolder:directoryName inside:parentItem options:nil resultHandler:^(NSError *error, OCCore *core, OCItem *item, id parameter) {
			completionHandler(item, error);
		}];
	}
	else
	{
		completionHandler(nil, error);
	}
}

- (void)reparentItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier toParentItemWithIdentifier:(NSFileProviderItemIdentifier)parentItemIdentifier newName:(NSString *)newName completionHandler:(void (^)(NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler
{
	NSError *error = nil;
	OCItem *item, *parentItem;

	if (((item = (OCItem *)[self itemForIdentifier:itemIdentifier error:&error]) != nil) &&
	    ((parentItem = (OCItem *)[self itemForIdentifier:parentItemIdentifier error:&error]) != nil))
	{
		[self.core moveItem:item to:parentItem withName:((newName != nil) ? newName : item.name) options:nil resultHandler:^(NSError *error, OCCore *core, OCItem *item, id parameter) {
			completionHandler(item, error);
		}];
	}
	else
	{
		completionHandler(nil, error);
	}
}

- (void)renameItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier toName:(NSString *)itemName completionHandler:(void (^)(NSFileProviderItem renamedItem, NSError *error))completionHandler
{
	NSError *error = nil;
	OCItem *item, *parentItem;

	if (((item = (OCItem *)[self itemForIdentifier:itemIdentifier error:&error]) != nil) &&
	    ((parentItem = (OCItem *)[self itemForIdentifier:item.parentFileID error:&error]) != nil))
	{
		[self.core moveItem:item to:parentItem withName:itemName options:nil resultHandler:^(NSError *error, OCCore *core, OCItem *item, id parameter) {
			completionHandler(item, error);
		}];
	}
	else
	{
		completionHandler(nil, error);
	}
}

- (void)trashItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier completionHandler:(void (^)(NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler
{
	NSError *error = nil;
	OCItem *item;

	if ((item = (OCItem *)[self itemForIdentifier:itemIdentifier error:&error]) != nil)
	{
		[self.core deleteItem:item requireMatch:YES resultHandler:^(NSError *error, OCCore *core, OCItem *item, id parameter) {
			completionHandler(nil, error);
		}];
	}
	else
	{
		completionHandler(nil, error);
	}
}

- (void)deleteItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier completionHandler:(void (^)(NSError * _Nullable))completionHandler
{
	NSError *error = nil;
	OCItem *item;

	if ((item = (OCItem *)[self itemForIdentifier:itemIdentifier error:&error]) != nil)
	{
		[self.core deleteItem:item requireMatch:YES resultHandler:^(NSError *error, OCCore *core, OCItem *item, id parameter) {
			completionHandler(error);
		}];
	}
	else
	{
		completionHandler(error);
	}
}

#pragma mark - Enumeration

- (nullable id<NSFileProviderEnumerator>)enumeratorForContainerItemIdentifier:(NSFileProviderItemIdentifier)containerItemIdentifier error:(NSError **)error
{
	if (![containerItemIdentifier isEqualToString:NSFileProviderWorkingSetContainerItemIdentifier])
	{
		FileProviderEnumerator *enumerator = [[FileProviderEnumerator alloc] initWithBookmark:self.bookmark enumeratedItemIdentifier:containerItemIdentifier];

		enumerator.fileProviderExtension = self;

		return (enumerator);
	}

	return (nil);

	/*
	FileProviderEnumerator *enumerator = nil;

	if ([containerItemIdentifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) {
		// TODO: instantiate an enumerator for the container root
	} else if ([containerItemIdentifier isEqualToString:NSFileProviderWorkingSetContainerItemIdentifier]) {
		// TODO: instantiate an enumerator for the working set
	} else {
		// TODO: determine if the item is a directory or a file
		// - for a directory, instantiate an enumerator of its subitems
		// - for a file, instantiate an enumerator that observes changes to the file
	}

	return enumerator;
	*/
}

#pragma mark - Thumbnails
- (NSProgress *)fetchThumbnailsForItemIdentifiers:(NSArray<NSFileProviderItemIdentifier> *)itemIdentifiers requestedSize:(CGSize)size perThumbnailCompletionHandler:(void (^)(NSFileProviderItemIdentifier _Nonnull, NSData * _Nullable, NSError * _Nullable))perThumbnailCompletionHandler completionHandler:(void (^)(NSError * _Nullable))completionHandler
{
	FileProviderExtensionThumbnailRequest *thumbnailRequest;

	if ((thumbnailRequest = [FileProviderExtensionThumbnailRequest new]) != nil)
	{
		if (size.width > 256)
		{
			size.width = 256;
		}

		if (size.height > 256)
		{
			size.height = 256;
		}

		thumbnailRequest.extension = self;
		thumbnailRequest.itemIdentifiers = itemIdentifiers;
		thumbnailRequest.sizeInPixels = size;
		thumbnailRequest.perThumbnailCompletionHandler = perThumbnailCompletionHandler;
		thumbnailRequest.completionHandler = completionHandler;
		thumbnailRequest.progress = [NSProgress progressWithTotalUnitCount:itemIdentifiers.count];

		[thumbnailRequest requestNextThumbnail];
	}

	return (thumbnailRequest.progress);
}

#pragma mark - Core
- (OCBookmark *)bookmark
{
	@synchronized(self)
	{
		if (_bookmark == nil)
		{
			NSFileProviderDomainIdentifier domainIdentifier;

			if ((domainIdentifier = self.domain.identifier) != nil)
			{
				_bookmark = [[OCBookmarkManager sharedBookmarkManager] bookmarkForUUID:[[NSUUID alloc] initWithUUIDString:domainIdentifier]];

				if (_bookmark == nil)
				{
					OCLogError(@"Error retrieving bookmark for domain %@ (UUID %@)", OCLogPrivate(self.domain.displayName), OCLogPrivate(self.domain.identifier));
				}
			}
		}
	}

	return (_bookmark);
}

- (OCCore *)core
{
	@synchronized(self)
	{
		if (_core == nil)
		{
			if (self.bookmark != nil)
			{
				dispatch_group_t waitForCoreGroup = dispatch_group_create();

				dispatch_group_enter(waitForCoreGroup);

				_core = [[OCCoreManager sharedCoreManager] requestCoreForBookmark:self.bookmark completionHandler:^(OCCore *core, NSError *error) {
					dispatch_group_leave(waitForCoreGroup);
				}];

				_core.delegate = self;

				dispatch_group_wait(waitForCoreGroup, DISPATCH_TIME_FOREVER);
			}
		}

		if (_core == nil)
		{
			OCLogError(@"Error getting core for domain %@ (UUID %@)", OCLogPrivate(self.domain.displayName), OCLogPrivate(self.domain.identifier));
		}
	}

	return (_core);
}

- (void)core:(OCCore *)core handleError:(NSError *)error issue:(OCConnectionIssue *)issue
{
	NSLog(@"CORE ERROR: error=%@, issue=%@", error, issue);

	if (issue.type == OCConnectionIssueTypeMultipleChoice)
	{
		[issue cancel];
	}
}

@end


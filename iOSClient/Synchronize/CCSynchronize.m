//
//  CCSynchronize.m
//  Crypto Cloud Technology Nextcloud
//
//  Created by Marino Faggiana on 19/10/16.
//  Copyright (c) 2017 TWS. All rights reserved.
//
//  Author Marino Faggiana <m.faggiana@twsweb.it>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "CCSynchronize.h"
#import "AppDelegate.h"
#import "CCMain.h"
#import "NCBridgeSwift.h"

@interface CCSynchronize () 
{
    // local
}
@end

@implementation CCSynchronize

+ (CCSynchronize *)sharedSynchronize {
    
    static CCSynchronize *sharedSynchronize;
    
    @synchronized(self)
    {
        if (!sharedSynchronize) {
            
            sharedSynchronize = [CCSynchronize new];
            
            sharedSynchronize.foldersInSynchronized = [NSMutableOrderedSet new];
        }
        return sharedSynchronize;
    }
}

#pragma --------------------------------------------------------------------------------------------
#pragma mark ===== Read Folder =====
#pragma --------------------------------------------------------------------------------------------

// serverUrl    : start
// directoryID  : start
// selector     : selectorReadFolder, selectorReadFolderWithDownload
//

- (void)readFolder:(NSString *)serverUrl selector:(NSString *)selector
{
    CCMetadataNet *metadataNet = [[CCMetadataNet alloc] initWithAccount:app.activeAccount];
    
    metadataNet.action = actionReadFolder;
    NSString *directoryID = [[NCManageDatabase sharedInstance] getDirectoryID:serverUrl];
    if (!directoryID) return;
    
    metadataNet.depth = @"1";
    metadataNet.directoryID = directoryID;
    metadataNet.priority = NSOperationQueuePriorityLow;
    metadataNet.selector = selector;
    metadataNet.serverUrl = serverUrl;
    
    [app addNetworkingOperationQueue:app.netQueue delegate:self metadataNet:metadataNet];
    
    NSLog(@"[LOG] %@ directory : %@", selector, serverUrl);
}

- (void)readFolderFailure:(CCMetadataNet *)metadataNet message:(NSString *)message errorCode:(NSInteger)errorCode
{
    // verify active user
    tableAccount *recordAccount = [[NCManageDatabase sharedInstance] getAccountActive];
    
    // Folder not present, remove it
    if (errorCode == 404 && [recordAccount.account isEqualToString:metadataNet.account]) {
        
        [[NCManageDatabase sharedInstance] deleteDirectoryAndSubDirectoryWithServerUrl:metadataNet.serverUrl];
        [app.activeMain reloadDatasource:metadataNet.serverUrl];
    }
}

// MULTI THREAD
- (void)readFolderSuccess:(CCMetadataNet *)metadataNet metadataFolder:(tableMetadata *)metadataFolder metadatas:(NSArray *)metadatas
{
    // Add/update self Folder
    if (!metadataFolder || !metadatas || [metadatas count] == 0)
        return;
    
    // Add metadata and update etag Directory
    (void)[[NCManageDatabase sharedInstance] addMetadata:metadataFolder];
    [[NCManageDatabase sharedInstance] setDirectoryWithServerUrl:metadataNet.serverUrl serverUrlTo:nil etag:metadataFolder.etag];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        
        tableAccount *recordAccount = [[NCManageDatabase sharedInstance] getAccountActive];
    
        NSMutableArray *metadatasForVerifyChange = [NSMutableArray new];
        NSMutableArray *addMetadatas = [NSMutableArray new];
    
        if ([recordAccount.account isEqualToString:metadataNet.account] == NO)
            return;

        NSArray *recordsInSessions = [[NCManageDatabase sharedInstance] getMetadatasWithPredicate:[NSPredicate predicateWithFormat:@"account = %@ AND directoryID = %@ AND session != ''", app.activeAccount, metadataNet.directoryID] sorted:nil ascending:NO];
        
        // ----- Test : (DELETE) -----
        
        NSMutableArray *metadatasNotPresents = [NSMutableArray new];
        
        NSArray *tableMetadatas = [[NCManageDatabase sharedInstance] getMetadatasWithPredicate:[NSPredicate predicateWithFormat:@"account = %@ AND directoryID = %@ AND session = ''", app.activeAccount, metadataNet.directoryID] sorted:nil ascending:NO];
        
        for (tableMetadata *record in tableMetadatas) {
            
            // reject cryptated
            if (record.cryptated)
                continue;
            
            BOOL fileIDFound = NO;
            
            for (tableMetadata *metadata in metadatas) {
                
                if ([record.fileID isEqualToString:metadata.fileID]) {
                    fileIDFound = YES;
                    break;
                }
            }
            
            if (!fileIDFound)
                [metadatasNotPresents addObject:record];
        }
        
        // delete metadata not present
        for (tableMetadata *metadata in metadatasNotPresents) {
        
            [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/%@", app.directoryUser, metadata.fileID] error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/%@.ico", app.directoryUser, metadata.fileID] error:nil];
            
            if (metadata.directory && metadataNet.serverUrl) {
                
                NSString *dirForDelete = [CCUtility stringAppendServerUrl:metadataNet.serverUrl addFileName:metadata.fileNameData];
                
                [[NCManageDatabase sharedInstance] deleteDirectoryAndSubDirectoryWithServerUrl:dirForDelete];
            }
            
            [[NCManageDatabase sharedInstance] deleteMetadataWithPredicate:[NSPredicate predicateWithFormat:@"fileID = %@", metadata.fileID] clearDateReadDirectoryID:nil];
            [[NCManageDatabase sharedInstance] deleteLocalFileWithPredicate:[NSPredicate predicateWithFormat:@"fileID = %@", metadata.fileID]];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([metadatasNotPresents count] > 0)
                [app.activeMain reloadDatasource:metadataNet.serverUrl];
        });
        
        // ----- Test : (MODIFY) -----
        
        for (tableMetadata *metadata in metadatas) {
            
            // reject cryptated
            if (metadata.cryptated)
                continue;
            
            // RECURSIVE DIRECTORY MODE
            if (metadata.directory) {
                
                    NSString *serverUrl = [CCUtility stringAppendServerUrl:metadataNet.serverUrl addFileName:metadata.fileNameData];
                    NSString *etag = metadata.etag;
                
                    // Verify if do not exists this Metadata
                    tableMetadata *result = [[NCManageDatabase sharedInstance] getMetadataWithPredicate:[NSPredicate predicateWithFormat:@"fileID = %@", metadata.fileID]];

                    if (!result)
                        (void)[[NCManageDatabase sharedInstance] addMetadata:metadata];
              
                    // Load if different etag
                    tableDirectory *tableDirectory = [[NCManageDatabase sharedInstance] getTableDirectoryWithPredicate:[NSPredicate predicateWithFormat:@"account = %@ AND serverUrl = %@", metadataNet.account, serverUrl]];
                
                if (![tableDirectory.etag isEqualToString:etag] || [metadataNet.selector isEqualToString:selectorReadFolderWithDownload]) {
                                        
                        [self readFolder:serverUrl selector:metadataNet.selector];
                    }
                    
                } else {
                
                if ([metadataNet.selector isEqualToString:selectorReadFolderWithDownload]) {
                    
                    // It's in session
                    BOOL recordInSession = NO;
                    for (tableMetadata *record in recordsInSessions) {
                        if ([record.fileID isEqualToString:metadata.fileID]) {
                            recordInSession = YES;
                            break;
                        }
                    }
                    
                    if (recordInSession)
                        continue;
            
                    // Ohhhh INSERT
                    [metadatasForVerifyChange addObject:metadata];
                }
                
                if ([metadataNet.selector isEqualToString:selectorReadFolder]) {
                    
                    // Verify if do not exists this Metadata
                    tableMetadata *result = [[NCManageDatabase sharedInstance] getMetadataWithPredicate:[NSPredicate predicateWithFormat:@"fileID = %@", metadata.fileID]];

                    if (!result)
                        [addMetadatas addObject:metadata];
                }
            }
        }
        
        if ([addMetadatas count] > 0)
            (void)[[NCManageDatabase sharedInstance] addMetadatas:addMetadatas serverUrl:metadataNet.serverUrl];
        
        if ([metadatasForVerifyChange count] > 0)
            [self verifyChangeMedatas:metadatasForVerifyChange serverUrl:metadataNet.serverUrl account:metadataNet.account withDownload:YES];
    });
}

#pragma --------------------------------------------------------------------------------------------
#pragma mark ===== Read File for Folder & Read File=====
#pragma --------------------------------------------------------------------------------------------

- (void)readFileForFolder:(NSString *)fileName serverUrl:(NSString *)serverUrl selector:(NSString *)selector
{
    CCMetadataNet *metadataNet = [[CCMetadataNet alloc] initWithAccount:app.activeAccount];
    
    metadataNet.action = actionReadFile;
    metadataNet.fileName = fileName;
    metadataNet.priority = NSOperationQueuePriorityLow;
    metadataNet.selector = selector;
    metadataNet.serverUrl = serverUrl;
    
    [app addNetworkingOperationQueue:app.netQueue delegate:self metadataNet:metadataNet];
}

- (void)readFile:(tableMetadata *)metadata selector:(NSString *)selector
{
    NSString *serverUrl = [[NCManageDatabase sharedInstance] getServerUrl:metadata.directoryID];
    if (!serverUrl) return;
        
    CCMetadataNet *metadataNet = [[CCMetadataNet alloc] initWithAccount:app.activeAccount];
        
    metadataNet.action = actionReadFile;
    metadataNet.fileID = metadata.fileID;
    metadataNet.fileName = metadata.fileName;
    metadataNet.fileNamePrint = metadata.fileNamePrint;
    metadataNet.priority = NSOperationQueuePriorityLow;
    metadataNet.selector = selector;
    metadataNet.serverUrl = serverUrl;
    
    [app addNetworkingOperationQueue:app.netQueue delegate:self metadataNet:metadataNet];
}

- (void)readFileFailure:(CCMetadataNet *)metadataNet message:(NSString *)message errorCode:(NSInteger)errorCode
{
    // verify active user
    tableAccount *recordAccount = [[NCManageDatabase sharedInstance] getAccountActive];
    
    // Selector : selectorReadFile, selectorReadFileWithDownload
    if ([metadataNet.selector isEqualToString:selectorReadFile] || [metadataNet.selector isEqualToString:selectorReadFileWithDownload]) {
        
        // File not present, remove it
        if (errorCode == 404 && [recordAccount.account isEqualToString:metadataNet.account]) {
        
            [[NCManageDatabase sharedInstance] deleteLocalFileWithPredicate:[NSPredicate predicateWithFormat:@"fileID = %@", metadataNet.fileID]];
            [[NCManageDatabase sharedInstance] deleteMetadataWithPredicate:[NSPredicate predicateWithFormat:@"fileID = %@", metadataNet.account, metadataNet.fileID] clearDateReadDirectoryID:nil];
        
            NSString *serverUrl = [[NCManageDatabase sharedInstance] getServerUrl:metadataNet.directoryID];
            if (serverUrl)
                [app.activeMain reloadDatasource:serverUrl];
        }
    }
}

- (void)readFileSuccess:(CCMetadataNet *)metadataNet metadata:(tableMetadata *)metadata
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        
        // Selector : selectorReadFile, selectorReadFileWithDownload
        if ([metadataNet.selector isEqualToString:selectorReadFile] || [metadataNet.selector isEqualToString:selectorReadFileWithDownload]) {
        
            BOOL withDownload = NO;
        
            if ([metadataNet.selector isEqualToString:selectorReadFileWithDownload])
                withDownload = YES;
        
            //Add/Update Metadata
            tableMetadata *addMetadata = [[NCManageDatabase sharedInstance] addMetadata:metadata];
            
            if (addMetadata)
                [self verifyChangeMedatas:[[NSArray alloc] initWithObjects:addMetadata, nil] serverUrl:metadataNet.serverUrl account:app.activeAccount withDownload:withDownload];
        }
        
        // Selector : selectorReadFileReloadFolder, selectorReadFileFolderWithDownload
        if ([metadataNet.selector isEqualToString:selectorReadFileFolder] || [metadataNet.selector isEqualToString:selectorReadFileFolderWithDownload]) {
            
            NSString *serverUrl = [CCUtility stringAppendServerUrl:metadataNet.serverUrl addFileName:metadataNet.fileName];
            
            // Add Directory
            (void) [[NCManageDatabase sharedInstance] addDirectoryWithServerUrl:metadataNet.account permissions:nil];
            tableDirectory *tableDirectory = [[NCManageDatabase sharedInstance] getTableDirectoryWithPredicate:[NSPredicate predicateWithFormat:@"account = %@ AND serverUrl = %@", metadataNet.account, serverUrl]];
            
            // Verify changed etag
            if (![tableDirectory.etag isEqualToString:metadata.etag]) {
                
                if ([metadataNet.selector isEqualToString:selectorReadFileFolder])
                    [self readFolder:serverUrl selector:selectorReadFolder];
                if ([metadataNet.selector isEqualToString:selectorReadFileFolderWithDownload])
                    [self readFolder:serverUrl selector:selectorReadFolderWithDownload];
            }
        }
    });
}

#pragma --------------------------------------------------------------------------------------------
#pragma mark ===== Verify Metadatas =====
#pragma --------------------------------------------------------------------------------------------

// MULTI THREAD
- (void)verifyChangeMedatas:(NSArray *)allRecordMetadatas serverUrl:(NSString *)serverUrl account:(NSString *)account withDownload:(BOOL)withDownload
{
    NSMutableArray *metadatas = [[NSMutableArray alloc] init];
    
    for (tableMetadata *metadata in allRecordMetadatas) {
        
        BOOL changeRev = NO;
        
        // change account
        if ([metadata.account isEqualToString:account] == NO)
            return;
        
        // no dir
        if (metadata.directory)
            continue;
        
        tableLocalFile *localFile = [[NCManageDatabase sharedInstance] getTableLocalFileWithPredicate:[NSPredicate predicateWithFormat:@"fileID = %@", metadata.fileID]];
        
        if (withDownload) {
            
            if (![localFile.etag isEqualToString:metadata.etag])
                changeRev = YES;
            
        } else {
            
            if (localFile && ![localFile.etag isEqualToString:metadata.etag]) // it must be in TableRecord
                changeRev = YES;
        }
        
        if (changeRev) {
            
            if ([metadata.type isEqualToString: k_metadataType_file]) {
                
                // remove file and ico
                [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/%@", app.directoryUser, metadata.fileID] error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/%@.ico", app.directoryUser, metadata.fileID] error:nil];
            }
            
            if ([metadata.type isEqualToString: k_metadataType_template]) {
                
                // remove model
                [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/%@", app.directoryUser, metadata.fileName] error:nil];
            }
            
            [metadatas addObject:metadata];
        }
    }
    
    if ([metadatas count])
        [self SynchronizeMetadatas:metadatas withDownload:withDownload];
}

// MULTI THREAD
- (void)SynchronizeMetadatas:(NSArray *)metadatas withDownload:(BOOL)withDownload
{
    NSString *oldDirectoryID, *serverUrl, *fileID;
    NSMutableArray *metadataToAdd = [NSMutableArray new];
    NSMutableArray *metadataNetToAdd = [NSMutableArray new];

    for (tableMetadata *metadata in metadatas) {
        
        NSString *selector, *selectorPost;
        BOOL downloadData = NO, downloadPlist = NO;
        CCMetadataNet *metadataNet = [CCMetadataNet new];
        
        if ([metadata.type isEqualToString: k_metadataType_file]) {
            downloadData = YES;
            selector = selectorDownloadSynchronize;
        }
        
        if ([metadata.type isEqualToString: k_metadataType_template]) {
            downloadPlist = YES;
            selector = selectorLoadPlist;
        }
            
        // Clear date for dorce refresh view
        if (![oldDirectoryID isEqualToString:metadata.directoryID]) {
            serverUrl = [[NCManageDatabase sharedInstance] getServerUrl:metadata.directoryID];
            oldDirectoryID = metadata.directoryID;
            if (!serverUrl)
                continue;
            [[NCManageDatabase sharedInstance] clearDateReadWithServerUrl:serverUrl directoryID:nil];
        }
        
        fileID = metadata.fileID;
        [metadataToAdd addObject:metadata];
       
        metadataNet.fileID = fileID;
        metadataNet.downloadData = downloadData;
        metadataNet.downloadPlist = downloadPlist;
        metadataNet.selector = selector;
        metadataNet.selectorPost = selectorPost;
        metadataNet.serverUrl = serverUrl;
        metadataNet.session = k_download_session;
        [metadataNetToAdd addObject:metadataNet];
    }
    
    (void)[[NCManageDatabase sharedInstance] addMetadatas:metadataToAdd serverUrl:nil];
    [[NCManageDatabase sharedInstance] addQueueDownloadWithMetadatasNet:metadataNetToAdd];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [app.activeMain reloadDatasource:serverUrl];
    });
}

@end

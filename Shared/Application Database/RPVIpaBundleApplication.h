//
//  RPVIpaBundleApplication.h
//  iOS
//
//  Created by Matt Clarke on 21/07/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVApplication.h"
#import "SSZipArchive.h"

@interface RPVIpaBundleApplication : RPVApplication <SSZipArchiveDelegate>
@property (nonatomic, strong) NSURL *cachedURL;
- (instancetype)initWithIpaURL:(NSURL*)url;

// Optional fallback for reading a picked .ipa this (no-container) app can't read itself.
// The iOS app registers a handler at launch that asks the root daemon to copy srcPath ->
// dstPath; the handler returns YES on success. When unset (e.g. tvOS/macOS) the import
// simply skips this fallback.
+ (void)setDaemonFileCopyHandler:(BOOL (^)(NSString *srcPath, NSString *dstPath))handler;
- (NSData *)_loadFileWithFormat:(NSString *)fileFormat fromIPA:(NSURL *)url multipleCandiateChooser:(NSString * (^)(NSArray *candidates))candidateChooser;
@end

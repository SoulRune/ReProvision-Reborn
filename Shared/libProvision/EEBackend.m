//
//  EEBackend.m
//  OpenExtenderTest
//
//  Created by Matt Clarke on 02/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "EEBackend.h"
#import "EEAppleServices.h"
#import "EEProvisioning.h"
#import "EESigning.h"
#import "SSZipArchive.h"

/* Private headers */
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)arg1 withOptions:(NSDictionary *)arg2 error:(NSError **)arg3;
- (NSArray *)allApplications;
- (BOOL)uninstallApplication:(id)arg1 withOptions:(id)arg2;
@end

@implementation EEBackend

// Returns the bundle's ORIGINAL identifier
static NSString *RPVOriginalBundleIDFromInfoPlist(NSDictionary *infoplist) {
    NSString *alt = [infoplist objectForKey:@"ALTBundleIdentifier"];
    if (alt.length) return alt;
    NSString *re = [infoplist objectForKey:@"REBundleIdentifier"];
    if (re.length) return re;
    return [infoplist objectForKey:@"CFBundleIdentifier"];
}

// Compute the re-signed bundle identifier.
// For a TOP-LEVEL app this is simply "<original>.<teamId>".
// For a NESTED bundle (an .appex in PlugIns, a watch app in Watch) it must NOT be
// "<originalChild>.<teamId>", because installd enforces that an app extension's
// identifier is prefixed by its host app's identifier
static NSString *RPVComputeNewBundleID(NSString *originalId, NSString *parentOriginalId, NSString *parentNewId, NSString *teamId) {
    if (!originalId.length) return originalId;

    if (parentOriginalId.length && parentNewId.length) {
        NSString *prefix = [parentOriginalId stringByAppendingString:@"."];
        if ([originalId hasPrefix:prefix]) {
            NSString *suffix = [originalId substringFromIndex:prefix.length];
            return [NSString stringWithFormat:@"%@.%@", parentNewId, suffix];
        }
    }

    return [originalId stringByAppendingFormat:@".%@", teamId];
}

+ (void)provisionDevice:(NSString *)udid name:(NSString *)name identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler {
    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];
    [provisioner provisionDevice:udid name:name withTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error) {
        completionHandler(error);
    }];
}

+ (void)revokeDevelopmentCertificatesForCurrentMachineWithIdentity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler {
    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];
    [provisioner revokeCertificatesWithTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error) {
        completionHandler(error);
    }];
}

+ (void)signBundleAtPath:(NSString *)path identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId withCompletionHandler:(void (^)(NSError *error))completionHandler {
    // Public entrypoint — this is a top-level bundle, so it has no parent.
    [self signBundleAtPath:path
                  identity:identity
                   gsToken:gsToken
         priorChosenTeamID:teamId
    parentOriginalBundleID:nil
         parentNewBundleID:nil
     withCompletionHandler:completionHandler];
}

+ (void)signBundleAtPath:(NSString *)path identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId parentOriginalBundleID:(NSString *)parentOriginalBundleID parentNewBundleID:(NSString *)parentNewBundleID withCompletionHandler:(void (^)(NSError *error))completionHandler {
    // We need to handle application extensions, e.g. watchOS applications and VPN plugins etc.
    // These are stored in the bundle's root directory at the following locations:
    // - /Plugins
    // - /Watch
    // Therefore, recurse through those directories as required before continuing for the root directory.

    // Work out THIS bundle's original and new identifiers up front, so we can pass them
    // to nested bundles before they're signed. installd requires an app extension's
    // identifier to be prefixed by its host app's identifier, so children must be renamed
    // relative to our new id — not independently given a ".<teamId>" suffix.
    NSString *myOriginalBundleID = nil;
    NSString *myNewBundleID = nil;
    {
        NSDictionary *earlyInfoPlist = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Info.plist", path]];
        myOriginalBundleID = RPVOriginalBundleIDFromInfoPlist(earlyInfoPlist);
        myNewBundleID = RPVComputeNewBundleID(myOriginalBundleID, parentOriginalBundleID, parentNewBundleID, teamId);
    }

    dispatch_group_t dispatch_group = dispatch_group_create();
    NSMutableArray *__block subBundleErrors = [NSMutableArray array];

    if ([[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/PlugIns", path]]) {
        // Recurse through the plugins.

        for (NSString *subBundle in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithFormat:@"%@/PlugIns", path] error:nil]) {
            NSString *__block subBundlePath = [NSString stringWithFormat:@"%@/PlugIns/%@", path, subBundle];

            // Enter the dispatch group
            dispatch_group_enter(dispatch_group);

            RPVLog(@"Handling sub-bundle: %@", subBundlePath);

            // Sign the bundle
            [self signBundleAtPath:subBundlePath identity:identity gsToken:gsToken priorChosenTeamID:teamId parentOriginalBundleID:myOriginalBundleID parentNewBundleID:myNewBundleID withCompletionHandler:^(NSError *error) {
                if (error)
                    [subBundleErrors addObject:error];

                RPVLog(@"Finished sub-bundle: %@", subBundlePath);
                dispatch_group_leave(dispatch_group);
            }];
        }
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/Watch", path]]) {
        // Recurse through the watchOS stuff.

        for (NSString *subBundle in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithFormat:@"%@/Watch", path] error:nil]) {
            NSString *__block subBundlePath = [NSString stringWithFormat:@"%@/Watch/%@", path, subBundle];

            // Enter the dispatch group
            dispatch_group_enter(dispatch_group);

            RPVLog(@"Handling sub-bundle: %@", subBundlePath);

            // Sign the bundle
            [self signBundleAtPath:subBundlePath identity:identity gsToken:gsToken priorChosenTeamID:teamId parentOriginalBundleID:myOriginalBundleID parentNewBundleID:myNewBundleID withCompletionHandler:^(NSError *error) {
                if (error)
                    [subBundleErrors addObject:error];

                RPVLog(@"Handled sub-bundle: %@", subBundlePath);
                dispatch_group_leave(dispatch_group);
            }];
        }
    }

    // Wait on sub-bundles to finish, if needed.
    dispatch_group_wait(dispatch_group, DISPATCH_TIME_FOREVER);

    if (subBundleErrors.count > 0) {
        // Errors when handling sub-bundles!
        for (NSError *err in subBundleErrors) {
            RPVLog(@"Error: %@", err.localizedDescription);
        }

        completionHandler([subBundleErrors lastObject]);
        return;
    }

    // 1. Read Info.plist to gain the applicationId and binaryLocation.
    // 2. Get provisioning profile and certificate info
    // 3. Sign bundle
    NSString *plistPath = [NSString stringWithFormat:@"%@/Info.plist", path];
    NSMutableDictionary *infoplist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];

    if (!infoplist || [infoplist allKeys].count == 0) {
        NSError *error = [self _errorFromString:@"Failed to open Info.plist!"];
        completionHandler(error);
        return;
    }

    // Find the systemType for this bundle.
    NSString *platformName = [infoplist objectForKey:@"DTPlatformName"];
    EESystemType systemType = -1;
    if ([platformName isEqualToString:@"iphoneos"]) {
        systemType = EESystemTypeiOS;
    } else if ([platformName isEqualToString:@"watchos"]) {
        systemType = EESystemTypewatchOS;
    } else if ([platformName isEqualToString:@"tvos"]) {
        systemType = EESystemTypetvOS;
    } else {
        // Base case, assume iOS.
        systemType = EESystemTypeiOS;
    }

    RPVLog(@"Platform: %@ for bundle: %@", platformName, [path lastPathComponent]);

    NSString *applicationId = [infoplist objectForKey:@"CFBundleIdentifier"];
    NSString *embeddedPath = [NSString stringWithFormat:@"%@/embedded.mobileprovision", path];
    BOOL isEmbeddedExists = [[NSFileManager defaultManager] fileExistsAtPath:embeddedPath];

    if (isEmbeddedExists) {
        BOOL isInstalledFromXcode = NO;
        BOOL isInstalledWithAnotherID = NO;

        NSString *profileString = [NSString stringWithContentsOfFile:embeddedPath encoding:NSISOLatin1StringEncoding error:nil];
        NSRange rangeOfTeamId = [profileString rangeOfString:teamId ?: @""];
        NSRange rangeOfXC = [profileString rangeOfString:@"XC "];
        if (rangeOfTeamId.location != NSNotFound && rangeOfXC.location != NSNotFound)
            isInstalledFromXcode = YES;
        else if (![applicationId hasSuffix:teamId]) {
            // application is installed with another apple id
            isInstalledWithAnotherID = YES;
        }

        if (isInstalledFromXcode || isInstalledWithAnotherID) {
            // This process should be done elsewhere and will be changed later
            // but i don't have enough time to understand the structure of this project.
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            [userInfo setObject:applicationId forKey:@"bundleIdentifier"];

            [[NSNotificationCenter defaultCenter] postNotificationName:@"jp.soh.reprovision/appShouldBeRemoved" object:nil userInfo:userInfo];
        }
    }

    if ([infoplist objectForKey:@"ALTBundleIdentifier"] != nil)
        applicationId = [infoplist objectForKey:@"ALTBundleIdentifier"];
    else if ([infoplist objectForKey:@"REBundleIdentifier"] != nil)
        applicationId = [infoplist objectForKey:@"REBundleIdentifier"];
    else
        [infoplist setObject:applicationId forKey:@"REBundleIdentifier"];

    applicationId = RPVComputeNewBundleID(applicationId, parentOriginalBundleID, parentNewBundleID, teamId);
    RPVLog(@"[ReProvision] Bundle ID: %@ -> %@ (parent: %@ -> %@)",
          [infoplist objectForKey:@"REBundleIdentifier"] ?: @"(none)", applicationId,
          parentOriginalBundleID ?: @"(top-level)", parentNewBundleID ?: @"(top-level)");
    [infoplist setObject:applicationId forKey:@"CFBundleIdentifier"];

    // A watchOS app points at its host via WKCompanionAppBundleIdentifier. Since the
    // host's identifier just changed, this has to follow it or the watch app is rejected.
    NSString *companion = [infoplist objectForKey:@"WKCompanionAppBundleIdentifier"];
    if (companion.length && parentNewBundleID.length) {
        [infoplist setObject:parentNewBundleID forKey:@"WKCompanionAppBundleIdentifier"];
        RPVLog(@"[ReProvision] WKCompanionAppBundleIdentifier: %@ -> %@", companion, parentNewBundleID);
    }

    NSError *error = nil;
    if (@available(iOS 11.0, *)) {
        [infoplist writeToURL:[NSURL fileURLWithPath:plistPath] error:&error];
    } else {
        // Fallback on earlier versions
        [infoplist writeToURL:[NSURL fileURLWithPath:plistPath] atomically:YES];
    }

    if (error) {
        RPVLog(@"%@", error);
        return;
    }

    NSString *applicationName = [infoplist objectForKey:@"CFBundleName"];
    NSString *binaryLocation = [path stringByAppendingFormat:@"/%@", [infoplist objectForKey:@"CFBundleExecutable"]];

    // We get entitlements from the binary using ldid::Analyze() during provisioning, updating them as needed
    // for the current Team ID.

    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];
    [provisioner downloadProvisioningProfileForApplicationIdentifier:applicationId applicationName:applicationName binaryLocation:(NSString *)binaryLocation withTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error, NSData *embeddedMobileProvision, NSString *privateKey, NSDictionary *certificate, NSDictionary *entitlements) {
        if (error) {
            completionHandler(error);
            return;
        }

        // We now have a valid provisioning profile for this application!
        // And, we also have a valid development codesigning certificate, with its private key!

        // Add embedded.mobileprovision to the bundle, overwriting if needed.
        NSError *fileIOError;

        if (isEmbeddedExists) {
            [[NSFileManager defaultManager] removeItemAtPath:embeddedPath error:&fileIOError];

            if (fileIOError) {
                RPVLog(@"%@", fileIOError);
                return;
            }
        }

        if (![(NSData *)embeddedMobileProvision writeToFile:embeddedPath options:NSDataWritingAtomic error:&fileIOError]) {
            if (fileIOError) {
                RPVLog(@"%@", fileIOError);
            } else {
                RPVLog(@"Failed to write '%@'.", embeddedPath);
            }

            return;
        }

        // Next step: signing. To do this, we use EESigner with these four results.
        NSData *certificateContent = [[NSData alloc] initWithBase64EncodedString:certificate[@"certificateContent"] options:0];
        EESigning *signer = [EESigning signerWithCertificate:certificateContent privateKey:privateKey];
        [signer signBundleAtPath:path entitlements:entitlements identifier:applicationId withCallback:^(BOOL success, NSString *result) {
            // Return to the caller on a new thread.
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // We will now pause so that ldid can cleanup after itself.
                [NSThread sleepForTimeInterval:1];

                NSError *error = nil;
                if (!success) {
                    error = [self _errorFromString:result];
                }

                // We're done.
                completionHandler(error);
            });
        }];
    }];
}

+ (void)signIpaAtPath:(NSString *)ipaPath outputPath:(NSString *)outputPath identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId withCompletionHandler:(void (^)(NSError *))completionHandler {
    // 1. Unpack IPA to a temporary directory.
    NSError *error;
    NSString *unpackedDirectory;
    if (![self unpackIpaAtPath:ipaPath outDirectory:&unpackedDirectory error:&error]) {
        completionHandler(error);
        return;
    }

    // 2. Sign its main bundle via above method.
    // The bundle will be located at <temporarydirectory>/<zipfilename>/Payload/*.app internally

    NSString *zipFilename = [ipaPath lastPathComponent];
    zipFilename = [zipFilename stringByReplacingOccurrencesOfString:@".ipa" withString:@""];

    NSString *payloadDirectory = [NSString stringWithFormat:@"%@/Payload", unpackedDirectory];

    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadDirectory error:&error];

    if (error) {
        completionHandler(error);
        return;
    } else if (files.count == 0) {
        NSError *err = [self _errorFromString:@"Payload directory of IPA has no contents"];
        completionHandler(err);
        return;
    }

    NSString *dotAppDirectory = @"";
    for (NSString *directory in files) {
        if ([directory containsString:@".app"]) {
            dotAppDirectory = directory;
            break;
        }
    }

    NSString *bundleDirectory = [NSString stringWithFormat:@"%@/%@", payloadDirectory, dotAppDirectory];

    // Session control lives in RPVApplicationSigning so that one session spans signing
    // AND installation - the install is where installd rejections surface, and those
    // were previously invisible in the file log.
    BOOL ownsSession = NO;
    NSDictionary *earlyInfo = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Info.plist", bundleDirectory]];
    if ([[RPVLogger logFilePath] isEqualToString:[RPVLogger logFilePathForBundle:nil]]) {
        [RPVLogger beginSessionForBundle:RPVOriginalBundleIDFromInfoPlist(earlyInfo)];
        ownsSession = YES;
    }

    [RPVLogger logStage:@"SIGNING"];
    RPVLog(@"Signing bundle at path '%@'", bundleDirectory);

    [self signBundleAtPath:bundleDirectory identity:identity gsToken:gsToken priorChosenTeamID:teamId withCompletionHandler:^(NSError *err) {
        if (err) {
            RPVLog(@"*** [ReProvision] signing failed: %@", err.localizedDescription);
            if (ownsSession) [RPVLogger endSessionSuccess:NO message:err.localizedDescription];
            completionHandler(err);
            return;
        }

        // 3. Repack IPA to output path
        RPVLog(@"Repacking IPA to '%@'", outputPath);
        NSError *error2;
        if (![self repackIpaAtPath:[NSString stringWithFormat:@"%@/%@", [self applicationTemporaryDirectory], zipFilename] toPath:outputPath error:&error2]) {
            RPVLog(@"*** [ReProvision] repack failed: %@", error2.localizedDescription);
            if (ownsSession) [RPVLogger endSessionSuccess:NO message:[NSString stringWithFormat:@"Repack failed: %@", error2.localizedDescription]];
            completionHandler(error2);
        } else {
            // Success!
            RPVLog(@"Repack complete");
            if (ownsSession) [RPVLogger endSessionSuccess:YES message:nil];
            completionHandler(nil);
        }
    }];
}

+ (BOOL)unpackIpaAtPath:(NSString *)ipaPath outDirectory:(NSString **)outputDirectory error:(NSError **)error {
    // Sanity checks.
    if (![ipaPath hasSuffix:@".ipa"]) {
        if (error)
            *error = [self _errorFromString:@"Input file specified is not an IPA!"];
        return NO;
    }

    if (!outputDirectory) {
        if (error)
            *error = [self _errorFromString:@"No outputDirectory; how will you know where the IPA was extracted to?"];
        return NO;
    }

    NSString *zipFilename = [ipaPath lastPathComponent];
    zipFilename = [zipFilename stringByReplacingOccurrencesOfString:@".ipa" withString:@""];

    *outputDirectory = [NSString stringWithFormat:@"%@/%@", [self applicationTemporaryDirectory], zipFilename];

    RPVLog(@"Unpacking '%@' into directory '%@'", ipaPath, *outputDirectory);

    if (![SSZipArchive unzipFileAtPath:ipaPath toDestination:*outputDirectory]) {
        if (error)
            *error = [self _errorFromString:@"Failed to unpack IPA!"];
        return NO;
    }

    return YES;
}

+ (BOOL)repackIpaAtPath:(NSString *)extractedPath toPath:(NSString *)outputPath error:(NSError **)error {
    // Sanity checks.
    if (![outputPath hasSuffix:@".ipa"]) {
        if (error)
            *error = [self _errorFromString:@"Output file specified is not an IPA!"];
        return NO;
    }

    RPVLog(@"Creating IPA from contents of '%@", extractedPath);

    // Ensure permissions are at least read on everyone.


    if (![SSZipArchive createZipFileAtPath:outputPath withContentsOfDirectory:extractedPath]) {
        if (error)
            *error = [self _errorFromString:@"Failed to repack IPA!"];
        return NO;
    }

    return YES;
}

+ (NSString *)applicationTemporaryDirectory {
    NSString *tempDir = NSTemporaryDirectory();
    if (!tempDir)
        tempDir = @"/tmp";

    if (![[NSFileManager defaultManager] fileExistsAtPath:tempDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:tempDir withIntermediateDirectories:NO attributes:nil error:nil];
    }

    return tempDir;
}

+ (NSError *)_errorFromString:(NSString *)string {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: NSLocalizedString(string, nil),
        NSLocalizedFailureReasonErrorKey: NSLocalizedString(string, nil),
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", nil)
    };

    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:-1
                                     userInfo:userInfo];

    return error;
}

@end

#pragma mark - RPVLogger

#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif
#import <sys/utsname.h>

static NSString * const kRPVLogEnabledKey = @"logSigningToFile";

// One log file per application, named after its ORIGINAL bundle identifier - the one
// the app shipped with, before ReProvision appends the Team ID. Using the original
// keeps the filename stable across re-signs and free of the random-looking team suffix.
static NSString * const kRPVLogDirectory = @"/var/mobile/Documents/ReProvision-logs";

static NSString * const kRPVGeneralLogName = @"_general";

// Per-file rotation. Lower than the old single-file limit because each app now has its
// own file; 512 KB is many dozens of sessions for one application.
static const unsigned long long kRPVLogMaxBytes = 512 * 1024;

static NSString *gRPVCurrentBundle = nil;
static NSLock *gRPVCurrentBundleLock = nil;

@implementation RPVLogger

+ (void)initialize {
    if (self == [RPVLogger class]) {
        gRPVCurrentBundleLock = [[NSLock alloc] init];
    }
}

#pragma mark Queue and current session

+ (dispatch_queue_t)_queue {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("jp.soh.reprovision.logger", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

+ (NSString *)_currentBundle {
    [gRPVCurrentBundleLock lock];
    NSString *b = [gRPVCurrentBundle copy];
    [gRPVCurrentBundleLock unlock];
    return b;
}

+ (void)_setCurrentBundle:(NSString *)bundle {
    [gRPVCurrentBundleLock lock];
    gRPVCurrentBundle = [bundle copy];
    [gRPVCurrentBundleLock unlock];
}

#pragma mark Paths

+ (NSString *)logDirectory {
    static NSString *resolved = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fm = [NSFileManager defaultManager];

        [fm createDirectoryAtPath:kRPVLogDirectory
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0777}
                            error:nil];

        // Probe rather than assume: if the daemon created the directory as root and the
        // app runs as mobile, every write would silently vanish.
        NSString *probe = [kRPVLogDirectory stringByAppendingPathComponent:@".write-probe"];
        if ([fm createFileAtPath:probe contents:[NSData data] attributes:nil]) {
            [fm removeItemAtPath:probe error:nil];
            resolved = kRPVLogDirectory;
        } else {
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            resolved = [[paths firstObject] stringByAppendingPathComponent:@"ReProvision-logs"];
            [fm createDirectoryAtPath:resolved withIntermediateDirectories:YES attributes:nil error:nil];
            NSLog(@"[RPVLogger] '%@' not writable, falling back to '%@'", kRPVLogDirectory, resolved);
        }
    });
    return resolved;
}

// Bundle identifiers are filesystem-safe in practice, but a malformed Info.plist
// shouldn't be able to write outside the log directory.
+ (NSString *)_sanitise:(NSString *)identifier {
    if (identifier.length == 0) return kRPVGeneralLogName;

    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:"];
    NSString *clean = [[identifier componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@"_"];

    clean = [clean stringByReplacingOccurrencesOfString:@".." withString:@"_"];
    while ([clean hasPrefix:@"."] && clean.length > 1) clean = [clean substringFromIndex:1];
    if (clean.length > 120) clean = [clean substringToIndex:120];

    return clean.length ? clean : kRPVGeneralLogName;
}

+ (NSString *)logFilePathForBundle:(NSString *)bundleIdentifier {
    NSString *name = [self _sanitise:bundleIdentifier];
    return [[self logDirectory] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"log"]];
}

+ (NSString *)logFilePath {
    return [self logFilePathForBundle:[self _currentBundle]];
}

+ (NSString *)previousLogFilePath {
    NSString *name = [self _sanitise:[self _currentBundle]];
    return [[self logDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.1.log", name]];
}

+ (NSArray<NSString *> *)logFiles {
    NSString *dir = [self logDirectory];
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *f in [all sortedArrayUsingSelector:@selector(compare:)]) {
        if ([[f pathExtension] isEqualToString:@"log"]) {
            [result addObject:[dir stringByAppendingPathComponent:f]];
        }
    }
    return result;
}

+ (unsigned long long)logFileSize {
    unsigned long long total = 0;
    for (NSString *p in [self logFiles]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (attrs) total += [attrs fileSize];
    }
    return total;
}

#pragma mark Enablement

+ (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kRPVLogEnabledKey];
}

+ (void)setEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kRPVLogEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (enabled) [self logRaw:@"=== File logging enabled ==="];
}

#pragma mark Redaction

+ (NSString *)_redact:(NSString *)message {
    if (message.length == 0) return message;

    static NSRegularExpression *pemRegex;
    static NSRegularExpression *plistKeyRegex;
    static NSRegularExpression *emailRegex;
    static NSRegularExpression *tokenRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pemRegex = [NSRegularExpression regularExpressionWithPattern:
                    @"-----BEGIN[^-]+-----[\\s\\S]*?-----END[^-]+-----" options:0 error:nil];
        plistKeyRegex = [NSRegularExpression regularExpressionWithPattern:
                         @"(?i)<key>(password|myacinfo|gsToken|gs-token|sessionToken|privateKey|identityToken|dsid)</key>\\s*<string>[^<]*</string>" options:0 error:nil];
        emailRegex = [NSRegularExpression regularExpressionWithPattern:
                      @"\\b[\\w._%+-]+@[\\w.-]+\\.[A-Za-z]{2,}\\b" options:0 error:nil];
        // Long opaque tokens. This previously ate path components too - the jailbreak
        // prefix under /private/preboot is a 96-char hex string, so paths came out as
        // '/[REDACTED TOKEN].app/apple-ios-g3.pem', useless when the point is debugging
        // paths. Now it only fires for a standalone run, not one bounded by '/' or '.'.
        tokenRegex = [NSRegularExpression regularExpressionWithPattern:
                      @"(?<![/.\\w])[A-Za-z0-9+/=_-]{40,}(?![/.\\w])" options:0 error:nil];
    });

    NSMutableString *out = [message mutableCopy];
    [pemRegex replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@"[REDACTED PEM BLOCK]"];
    [plistKeyRegex replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@"[REDACTED PLIST SECRET]"];
    [emailRegex replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@"[REDACTED EMAIL]"];
    [tokenRegex replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@"[REDACTED TOKEN]"];
    return out;
}

#pragma mark Writing

+ (void)_appendLine:(NSString *)line toPath:(NSString *)path {
    // Must be called on _queue.
    NSFileManager *fm = [NSFileManager defaultManager];

    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs && [attrs fileSize] >= kRPVLogMaxBytes) {
        NSString *prev = [NSString stringWithFormat:@"%@.1.log", [path stringByDeletingPathExtension]];
        [fm removeItemAtPath:prev error:nil];
        [fm moveItemAtPath:path toPath:prev error:nil];
    }

    if (![fm fileExistsAtPath:path]) {
        // 0666: the app runs as mobile and the reprovisiond daemon may run as root, and
        // both append to these files. Restrictive modes make whichever ran second fail
        // silently.
        [fm createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions: @0666}];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;

    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) {
        NSLog(@"[RPVLogger] write failed: %@", e.reason);
    } @finally {
        [handle closeFile];
    }
}

+ (NSString *)_timestamp {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter stringFromDate:[NSDate date]];
}

+ (void)_write:(NSString *)message synchronously:(BOOL)sync {
    if (![self isEnabled] || message.length == 0) return;

    NSString *path = [self logFilePath];
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [self _timestamp], [self _redact:message]];

    if (sync) {
        dispatch_sync([self _queue], ^{
            [self _appendLine:line toPath:path];
        });
    } else {
        dispatch_async([self _queue], ^{
            [self _appendLine:line toPath:path];
        });
    }
}

+ (void)logRaw:(NSString *)message {
    [self _write:message synchronously:NO];
}

+ (void)log:(NSString *)format, ... {
    if (![self isEnabled]) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    [self _write:message synchronously:NO];
}

#pragma mark Sessions

+ (void)beginSessionForBundle:(NSString *)bundleIdentifier {
    [self beginSessionForBundle:bundleIdentifier displayName:nil];
}

+ (void)beginSessionForBundle:(NSString *)bundleIdentifier displayName:(NSString *)displayName {
    [self _setCurrentBundle:bundleIdentifier];
    if (![self isEnabled]) return;

    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *model = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];

    NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *appBuild = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";

    NSString *osVersion;
#if __has_include(<UIKit/UIKit.h>)
    osVersion = [[UIDevice currentDevice] systemVersion];
#else
    osVersion = [[NSProcessInfo processInfo] operatingSystemVersionString];
#endif

    NSMutableString *banner = [NSMutableString string];
    [banner appendString:@"\n"];
    [banner appendString:@"================================================================\n"];
    [banner appendFormat:@"  SESSION START — %@\n", displayName.length ? displayName : (bundleIdentifier ?: @"(unknown)")];
    if (displayName.length && bundleIdentifier.length) {
        [banner appendFormat:@"  Bundle: %@\n", bundleIdentifier];
    }
    [banner appendFormat:@"  ReProvision %@ (%@)\n", appVersion, appBuild];
    [banner appendFormat:@"  OS %@ on %@\n", osVersion, model];
    [banner appendString:@"================================================================"];

    [self _write:banner synchronously:YES];
}

+ (void)logStage:(NSString *)stage {
    if (![self isEnabled]) return;
    [self _write:[NSString stringWithFormat:@"---------------- %@ ----------------", stage] synchronously:YES];
}

+ (void)endSessionSuccess:(BOOL)success message:(NSString *)message {
    if ([self isEnabled]) {
        NSMutableString *banner = [NSMutableString string];
        [banner appendFormat:@"  SESSION END — %@", success ? @"SUCCESS" : @"FAILED"];
        if (message.length) [banner appendFormat:@"\n  %@", message];
        [banner appendString:@"\n================================================================\n"];

        [self _write:banner synchronously:YES];
    }

    [self _setCurrentBundle:nil];
}

#pragma mark Reading / clearing

+ (NSString *)logContents {
    NSMutableString *combined = [NSMutableString string];
    for (NSString *p in [self logFiles]) {
        NSString *c = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (c.length) {
            [combined appendFormat:@"\n########## %@ ##########\n", [p lastPathComponent]];
            [combined appendString:c];
        }
    }
    return combined.length ? combined : nil;
}

+ (void)clearLog {
    dispatch_async([self _queue], ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [self logDirectory];
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if ([[f pathExtension] isEqualToString:@"log"]) {
                [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
            }
        }
    });
}

@end

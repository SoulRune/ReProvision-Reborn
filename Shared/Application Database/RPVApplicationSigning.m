//
//  RPVApplicationSigning.m
//  iOS
//
//  Created by Matt Clarke on 09/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVApplicationSigning.h"
#import "EEBackend.h"
#import "RPVApplication.h"
#import "RPVApplicationDatabase.h"

#import "SSZipArchive.h"

#import <dlfcn.h>
#import <objc/runtime.h>

// MCProfileConnection (ManagedConfiguration) - used to register a provisioning
// profile with the system so the OS trusts the signed app. Accessed purely via the
// ObjC runtime so there's no link-time dependency in non-UI targets.
@interface MCProfileConnection : NSObject
+ (instancetype)sharedConnection;
@end

/* Private headers */
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)arg1 withOptions:(NSDictionary *)arg2 error:(NSError **)arg3;
- (NSArray *)allApplications;
- (BOOL)uninstallApplication:(id)arg1 withOptions:(id)arg2;
@end


@interface RPVApplicationSigning ()

@property (nonatomic, strong) NSMutableArray *installQueue;
@property (nonatomic, readwrite) BOOL undertakingResignPipeline;
@property (nonatomic, readwrite) UIBackgroundTaskIdentifier currentBackgroundTaskIdentifier;

@property (nonatomic, strong) NSMutableArray *observers;

@end

static RPVApplicationSigning *sharedInstance;

@implementation RPVApplicationSigning

+ (instancetype)sharedInstance {
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });

    return sharedInstance;
}

- (instancetype)init {
    self = [super init];

    if (self) {
        self.observers = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appShouldBeRemoved:) name:@"jp.soh.reprovision/appShouldBeRemoved" object:nil];
    }

    return self;
}

- (void)addSigningUpdatesObserver:(id<RPVApplicationSigningProtocol>)observer {
    [self.observers addObject:observer];
}

- (void)removeSigningUpdatesObserver:(id<RPVApplicationSigningProtocol>)observer {
    [self.observers removeObject:observer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_resignApplicationsArray:(NSArray *)applications withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningDidStart];
        }

        if (self.undertakingResignPipeline) {
            NSError *error = [self _errorFromString:@"Already undertaking the re-sign pipeline!" errorCode:RPVErrorAlreadyUndertakingPipeline];

            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        } else {
            self.undertakingResignPipeline = YES;
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 1. Do pre-flight checks.
        //////////////////////////////////////////////////////////////////////////////////////

        // TODO: Network connectivity.

        // Update install queue with new applications list
        self.installQueue = [applications mutableCopy];

        //////////////////////////////////////////////////////////////////////////////////////
        // 2. Initiate signing for applications if applicable.
        //////////////////////////////////////////////////////////////////////////////////////

        // If no signing needed, just exit.
        if (self.installQueue.count == 0) {
            self.undertakingResignPipeline = NO;
            NSError *error = [self _errorFromString:@"No applications need re-signing" errorCode:RPVErrorNoSigningRequired];
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        }

        // Move to a background task!
        UIApplication *application = [UIApplication sharedApplication];
        UIBackgroundTaskIdentifier __block bgTask = [application beginBackgroundTaskWithName:@"ReProvision Application Signing" expirationHandler:^{
            // Clean up any unfinished task business by marking where you
            // stopped or ending the task outright.

            [application endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }];

        self.currentBackgroundTaskIdentifier = bgTask;

        // Update progress handler to 0% for all applications.
        for (RPVApplication *app in [self.installQueue reverseObjectEnumerator]) {
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningUpdateProgress:0 forBundleIdentifier:app.bundleIdentifier];
            }
        }

        // Start signing.
        [self _initiateNextInstallFromQueueWithTeamID:teamID
                                             username:username
                                             password:password];
    });
}

- (void)resignSpecificApplications:(NSArray *)applications withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    [self _resignApplicationsArray:applications withTeamID:teamID username:username password:password];
}

- (void)resignApplications:(BOOL)onlyExpiringApplications thresholdForExpiration:(int)thresholdForExpiration withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    //////////////////////////////////////////////////////////////////////////////////////
    // 0. Iterate over all the applications available in RPVApplicationDatabase.
    //////////////////////////////////////////////////////////////////////////////////////

    // Get list of applications from RPVApplicationDatabase
    NSMutableArray *applications = [NSMutableArray array];
    if (onlyExpiringApplications) {
        NSDate *now = [NSDate date];
        NSDate *expirationDate = [now dateByAddingTimeInterval:60 * 60 * 24 * thresholdForExpiration];

        if (![[RPVApplicationDatabase sharedInstance] getApplicationsWithExpiryDateBefore:&applications andAfter:nil date:expirationDate forTeamID:teamID]) {
            // sad times.
            self.undertakingResignPipeline = NO;
            NSError *error = [self _errorFromString:@"Failed to get applications within expiry date" errorCode:-1337];
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        }
    } else {
        applications = [[[RPVApplicationDatabase sharedInstance] getAllApplicationsForTeamID:teamID] mutableCopy];
    }

    [self _resignApplicationsArray:applications withTeamID:teamID username:username password:password];
}

/**
 For the given RPVApplication, this method copies its .app bundle into a directory structure of
 an extracted IPA, in a temporary directory.

 @param extractedArchiveURL Output URL of where the root directory structure is located
 @param applicationBundleURL Output URL of where the application's bundle is located
 @param error If non-null, any arising error.
 @return Success
 */
- (BOOL)_copyApplicationBundleForApplication:(RPVApplication *)application extractedArchiveURL:(NSURL **)extractedArchiveURL applicationBundleURL:(NSURL **)applicationBundleURL error:(NSError **)error {
    NSString *temporaryDirectory = [EEBackend applicationTemporaryDirectory];
    NSString *dotAppName = @"";

    if ([application.class isEqual:[RPVApplication class]]) {
        NSString *applicationBundleLocation = [application locationOfApplicationOnFilesystem].path;
        dotAppName = [applicationBundleLocation lastPathComponent];

        NSString *toPath = [NSString stringWithFormat:@"%@/%@/Payload/%@", temporaryDirectory, [application bundleIdentifier], dotAppName];

        // Create the parent path if needed
        NSString *parentPath = [toPath stringByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentPath]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:nil];
            // Delete any existing .app if needed too.
        } else if ([[NSFileManager defaultManager] fileExistsAtPath:toPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:toPath error:nil];
        }

        NSError *err;
        if (![[NSFileManager defaultManager] copyItemAtPath:applicationBundleLocation toPath:toPath error:&err]) {
            if (error) {
                *error = [self _errorFromString:err.localizedDescription errorCode:RPVErrorFailedToCopyBundle];
            }
            return NO;
        }

    } else {
        // This is an IPA application, therefore -locationOfApplicationOnFilesystem will return the .ipa
        // file on the filesystem.

        // We need to extract the IPA to our temporary location, and roll from there.
        NSString *extractionPath = [NSString stringWithFormat:@"%@/%@", temporaryDirectory, [application bundleIdentifier]];
        NSError *err;
        BOOL success = [SSZipArchive unzipFileAtPath:[application locationOfApplicationOnFilesystem].path
                                       toDestination:extractionPath
                                           overwrite:YES
                                            password:nil
                                               error:&err];

        if (success) {
            // Find the .app name

            NSArray *subdirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithFormat:@"%@/Payload/", extractionPath] error:nil];

            for (NSString *dir in subdirs) {
                if (![dir isEqualToString:@".DS_Store"]) {
                    dotAppName = dir;
                    break;
                }
            }

            // Clear the downloaded IPA now that it is extracted properly.
            NSError *cacheClearError;
            [[NSFileManager defaultManager] removeItemAtPath:[application locationOfApplicationOnFilesystem].path error:&cacheClearError];

            if (cacheClearError) {
                NSLog(@"Failed to remove '%@'", [application locationOfApplicationOnFilesystem].path);
            }
        } else {
            if (error) {
                *error = [self _errorFromString:err.localizedDescription errorCode:RPVErrorFailedToCopyBundle];
            }
            return NO;
        }
    }

    *extractedArchiveURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@", temporaryDirectory, [application bundleIdentifier]]];
    *applicationBundleURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@/Payload/%@", temporaryDirectory, [application bundleIdentifier], dotAppName]];

    return YES;
}

- (NSError *)_errorFromString:(NSString *)string errorCode:(int)code {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: NSLocalizedString(string, nil),
        NSLocalizedFailureReasonErrorKey: NSLocalizedString(string, nil),
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", nil)
    };

    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:code
                                     userInfo:userInfo];

    return error;
}

- (void)_initiateNextInstallFromQueueWithTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    if ([self.installQueue count] == 0) {
        // We can exit now.
        self.undertakingResignPipeline = NO;
    } else {
        // Pull next off the front of the array.
        RPVApplication *application = [self.installQueue firstObject];

        [self _resignApplication:application
                      withTeamID:teamID
                        username:username
                        password:password];
    }
}

// Register the signed app's provisioning profile with the system. On iOS 13/14 the
// on-device install registered the embedded profile automatically; on iOS 15+/rootless
// it does not, so the OS has no trusted profile for the app and rejects its signature
// ("failed to verify code signature" at install / instant AMFI kill at launch, and no
// entry in Settings > VPN & Device Management). This mirrors what Sideloadly/AltStore
// do as a separate step. Best-effort + heavily logged so we can confirm the exact API.
- (BOOL)_registerProvisioningProfileAtPath:(NSString *)profilePath {
    NSMutableString *report = [NSMutableString string];
    BOOL success = NO;

    NSData *data = [NSData dataWithContentsOfFile:profilePath];
    if (data.length == 0) {
        [report appendFormat:@"no profile data at %@\n", profilePath];
    } else {
        dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
        Class cls = objc_getClass("MCProfileConnection");
        id connection = cls ? [cls sharedConnection] : nil;

        if (!cls) {
            [report appendString:@"MCProfileConnection class unavailable\n"];
        } else if (!connection) {
            [report appendString:@"MCProfileConnection sharedConnection was nil\n"];
        } else {
            // The real provisioning-profile installer on iOS 15+:
            //   - (BOOL)installProvisioningProfileData:(NSData *)data
            //              managingProfileIdentifier:(NSString *)identifier
            //                               outError:(NSError **)error;
            SEL sel = NSSelectorFromString(@"installProvisioningProfileData:managingProfileIdentifier:outError:");
            if ([connection respondsToSelector:sel]) {
                NSMethodSignature *sig = [connection methodSignatureForSelector:sel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:connection];
                [inv setSelector:sel];
                [inv setArgument:&data atIndex:2];
                NSString *managing = nil;
                [inv setArgument:&managing atIndex:3];
                NSError *__autoreleasing outError = nil;
                NSError *__autoreleasing *outPtr = &outError;
                [inv setArgument:&outPtr atIndex:4];

                BOOL ret = NO;
                @try {
                    [inv invoke];
                    if (sig.methodReturnLength == sizeof(BOOL)) [inv getReturnValue:&ret];
                    success = ret && (outError == nil);
                    [report appendFormat:@"installProvisioningProfileData:managingProfileIdentifier:outError: returned %d, error: %@\n", ret, outError ?: @"none"];
                } @catch (NSException *e) {
                    [report appendFormat:@"install threw %@\n", e];
                }
            } else {
                [report appendString:@"installProvisioningProfileData:managingProfileIdentifier:outError: not available\n"];
            }
        }
    }

    NSLog(@"*** [ReProvision] profile register report:\n%@", report);

    return success;
}

- (void)_installIpaAtPath:(NSString *)ipaPath withBundleIdentifier:(NSString *)bundleIdentifier displayBundleIdentifier:(NSString *)displayBundleIdentifier {
    // bundleIdentifier is the *signed* id (with the Team ID suffix) - used for the
    // actual install/uninstall. displayBundleIdentifier is the id the UI tracks
    // progress under (the original, pre-signing id), so the progress bar reaches
    // 100% instead of getting stuck at 60%.
    if ([displayBundleIdentifier length] == 0) displayBundleIdentifier = bundleIdentifier;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        NSDictionary *options = @{ @"CFBundleIdentifier": bundleIdentifier, @"AllowInstallLocalProvisioned": [NSNumber numberWithBool:YES] };

        NSURL *ipaURL = [NSURL fileURLWithPath:ipaPath];

        // Make a cached version of the .ipa for if we need to handle another go-around.
        [[NSFileManager defaultManager] copyItemAtPath:ipaPath toPath:[ipaPath stringByReplacingOccurrencesOfString:@".ipa" withString:@"2.ipa"] error:nil];

        NSLog(@"Does ipaPath exist? %d", [[NSFileManager defaultManager] fileExistsAtPath:ipaPath]);

        BOOL result = NO;
        @try {
            result = [[LSApplicationWorkspace defaultWorkspace] installApplication:ipaURL
                                                                       withOptions:options
                                                                             error:&error];
        } @catch (NSException *e) {
            error = [self _errorFromString:e.description errorCode:RPVErrorFailedToInstallSignedIPA];
            result = NO;
        }

        if (!result) {
            // Check if this is the case where it's an app from another Team ID.
            if (error.code == 64 || [error.localizedDescription containsString:@"LaunchServicesError error 0"]) {
                // Delete the original app, and try again.
                if ([[LSApplicationWorkspace defaultWorkspace] uninstallApplication:bundleIdentifier withOptions:nil]) {
                    // Try again!

                    // Update progress to 70% for this application.
                    for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                        [observer applicationSigningUpdateProgress:75 forBundleIdentifier:displayBundleIdentifier];
                    }

                    NSLog(@"*** Uninstalled application, trying again.");
                    [self _installIpaAtPath:[ipaPath stringByReplacingOccurrencesOfString:@".ipa" withString:@"2.ipa"] withBundleIdentifier:bundleIdentifier displayBundleIdentifier:displayBundleIdentifier];

                    return;
                }
            }

            // Build a full, faithful description of the installd error. The old
            // code tried to extract a "user friendly" substring (everything after
            // the last "("), which mangled iOS 16 errors into a useless set fragment
            // like ("com.foo.bar.TEAMID") and hid the real reason. Keep the friendly
            // mappings for known cases, but otherwise surface the raw error verbatim.
            NSString *rawDescription = error.localizedDescription ?: @"Unknown install error";
            NSString *fullError = [NSString stringWithFormat:@"%@ [%@ %ld]", rawDescription, error.domain ?: @"?", (long)error.code];

            // Pull underlying error / recovery details into the message too.
            NSString *underlying = [[error.userInfo objectForKey:NSUnderlyingErrorKey] localizedDescription];
            if ([underlying length] > 0) {
                fullError = [fullError stringByAppendingFormat:@" | underlying: %@", underlying];
            }

            // Show the raw installd error verbatim. (Older code tried to map known
            // codes to "friendly" text - including a wrong "3 app limit" message for
            // code 13 - which hid the real reason, so we just surface the truth.)
            NSString *errorMessage = fullError;

            NSLog(@"*** [ReProvision] install failed: domain=%@ code=%ld desc=%@ userInfo=%@", error.domain, (long)error.code, error.localizedDescription, error.userInfo);

            NSError *err = [self _errorFromString:errorMessage errorCode:RPVErrorFailedToInstallSignedIPA];
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningDidEncounterError:err forBundleIdentifier:displayBundleIdentifier];
            }
        }

        if (result) {
            // Update progress to 90% for this application.
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningUpdateProgress:90 forBundleIdentifier:displayBundleIdentifier];
            }
        }

        // Clean up.
        [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[ipaPath stringByReplacingOccurrencesOfString:@".ipa" withString:@"2.ipa"] error:nil];

        if (result) {
            // Update progress to 100% for this application.
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningUpdateProgress:100 forBundleIdentifier:displayBundleIdentifier];
            }
        }

        // If this was the last application, notify the completionHandler of success
        if (!self.undertakingResignPipeline) {
            // End the background task!
            [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
            self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;

            // Notify of success!
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:nil];
            }
        }
    });
}

- (void)_resignApplication:(RPVApplication *)application withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    // Update progress to 10% for this application.
    for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
        [observer applicationSigningUpdateProgress:10 forBundleIdentifier:[application bundleIdentifier]];
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // 1. Make a copy of this application's .app into a directory structure of an IPA.
    //////////////////////////////////////////////////////////////////////////////////////

    NSURL *extractedArchiveURL;   // This root directory is repacked into an IPA.
    NSURL *applicationBundleURL;  // Passed to EEbackend to sign (the .app).
    NSError *error;

    if (![self _copyApplicationBundleForApplication:application extractedArchiveURL:&extractedArchiveURL applicationBundleURL:&applicationBundleURL error:&error]) {
        // Callback to say we done "goofed".
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningDidEncounterError:error forBundleIdentifier:[application bundleIdentifier]];
        }

        // Start the next application off.
        if (self.installQueue.count > 1) {
            [self.installQueue removeObjectAtIndex:0];
            [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                 username:username
                                                 password:password];
        } else {
            // End the background task!
            [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
            self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;

            self.undertakingResignPipeline = NO;

            // Notify of failure
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
        }

        return;
    }

    // Update progress to 30% for this application.
    for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
        [observer applicationSigningUpdateProgress:30 forBundleIdentifier:[application bundleIdentifier]];
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // 2. Use libProvision to sign the .app
    //////////////////////////////////////////////////////////////////////////////////////

    [EEBackend signBundleAtPath:[applicationBundleURL path] identity:username gsToken:password priorChosenTeamID:teamID withCompletionHandler:^(NSError *error) {
        if (error) {
            // Callback to say we done "goofed".
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningDidEncounterError:error forBundleIdentifier:[application bundleIdentifier]];
            }

            // TODO: Cleanup the filesystem?

            // Start the next application off.
            if (self.installQueue.count > 1) {
                [self.installQueue removeObjectAtIndex:0];
                [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                     username:username
                                                     password:password];
            } else {
                // End the background task!
                [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
                self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;

                self.undertakingResignPipeline = NO;

                // Notify of failure
                for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                    [observer applicationSigningCompleteWithError:error];
                }
            }

            return;
        }

        // Update progress to 50% for this application.
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningUpdateProgress:50 forBundleIdentifier:[application bundleIdentifier]];
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 3. Build IPA
        //////////////////////////////////////////////////////////////////////////////////////

        NSString *outputIpaPath = [NSString stringWithFormat:@"%@/%@.ipa", [EEBackend applicationTemporaryDirectory], [application bundleIdentifier]];

        NSError *err;
        if (![EEBackend repackIpaAtPath:[extractedArchiveURL path] toPath:outputIpaPath error:&err]) {
            // Callback to say we done "goofed".
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningDidEncounterError:error forBundleIdentifier:[application bundleIdentifier]];
            }

            // TODO: Cleanup the filesystem?

            // Start the next application off.
            if (self.installQueue.count > 1) {
                [self.installQueue removeObjectAtIndex:0];
                [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                     username:username
                                                     password:password];
            } else {
                // End the background task!
                [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
                self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;

                self.undertakingResignPipeline = NO;

                // Notify of failure
                for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                    [observer applicationSigningCompleteWithError:error];
                }
            }

            return;
        }

        // Update progress to 60% for this application.
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningUpdateProgress:60 forBundleIdentifier:[application bundleIdentifier]];
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 4. Install IPA
        //////////////////////////////////////////////////////////////////////////////////////

        // libProvision appends the Team ID to the bundle id when signing (e.g.
        // com.opa334.Dopamine -> com.opa334.Dopamine.C9RTXQNQ3J). installd matches
        // the IPA against the CFBundleIdentifier install option, so we must pass the
        // *signed* id, not the original. Read it straight from the repacked app's
        // Info.plist; fall back to the original only if that read fails.
        NSString *bundleIdentifier = [application bundleIdentifier];
        NSString *signedInfoPlistPath = [[applicationBundleURL path] stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *signedInfoPlist = [NSDictionary dictionaryWithContentsOfFile:signedInfoPlistPath];
        NSString *signedBundleIdentifier = [signedInfoPlist objectForKey:@"CFBundleIdentifier"];
        if ([signedBundleIdentifier length] > 0) {
            bundleIdentifier = signedBundleIdentifier;
        }
        NSLog(@"*** [ReProvision] installing with bundle id '%@' (original '%@')", bundleIdentifier, [application bundleIdentifier]);

        // Register the freshly-signed provisioning profile with the system so iOS
        // trusts the signed app (misagent/MCProfileConnection). Without this the OS
        // refuses to launch the app even when the signature itself is valid.
        NSString *embeddedPath = [[applicationBundleURL path] stringByAppendingPathComponent:@"embedded.mobileprovision"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:embeddedPath]) {
            BOOL registered = [self _registerProvisioningProfileAtPath:embeddedPath];
            NSLog(@"*** [ReProvision] provisioning profile registered with system: %d", registered);
        }

        // Start the next application off at this point for some parallelism!
        if (self.installQueue.count > 1) {
            [self.installQueue removeObjectAtIndex:0];
            [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                 username:username
                                                 password:password];
        } else {
            // Flag that we're done!
            self.undertakingResignPipeline = NO;
        }

        // And now we install! Install under the signed id, but report progress
        // under the original id that the UI is tracking.
        [self _installIpaAtPath:outputIpaPath withBundleIdentifier:bundleIdentifier displayBundleIdentifier:[application bundleIdentifier]];
    }];
}

////////////////////////////////////////////////////////////////////////////////
// Application handling callbacks
////////////////////////////////////////////////////////////////////////////////

- (BOOL)removeApplicationWithBundleIdentifier:(NSString *)bundleIdentifier {
    BOOL ret = NO;
    if (bundleIdentifier) {
        ret = [[LSApplicationWorkspace defaultWorkspace] uninstallApplication:bundleIdentifier withOptions:nil];
    }
    return ret;
}

- (void)_appShouldBeRemoved:(NSNotification *)notification {
    NSString *bundleIdentifier = [[notification userInfo] objectForKey:@"bundleIdentifier"];
    if (bundleIdentifier) {
        [[LSApplicationWorkspace defaultWorkspace] uninstallApplication:bundleIdentifier withOptions:nil];
    }
}

@end

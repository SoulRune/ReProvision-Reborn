//
//  EEBackend.h
//  OpenExtenderTest
//
//  Created by Matt Clarke on 02/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "EEAppleServices.h"

/**
 EEBackend provides an easy interface through which to sign a given IPA file.
 
 The Apple ID credentials passed to the below methods are ONLY sent to Apple. You can verify
 this yourself by studying the source code.
 */
@interface EEBackend : NSObject

/**
 * TODO: Docs!
 */
+ (void)provisionDevice:(NSString*)udid name:(NSString*)name identity:(NSString*)identity gsToken:(NSString*)gsToken priorChosenTeamID:(NSString*)teamId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler;

/**
 * TODO: Docs!
 */
+ (void)revokeDevelopmentCertificatesForCurrentMachineWithIdentity:(NSString*)identity gsToken:(NSString*)gsToken priorChosenTeamID:(NSString*)teamId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler;

/**
 * TODO: Docs!
 */
+ (void)signBundleAtPath:(NSString*)path identity:(NSString*)identity gsToken:(NSString*)gsToken priorChosenTeamID:(NSString*)teamId withCompletionHandler:(void (^)(NSError *))completionHandler;

/**
 Signs the IPA specified at the inputPath, then outputs it to the outputPath. *simple*.
 
 @param ipaPath The path the IPA to sign is currently available at.
 @param outputPath The path to write the signed IPA to. This can be the same as the inputPath
 @param identity The DSID identity of the Apple ID used to sign with
 @param gsToken The GS Token of the Apple ID used to sign with.
 @param teamId If the user's Apple ID is associated with multiple developer accounts, this is the Team ID that should be used.
 @param completionHandler Called once the IPA is signed and present at the outputPath. If any errors occurred during the process, the first parameter of the completionHandler will contain further information.
 */
+ (void)signIpaAtPath:(NSString*)ipaPath outputPath:(NSString*)outputPath identity:(NSString*)identity gsToken:(NSString*)gsToken priorChosenTeamID:(NSString*)teamId withCompletionHandler:(void (^)(NSError *))completionHandler;

/**
 Unpacks the contents of the specified IPA into a directory.
 @param ipaPath Path to the IPA to unpack
 @param outputDirectory A pointer that will be updated to the directory the IPA is unpacked to
 @param error A pointer will be updated with any errors that occurred.
 @return Success or failure
 */
+ (BOOL)unpackIpaAtPath:(NSString*)ipaPath outDirectory:(NSString**)outputDirectory error:(NSError**)error;

/**
 Repacks the contents of the IPA directory structure into an IPA file.
 @param extractedPath Path to the IPA directory structure to repack
 @param outputPath Path where the IPA should be written
 @param error A pointer will be updated with any errors that occurred.
 @return Success or failure
 */
+ (BOOL)repackIpaAtPath:(NSString*)extractedPath toPath:(NSString*)outputPath error:(NSError**)error;

/**
 Asks sandboxing APIs for a temporary directory to use.
 @return The temporary directory the current application can utilise.
 */
+ (NSString*)applicationTemporaryDirectory;

@end

#pragma mark - Signing log

/**
 Optional file logging for the signing pipeline.

 Everything in the signing path uses NSLog, which on iOS goes only to os_log -
 invisible unless you happen to be attached over SSH with `oslog` running at the exact
 moment of failure.
 Off by default. Toggle lives in Settings -> Advanced -> Signing Log.
 */
@interface RPVLogger : NSObject

/// YES if file logging is currently enabled (reads the `logSigningToFile` preference).
+ (BOOL)isEnabled;

/// Enable/disable file logging. Persists to NSUserDefaults.
+ (void)setEnabled:(BOOL)enabled;

/// Absolute path of the current log file. Valid even when logging is disabled.
+ (NSString *)logFilePath;

/// Absolute path of the rotated (previous) log file.
+ (NSString *)previousLogFilePath;

/// Current log size in bytes (0 if no log exists).
+ (unsigned long long)logFileSize;

/// Contents of previous + current log, oldest first. Nil if nothing logged yet.
+ (NSString *)logContents;

/// Delete both current and rotated logs.
+ (void)clearLog;

/// Write a line. No-op when disabled. Safe to call from any thread or queue.
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// Write a line without formatting. Still redacted.
+ (void)logRaw:(NSString *)message;

/// Mark the start of a signing run — writes a banner with device/app context.
+ (void)beginSessionForBundle:(NSString *)bundleIdentifier;

/// Mark the end of a signing run.
+ (void)endSessionSuccess:(BOOL)success message:(NSString *)message;

@end

/**
 Drop-in replacement for NSLog: always goes to os_log, and additionally to the file
 when logging is enabled. Behaviour with the toggle off is identical to plain NSLog
 plus one BOOL read.
 */
#define RPVLog(fmt, ...)                              \
    do {                                              \
        NSLog(fmt, ##__VA_ARGS__);                    \
        [RPVLogger log:fmt, ##__VA_ARGS__];           \
    } while (0)

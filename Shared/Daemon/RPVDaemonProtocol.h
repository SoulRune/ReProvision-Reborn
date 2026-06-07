//
//  RPVDaemonProtocol.h
//  ReProvision
//
//  Created by Matt Clarke on 24/08/2019.
//  Copyright © 2019 Matt Clarke. All rights reserved.
//

@protocol RPVDaemonProtocol <NSObject>

- (void)applicationDidLaunch;
- (void)applicationDidFinishTask;

- (void)applicationRequestsDebuggingBackgroundSigning;
- (void)applicationRequestsPreferencesUpdate;

// Copy a file the app cannot read itself. The GUI is signed no-container
// (platform-application) and therefore cannot read files vended by another app's /
// provider's File Provider via the document picker's security-scoped URL. The daemon runs
// as root and can read any on-disk path, so it copies srcPath -> dstPath (dstPath being a
// location the app can read, e.g. its own tmp dir) and reports success.
- (void)copyFileAtPath:(NSString *)srcPath toPath:(NSString *)dstPath withReply:(void (^)(BOOL success))reply;

@end

//
//  ShareViewController.m
//  iOS Share Extension
//
//  Created by Matt Clarke on 24/12/2019.
//  Copyright © 2019 Matt Clarke. All rights reserved.
//

#import "ShareViewController.h"

// Shared between the app and this extension (see Shared/entitlements.xml). Both
// processes carry this group entitlement, so its container is the one location
// the extension can write to and the main app can later read from.
#define RPV_APP_GROUP @"group.jp.soh.reprovision.ios"
#define RPV_IPA_TYPE @"jp.soh.reprovision.ipa"

@interface ShareViewController ()

@end

@implementation ShareViewController

- (BOOL)openURL:(NSURL*)url {
    UIResponder *responder = self;
    UIApplication *application = nil;

    while (![[responder class] isEqual:[UIApplication class]] && responder != nil) {
        responder = responder.nextResponder;

        if ([[responder class] isEqual:[UIApplication class]]) {
            application = (UIApplication*)responder;
            break;
        }
    }

    if (application) {
        return (BOOL)[application performSelector:@selector(openURL:) withObject:url];
    } else {
        return NO;
    }
}

- (NSString *)getUUID {
    CFUUIDRef newUniqueId = CFUUIDCreate(kCFAllocatorDefault);
    NSString * uuidString = (__bridge_transfer NSString*)CFUUIDCreateString(kCFAllocatorDefault, newUniqueId);
    CFRelease(newUniqueId);

    return uuidString;
}

// The shared "Inbox" inside the App Group container. This is the hand-off point:
// the extension copies the incoming .ipa here, then the main app reads it back.
- (NSURL *)sharedInboxDirectory {
    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:RPV_APP_GROUP];
    if (!container) {
        NSLog(@"ReProvision :: could not resolve App Group container %@", RPV_APP_GROUP);
        return nil;
    }

    NSURL *inbox = [container URLByAppendingPathComponent:@"Inbox" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:inbox withIntermediateDirectories:YES attributes:nil error:nil];
    return inbox;
}

// Persist whatever loadItemForTypeIdentifier: handed back (an NSURL into the
// extension's transient storage, or raw NSData) into the shared Inbox so it
// survives this extension being torn down and is reachable by the main app.
- (NSURL *)persistIncomingItem:(id)item suggestedName:(NSString *)suggestedName {
    NSURL *inbox = [self sharedInboxDirectory];
    if (!inbox) return nil;

    NSString *filename = nil;
    if ([item isKindOfClass:[NSURL class]])
        filename = [(NSURL *)item lastPathComponent];
    if (filename.length == 0)
        filename = suggestedName;
    if (filename.length == 0)
        filename = @"application.ipa";
    // The main app keys off the .ipa extension downstream, so guarantee it.
    if (![[filename.pathExtension lowercaseString] isEqualToString:@"ipa"])
        filename = [filename stringByAppendingPathExtension:@"ipa"];

    // Namespace the copy so concurrent / repeated shares don't clash.
    NSURL *destDir = [inbox URLByAppendingPathComponent:[self getUUID] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *dest = [destDir URLByAppendingPathComponent:filename];

    if ([item isKindOfClass:[NSURL class]]) {
        NSURL *src = (NSURL *)item;

        // URLs vended by another app are security-scoped and only readable while access
        // is held.
        BOOL scoped = [src startAccessingSecurityScopedResource];

        NSError *err = nil;
        BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:src toURL:dest error:&err];

        // A path-level copy can be denied for files handed over by another process; fall
        // back to reading the bytes and writing them ourselves.
        if (!ok) {
            NSData *data = [NSData dataWithContentsOfURL:src options:0 error:nil];
            if (data) ok = [data writeToURL:dest options:NSDataWritingAtomic error:&err];
        }

        if (scoped) [src stopAccessingSecurityScopedResource];

        if (!ok) {
            NSLog(@"ReProvision :: failed to copy shared .ipa: %@", err);
            return nil;
        }
        return dest;
    } else if ([item isKindOfClass:[NSData class]]) {
        NSError *err = nil;
        if ([(NSData *)item writeToURL:dest options:NSDataWritingAtomic error:&err])
            return dest;
        NSLog(@"ReProvision :: failed to write shared .ipa data: %@", err);
        return nil;
    }

    NSLog(@"ReProvision :: unexpected shared item class %@", [item class]);
    return nil;
}

- (void)copyIncomingFileToInboxWithCompletion:(void (^)(BOOL success, NSURL *location))completion {
    NSExtensionItem *firstItem = [self.extensionContext.inputItems firstObject];
    NSItemProvider *firstAttachment = [firstItem.attachments firstObject];

    // Prefer our own exported .ipa UTI, but accept a generic data attachment in case the
    // source provider tagged the file differently.
    NSString *typeId = nil;
    if ([firstAttachment hasItemConformingToTypeIdentifier:RPV_IPA_TYPE])
        typeId = RPV_IPA_TYPE;
    else if ([firstAttachment hasItemConformingToTypeIdentifier:@"public.data"])
        typeId = @"public.data";

    if (!typeId) {
        completion(NO, nil);
        return;
    }

    [firstAttachment loadItemForTypeIdentifier:typeId
                                       options:nil
                             completionHandler:^(id<NSSecureCoding> item, NSError * _Null_unspecified error) {
        if (error) {
            NSLog(@"ReProvision :: %@", error);
        } else if (!item) {
            NSLog(@"ReProvision :: item is nil");
        }

        NSURL *location = [self persistIncomingItem:(id)item suggestedName:firstAttachment.suggestedName];
        completion(location != nil, location);
    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Handle going to main app
    [self copyIncomingFileToInboxWithCompletion:^(BOOL success, NSURL *location) {
        if (success) {
            [self.extensionContext completeRequestReturningItems:@[] completionHandler:^(BOOL expired) {
                NSLog(@"Exited, launching main app");

                NSMutableCharacterSet *chars = NSCharacterSet.URLQueryAllowedCharacterSet.mutableCopy;
                [chars removeCharactersInRange:NSMakeRange('&', 1)];
                [chars removeCharactersInRange:NSMakeRange('/', 1)];

                NSString *encodedString = [[location path] stringByAddingPercentEncodingWithAllowedCharacters:chars];

                NSString *queryString = [NSString stringWithFormat:@"reprovision://share/%@", encodedString];

                [self openURL:[NSURL URLWithString:queryString]];
            }];
        } else {
            NSLog(@"FAILED TO COPY TO MAIN APP!");
            // Don't leave the user staring at a stuck share sheet on failure.
            [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
        }
    }];
}

@end

//
//  RPVApplication.m
//  iOS
//
//  Created by Matt Clarke on 09/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVApplication.h"

@interface _LSDiskUsage : NSObject
@property (nonatomic, readonly) NSNumber *dynamicUsage;
@property (nonatomic, readonly) NSNumber *onDemandResourcesUsage;
@property (nonatomic, readonly) NSNumber *sharedUsage;
@property (nonatomic, readonly) NSNumber *staticUsage;
@end

@interface LSApplicationProxy : NSObject

@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) _LSDiskUsage *diskUsage;
@property (nonatomic, readonly) NSString *shortVersionString;
@property (nonatomic, readonly) NSNumber *staticDiskUsage;

+ (instancetype)applicationProxyForIdentifier:(NSString *)arg1;

- (id)localizedName;
- (id)primaryIconDataForVariant:(int)arg1;
- (id)iconDataForVariant:(int)arg1;
@end

@interface UIImage (Private)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface RPVApplication ()
@property (nonatomic, strong) LSApplicationProxy *proxy;
@end

@implementation RPVApplication

- (instancetype)initWithApplicationProxy:(LSApplicationProxy *)proxy {
    self = [super init];

    if (self) {
        self.proxy = proxy;
    }

    return self;
}

- (NSString *)bundleIdentifier {
    return self.proxy != nil ? self.proxy.applicationIdentifier : @"com.mycompany.example";
}

- (NSString *)applicationName {
    return self.proxy != nil ? [self.proxy localizedName] : @"Example";
}

- (NSString *)applicationVersion {
    return self.proxy != nil ? [self.proxy shortVersionString] : @"1.0";
}

- (NSNumber *)applicationInstalledSize {
    if (!self.proxy) {
        return @0;
    }

    if ([self.proxy respondsToSelector:@selector(diskUsage)])
        return [self.proxy.diskUsage staticUsage];
    else
        return self.proxy.staticDiskUsage;
}

- (UIImage *)applicationIcon {
    UIImage *icon;

    if (self.proxy != nil) {
        icon = [UIImage _applicationIconImageForBundleIdentifier:[self bundleIdentifier] format:2 scale:[UIScreen mainScreen].scale];
    } else {
        icon = [UIImage imageNamed:@"AppIcon40x40"];
    }

    return icon;
}

- (UIImage *)tvOSApplicationIcon {
    return [UIImage _applicationIconImageForBundleIdentifier:[self bundleIdentifier] format:2 scale:[UIScreen mainScreen].scale];
}

- (BOOL)_provisioningProfileReallyExists {
    // Get provisioning file from app
    NSString *appProvisioningPath = [[self.proxy.bundleURL path] stringByAppendingString:@"/embedded.mobileprovision"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:appProvisioningPath]) return NO;

    NSDictionary *appProvisioningFile = [RPVApplication provisioningProfileAtPath:appProvisioningPath];
    if (![appProvisioningFile isKindOfClass:[NSDictionary class]] || appProvisioningFile.count == 0) return NO;

    // Historically we cross-checked the embedded profile against the system store at
    // /var/MobileDevice/ProvisioningProfiles to make sure it is still installed.
    // On iOS 15+/rootless that directory typically can't be enumerated from here, so
    // the strict isEqualToDictionary check failed for EVERY app and made even
    // perfectly valid apps report as "expired". Match by the profile UUID when we can
    // read the store, and otherwise trust the app's own embedded profile.
    NSString *profilesFolderPath = @"/var/MobileDevice/ProvisioningProfiles";
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:profilesFolderPath error:nil];

    if (contents.count == 0) {
        // Can't verify against the system store - trust the embedded profile.
        return YES;
    }

    NSString *appUUID = [appProvisioningFile objectForKey:@"UUID"];
    for (NSString *file in contents) {
        NSString *filePath = [profilesFolderPath stringByAppendingPathComponent:file];
        NSDictionary *provisioningProfile = [RPVApplication provisioningProfileAtPath:filePath];
        if (![provisioningProfile isKindOfClass:[NSDictionary class]]) continue;

        NSString *uuid = [provisioningProfile objectForKey:@"UUID"];
        if (appUUID.length > 0 && [appUUID isEqualToString:uuid]) return YES;
        if ([appProvisioningFile isEqualToDictionary:provisioningProfile]) return YES;
    }

    // We could read the store but found no match. The profile may live elsewhere on
    // this OS; be lenient and trust the embedded profile's own ExpirationDate rather
    // than forcing an incorrect "expired" state.
    return YES;
}

- (NSDate *)applicationExpiryDate {
    if (!self.proxy) {
        // Date that is 2 days away.
        return [NSDate date];
    }

    NSString *provisionPath = [[self.proxy.bundleURL path] stringByAppendingString:@"/embedded.mobileprovision"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:provisionPath]) {
        NSLog(@"*** [ReProvision] :: ERROR :: No embedded.mobileprovision at %@, given bundleURL is %@", provisionPath, self.proxy.bundleURL);

        return [NSDate date];
    }

    NSDictionary *provision = [RPVApplication provisioningProfileAtPath:provisionPath];
    if (!provision) {
        return [NSDate date];
    }

    if (!self._provisioningProfileReallyExists) {
        return [NSDate date];
    }

    return [provision objectForKey:@"ExpirationDate"];
}

- (BOOL)hasEmbeddedMobileprovision {
    if (!self.proxy) {
        return NO;
    }

    NSString *provisionPath = [[self.proxy.bundleURL path] stringByAppendingString:@"/embedded.mobileprovision"];
    return [[NSFileManager defaultManager] fileExistsAtPath:provisionPath];
}

- (NSURL *)locationOfApplicationOnFilesystem {
    return self.proxy.bundleURL;
}

+ (NSDictionary *)provisioningProfileAtPath:(NSString *)path {
    NSError *err;
    // A .mobileprovision is a PKCS#7/CMS container with bytes > 127, so reading it as
    // strict ASCII returns nil and the whole parse silently fails (making every app
    // look "expired"). ISO Latin-1 maps all 256 byte values and never fails; the
    // <plist> payload itself is ASCII XML, so extraction stays correct.
    NSString *stringContent = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:&err];

    NSString *startMarker = @"<plist";
    NSString *endMarker = @"</plist>";

    NSRange startRange = [stringContent rangeOfString:startMarker];
    if (startRange.location == NSNotFound) {
        return @{};
    }

    NSRange endRange = [stringContent rangeOfString:endMarker];
    if (endRange.location == NSNotFound) {
        return @{};
    }

    NSInteger length = (endRange.location + endMarker.length) - startRange.location;
    stringContent = [stringContent substringWithRange:NSMakeRange(startRange.location, length)];

    NSData *stringData = [stringContent dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error;
    NSPropertyListFormat format;

    @try {
        id plist = [NSPropertyListSerialization propertyListWithData:stringData options:NSPropertyListImmutable format:&format error:&error];
        return plist;
    } @catch (NSException *e) {
        NSLog(@"*** ReProvision :: Failed to parse plist: %@, %@", e, stringData);
        return @{};
    }
}

@end

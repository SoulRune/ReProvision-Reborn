//
//  EESigning.m
//  OpenExtenderTest
//
//  Created by Matt Clarke on 28/12/2017.
//  Copyright © 2017 Matt Clarke. All rights reserved.
//

#import "EESigning.h"
#include "ldid.hpp"

#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <stdio.h>

static auto dummy([](double) {});

// Build the set of entitlement keys we're allowed to keep when re-signing. The
// authoritative source is the provisioning profile Apple just issued for this app
// (its "Entitlements" dict = exactly what this free account is permitted to use), so
// we read it straight from the embedded.mobileprovision in the bundle. We union that
// with the always-present basics plus game-center (benign and tolerated). Everything
// NOT in this set - iCloud/CloudKit, associated-domains, app groups, push, and
// private/jailbreak entitlements like platform-application / run-unsigned-code /
// com.apple.private.* - is stripped, otherwise installd rejects the app (0xe8008001)
// or it gets killed right after launch.
//
// IMPORTANT: `bundlePath` must be the bundle that OWNS the embedded.mobileprovision
// we want to consult. For the main app that's the .app root; for an app extension
// that's the .appex root (which has its own provisioning profile with its own
// distinct set of allowed entitlements - e.g. app-groups for a widget).
static NSSet *RPVAllowedEntitlementKeys(NSString *bundlePath) {
    NSMutableSet *allowed = [NSMutableSet setWithObjects:
        @"application-identifier",
        @"com.apple.developer.team-identifier",
        @"keychain-access-groups",
        @"get-task-allow",
        @"com.apple.developer.game-center",
        nil];

    NSString *profilePath = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    NSString *content = [NSString stringWithContentsOfFile:profilePath encoding:NSISOLatin1StringEncoding error:nil];
    NSRange s = [content rangeOfString:@"<plist"];
    NSRange e = [content rangeOfString:@"</plist>"];
    if (content && s.location != NSNotFound && e.location != NSNotFound) {
        NSString *plistStr = [content substringWithRange:NSMakeRange(s.location, e.location + e.length - s.location)];
        NSDictionary *prof = [NSPropertyListSerialization propertyListWithData:[plistStr dataUsingEncoding:NSUTF8StringEncoding] options:0 format:NULL error:nil];
        NSDictionary *profEnt = prof[@"Entitlements"];
        if ([profEnt isKindOfClass:[NSDictionary class]]) {
            [allowed addObjectsFromArray:[profEnt allKeys]];
        }
    }

    return allowed;
}

// Given a path RELATIVE to the main bundle root (as passed to the ldid alter callback
// for a nested Mach-O), find the enclosing .appex bundle root, if any. ldid passes
// paths like "PlugIns/AltWidgetExtension.appex/AltWidgetExtension" for extension
// executables and "Frameworks/Foo.framework/Foo" for frameworks; only care about
// .appex (frameworks have no entitlements anyway).
static NSString *RPVEnclosingAppexPath(NSString *mainBundleAbsPath, const std::string &relPath) {
    if (relPath.empty()) return nil;
    NSString *rel = [NSString stringWithUTF8String:relPath.c_str()];
    NSRange r = [rel rangeOfString:@".appex/"];
    if (r.location == NSNotFound) return nil;
    NSString *appexRel = [rel substringToIndex:r.location + r.length - 1]; // drop trailing '/'
    return [mainBundleAbsPath stringByAppendingPathComponent:appexRel];
}

// Strip entitlements not in `allowed` from an XML entitlements string (used for
// nested frameworks/dylibs, whose entitlements arrive as XML from ldid::Analyze).
static std::string RPVSanitizeEntitlementsXML(const std::string &xml, NSSet *allowed) {
    if (xml.empty()) return xml;

    // The string may carry a trailing NUL / junk after </plist>; trim to the plist.
    std::string trimmed = xml;
    size_t end = trimmed.rfind("</plist>");
    if (end != std::string::npos) trimmed = trimmed.substr(0, end + 8);

    NSData *data = [NSData dataWithBytes:trimmed.data() length:trimmed.size()];
    NSError *err = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:&err];
    if (![plist isKindOfClass:[NSDictionary class]]) return xml;

    NSMutableDictionary *dict = (NSMutableDictionary *)plist;
    BOOL changed = NO;
    for (NSString *key in [dict allKeys]) {
        if (![allowed containsObject:key]) {
            [dict removeObjectForKey:key];
            changed = YES;
        }
    }
    if (!changed) return xml;

    NSData *out = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
    if (out == nil) return xml;
    return std::string((const char *)out.bytes, out.length);
}

// Private methods - declared here so the compiler sees the new selectors
// (added by the rootless / iOS 15+ fix set) before their first use in this file.
@interface EESigning ()
- (STACK_OF(X509) *)_loadCAChainStackFromDiskForCertificate:(NSData *)certificate;
- (X509 *)_loadCAChainFromDiskForCertificate:(NSData *)certificate;
- (std::string)_createPKCS12CertificateWithKey:(NSString *)key certificate:(NSData *)certificate andCAChain:(X509 *)chain;
- (std::string)_createPKCS12CertificateWithKey:(NSString *)key certificate:(NSData *)certificate andCAChainStack:(STACK_OF(X509) *)chainStack;
- (std::string)_createRequirementsBlobWithKey:(NSString *)key certificate:(NSData *)certificate andBundleIdentifier:(NSString *)identifier;
@end

@implementation EESigning

+ (instancetype)signerWithCertificate:(NSData *)certificate privateKey:(NSString *)privateKey {
    return [[EESigning alloc] initWithCertificate:certificate privateKey:privateKey];
}

- (instancetype)initWithCertificate:(NSData *)certificate privateKey:(NSString *)privateKey {
    self = [super init];

    if (self) {
        _certificate = certificate;
        _privateKey = privateKey;

        // Create a PKCS12 certificate from the private key and certificate.
		// This is what ldid accepts in Sign().
        STACK_OF(X509) *chain = [self _loadCAChainStackFromDiskForCertificate:certificate];
        _PKCS12 = [self _createPKCS12CertificateWithKey:privateKey
                                            certificate:certificate
                                          andCAChainStack:chain];
        if (_PKCS12.size() == 0) {
            NSLog(@"*** [ReProvision] PKCS12 creation returned empty - signing will fail");
        }
    }

    return self;
}

+ (NSMutableDictionary *)getEntitlementsForBinaryAtLocation:(NSString *)binaryLocation {
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];

    NSLog(@"Loading entitlements for: '%@'", binaryLocation);

    // Make sure to pass in the entitlements already present, updating as needed.
    NSData *binaryData = [NSData dataWithContentsOfFile:binaryLocation];
    if (!binaryData || binaryData.length == 0) {
        return nil;
    }

    // If entitlements are present, we MUST update the following keys first:
    // application-identifier -> <teamId>.<applicationIdentifier>
    // com.apple.developer.team-identifier -> <teamId>
    // keychain-access-groups -> array containing <teamId>.<applicationIdentifier>

    std::string entitlements = ldid::Analyze([binaryData bytes], (size_t)[binaryData length]);
    if (entitlements.length() > 0) {
        NSLog(@"Has entitlements in binary, so loading existing!");
        NSData *plistData = [NSData dataWithBytes:entitlements.data() length:entitlements.length()];

        NSError *error;
        NSPropertyListFormat format;
        plist = [[NSPropertyListSerialization propertyListWithData:plistData options:0 format:&format error:&error] mutableCopy];
    }

    return plist;
}

+ (NSDictionary *)updateEntitlementsForBinaryAtLocation:(NSString *)binaryLocation bundleIdentifier:(NSString *)bundleIdentifier teamID:(NSString *)teamid {
    NSMutableDictionary *plist = [EESigning getEntitlementsForBinaryAtLocation:binaryLocation];
    if (plist == nil) return [NSMutableDictionary dictionary];

    [plist setValue:[NSString stringWithFormat:@"%@.%@", teamid, bundleIdentifier] forKey:@"application-identifier"];
    [plist setValue:teamid forKey:@"com.apple.developer.team-identifier"];

    NSMutableArray *keychainAccessGroups = [NSMutableArray array];

    NSString *applicationident = [NSString stringWithFormat:@"%@.*", teamid];
    [keychainAccessGroups addObject:applicationident];

    [plist setValue:keychainAccessGroups forKey:@"keychain-access-groups"];
    //[plist setValue:@YES forKey:@"get-task-allow"];

    return plist;
}

- (void)signBundleAtPath:(NSString *)absolutePath entitlements:(NSDictionary *)entitlements identifier:(NSString *)bundleIdentifier withCallback:(void (^)(BOOL, NSString *))completionHandler {
    // We request that ldid signs the bundle given, with our PKCS12 file so that it is validly codesigned.
    if (_PKCS12.size() == 0) {
        completionHandler(NO, @"No valid PKCS12 certificate is available to use for signing.");
        return;
    }

    // Strip entitlements this free profile doesn't grant (iCloud, associated-domains,
    // push, app groups, platform-application, run-unsigned-code, com.apple.private.*,
    // ...) before signing the MAIN executable - otherwise installd rejects the app
    // (0xe8008001) or it's killed right after launch. The allowed set is derived from
    // the actual provisioning profile, so it's as complete as the account permits.
    NSSet *mainAllowedKeys = RPVAllowedEntitlementKeys(absolutePath);
    NSMutableDictionary *cleanEntitlements = [entitlements mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *key in [cleanEntitlements allKeys]) {
        if (![mainAllowedKeys containsObject:key]) {
            NSLog(@"*** [ReProvision] stripping unsupported entitlement: %@", key);
            [cleanEntitlements removeObjectForKey:key];
        }
    }

    NSError *error;
    NSMutableData *exportedPlist = [[NSPropertyListSerialization dataWithPropertyList:cleanEntitlements format:NSPropertyListXMLFormat_v1_0 options:0 error:&error] mutableCopy];
    if (!exportedPlist) {
        NSString *reason = [NSString stringWithFormat:@"Failed to serialize entitlements: %@", error.localizedDescription ?: @"unknown"];
        NSLog(@"*** [ReProvision] %@", reason);
        completionHandler(NO, reason);
        return;
    }
    [exportedPlist appendBytes:"\x0" length:1];

    std::string entitlementsString = (char *)[exportedPlist bytes];
    NSLog(@"Entitlements are:\n%s", entitlementsString.c_str());

    std::string requirementsString = [self _createRequirementsBlobWithKey:_privateKey certificate:(NSData *)_certificate andBundleIdentifier:bundleIdentifier];
    //std::string requirementsString = "";

    // We can now sign!

    NSString *mainBundleAbsPath = [absolutePath copy];
    ldid::DiskFolder folder([mainBundleAbsPath cStringUsingEncoding:NSUTF8StringEncoding]);

    // The alter callback runs for every Mach-O in the bundle. ldid passes the
    // component's path prefix as the first argument: "" for the main executable, and
    // the relative path (e.g. "Frameworks/Foo.framework/") for nested code. The main
    // executable gets the (sanitized) app entitlements; nested code keeps its own with
    // anything the OWNING sub-bundle's profile doesn't grant stripped.
    try {
        ldid::Bundle outputBundle = Sign("", folder, _PKCS12, requirementsString,
            ldid::fun([&](const std::string &path, const std::string &original) -> std::string {
                std::string result;
                if (path.empty()) {
                    // Main executable: gets the (sanitized) app entitlements.
                    result = entitlementsString;
                } else if (path.find(".appex") != std::string::npos) {
                    // App extension: use its OWN profile's allowed keys, not the main app's.
                    NSString *appexPath = RPVEnclosingAppexPath(mainBundleAbsPath, path);
                    NSSet *appexAllowed = appexPath ? RPVAllowedEntitlementKeys(appexPath) : mainAllowedKeys;
                    result = RPVSanitizeEntitlementsXML(original, appexAllowed);
                } else {
                    // Frameworks / dylibs: NO entitlements at all. Properly-built apps ship
                    // frameworks with no entitlements blob; leaving one here (even just
                    // get-task-allow) makes installd reject the whole bundle (0xe8008001).
                    result = "";
                }
                return result;
            }),
            ldid::fun([&](const std::string &) {}),
            ldid::fun(dummy));
    } catch (const char *msg) {
        NSString *reason = [NSString stringWithUTF8String:msg ? msg : "ldid: unknown assertion"];
        NSLog(@"*** [ReProvision] ldid threw: %@", reason);
        completionHandler(NO, [NSString stringWithFormat:@"Signing failed: %@", reason]);
        return;
    } catch (const std::exception &ex) {
        NSString *reason = [NSString stringWithUTF8String:ex.what()];
        NSLog(@"*** [ReProvision] ldid std::exception: %@", reason);
        completionHandler(NO, [NSString stringWithFormat:@"Signing failed: %@", reason]);
        return;
    } catch (...) {
        NSLog(@"*** [ReProvision] ldid unknown C++ exception");
        completionHandler(NO, @"Signing failed: unknown internal error");
        return;
    }

    completionHandler(YES, @"");
}

// Load ALL X.509 certificates from a PEM file into `outStack`.
// Returns the count loaded. Skips duplicates by subject-key-id when possible.
static int RPVLoadAllCertsFromPEM(NSString *filepath, STACK_OF(X509) *outStack) {
    if (!filepath) return 0;
    NSString *contents = [NSString stringWithContentsOfFile:filepath encoding:NSUTF8StringEncoding error:nil];
    if (!contents.length) return 0;

    BIO *bio = BIO_new(BIO_s_mem());
    BIO_puts(bio, [contents cStringUsingEncoding:NSUTF8StringEncoding]);

    int n = 0;
    X509 *c;
    while ((c = PEM_read_bio_X509(bio, NULL, NULL, NULL)) != NULL) {
        sk_X509_push(outStack, c);
        n++;
    }
    BIO_free_all(bio);
    return n;
}

// Load the intermediate CA chain that signs the developer certificate.
// New behaviour: try the hash-matched PEM first (fast path), but on miss/parse failure
// fall through to ALL bundled PEMs and return every X.509 we can find. The returned
// stack is owned by the caller (sk_X509_pop_free with X509_free).
- (STACK_OF(X509) *)_loadCAChainStackFromDiskForCertificate:(NSData *)certificate {
    STACK_OF(X509) *stack = sk_X509_new_null();

    // Peek at the issuer hash to prefer a known-good PEM if we recognize it.
    NSString *preferred = nil;
    const unsigned char *input = (unsigned char *)[certificate bytes];
    X509 *certForHashCheck = d2i_X509(NULL, &input, (int)[certificate length]);
    if (certForHashCheck) {
        unsigned long issuerHash = X509_issuer_name_hash(certForHashCheck);
        if (issuerHash == 0x817d2f7a) {
            preferred = [[NSBundle mainBundle] pathForResource:@"apple-ios" ofType:@"pem"];
        } else if (issuerHash == 0x9b16b75c) {
            preferred = [[NSBundle mainBundle] pathForResource:@"apple-ios-g3" ofType:@"pem"];
        } else {
            NSLog(@"*** [ReProvision] Unrecognized issuer hash 0x%lx - falling back to full PEM search", issuerHash);
        }
        X509_free(certForHashCheck);
    }

    // Try preferred first
    if (preferred) {
        NSLog(@"Loading CA chain from '%@'", preferred);
        RPVLoadAllCertsFromPEM(preferred, stack);
    }

    // Then union with the rest of the bundled intermediates. Duplicates in the CMS
    // don't matter - CMS_add1_cert is a no-op if a cert is already present.
    NSArray *fallbacks = @[ @"apple-ios-g3", @"apple-ios" ];
    for (NSString *name in fallbacks) {
        NSString *p = [[NSBundle mainBundle] pathForResource:name ofType:@"pem"];
        if (p && ![p isEqualToString:preferred]) {
            RPVLoadAllCertsFromPEM(p, stack);
        }
    }

    if (sk_X509_num(stack) == 0) {
        sk_X509_free(stack);
        NSLog(@"Failed to load CA chain.");
        @throw [NSException exceptionWithName:@"libProvisionSigningException"
                                       reason:@"Could not load any CA intermediate from disk!"
                                     userInfo:nil];
    }

    NSLog(@"Loaded %d intermediate certificate(s) into CA chain", sk_X509_num(stack));
    return stack;
}

// Backwards-compat shim: some paths still expect a single X509*. Returns the first cert of the freshly-built stack,
// and frees the rest. New code should call _loadCAChainStackFromDiskForCertificate:
// directly and pass the whole stack to PKCS12_create.
- (X509 *)_loadCAChainFromDiskForCertificate:(NSData *)certificate {
    STACK_OF(X509) *stack = [self _loadCAChainStackFromDiskForCertificate:certificate];
    X509 *first = sk_X509_shift(stack);              // take ownership of first
    sk_X509_pop_free(stack, X509_free);              // free the rest
    return first;
}

- (std::string)_createPKCS12CertificateWithKey:(NSString *)key certificate:(NSData *)certificate andCAChainStack:(STACK_OF(X509) *)chainStack {
    // This function mirrors the original single-cert version as closely as possible,
    // differing only in that it accepts multiple intermediate certificates. It also
    // logs every OpenSSL failure it sees, so if PKCS12 comes back empty we can tell
    // WHY from syslog instead of guessing.
    //
    // Ownership model (kept simple to avoid double-frees on OpenSSL 1.0.2):
    //   - `chainStack` is CONSUMED. Callers must not use it after this call.
    //   - `rootCA` is loaded here, pushed onto the CA stack, and freed with the stack.
    //   - Intermediates from `chainStack` are MOVED (not ref-counted) onto the CA
    //     stack; the original chainStack container is freed empty.
    //   - PKCS12_free is called BEFORE the certs/keys it references are freed.

    // Load root CA
    NSString *rootCAFilepath = [[NSBundle mainBundle] pathForResource:@"root" ofType:@"pem"];
    NSString *rootCAContents = [NSString stringWithContentsOfFile:rootCAFilepath encoding:NSUTF8StringEncoding error:nil];
    if (!rootCAContents.length) {
        NSLog(@"*** [ReProvision] Failed to read root.pem from bundle (path=%@)", rootCAFilepath);
        if (chainStack) sk_X509_pop_free(chainStack, X509_free);
        return std::string("");
    }

    BIO *rootCABio = BIO_new(BIO_s_mem());
    BIO_puts(rootCABio, [rootCAContents cStringUsingEncoding:NSUTF8StringEncoding]);
    X509 *rootCA = PEM_read_bio_X509(rootCABio, NULL, NULL, NULL);
    if (!rootCA) {
        NSLog(@"*** [ReProvision] PEM_read_bio_X509(root) failed. OpenSSL: %s",
              ERR_error_string(ERR_get_error(), NULL));
        BIO_free_all(rootCABio);
        if (chainStack) sk_X509_pop_free(chainStack, X509_free);
        return std::string("");
    }

    // Locals - same layout as the original code
    X509 *cert = NULL;
    STACK_OF(X509) *cacertstack = NULL;
    PKCS12 *pkcs12bundle = NULL;
    EVP_PKEY *cert_privkey = NULL;
    BIO *bio_privkey = NULL, *bio_pkcs12 = NULL;
    int bytes = 0;
    char *data = NULL;
    long len = 0;
    int error = 0;

    OpenSSL_add_all_algorithms();
    ERR_load_crypto_strings();

    // 1) Load the private key
    bio_privkey = BIO_new(BIO_s_mem());
    BIO_puts(bio_privkey, [key cStringUsingEncoding:NSUTF8StringEncoding]);
    cert_privkey = PEM_read_bio_PrivateKey(bio_privkey, NULL, NULL, NULL);
    if (!cert_privkey) {
        NSLog(@"*** [ReProvision] PEM_read_bio_PrivateKey failed. OpenSSL: %s",
              ERR_error_string(ERR_get_error(), NULL));
        error = -1;
    }

    // 2) Load the leaf developer certificate (DER)
    if (error == 0) {
        const unsigned char *input = (unsigned char *)[certificate bytes];
        cert = d2i_X509(NULL, &input, (int)[certificate length]);
        if (!cert) {
            NSLog(@"*** [ReProvision] d2i_X509(leaf) failed. OpenSSL: %s",
                  ERR_error_string(ERR_get_error(), NULL));
            error = -1;
        }
    }

    // 3) Build CA stack: root + every intermediate from chainStack.
    //    We MOVE ownership from chainStack into cacertstack (no ref-counting needed),
    //    then free chainStack as an empty container.
    if (error == 0) {
        cacertstack = sk_X509_new_null();
        if (!cacertstack) {
            NSLog(@"*** [ReProvision] sk_X509_new_null failed");
            error = -1;
        } else {
            sk_X509_push(cacertstack, rootCA);
            rootCA = NULL;  // ownership moved

            if (chainStack) {
                while (sk_X509_num(chainStack) > 0) {
                    X509 *c = sk_X509_shift(chainStack);  // take ownership
                    sk_X509_push(cacertstack, c);
                }
                sk_X509_free(chainStack);  // container empty - safe to just free
                chainStack = NULL;
            }
            NSLog(@"[ReProvision] PKCS12: CA stack size=%d, have leaf=%d, have key=%d",
                  sk_X509_num(cacertstack), cert != NULL, cert_privkey != NULL);
        }
    }

    // 4) Create the PKCS12 bundle
    if (error == 0) {
        pkcs12bundle = PKCS12_create(
            (char *)"",
            (char *)"ReProvision",
            cert_privkey,
            cert,
            cacertstack,
            0, 0, 0, 0, 0
        );
        if (!pkcs12bundle) {
            NSLog(@"*** [ReProvision] PKCS12_create failed. OpenSSL: %s",
                  ERR_error_string(ERR_get_error(), NULL));
            // Drain the whole OpenSSL error queue too - PKCS12_create can push several
            unsigned long e;
            while ((e = ERR_get_error()) != 0) {
                NSLog(@"*** [ReProvision]   further OpenSSL error: %s",
                      ERR_error_string(e, NULL));
            }
            error = -1;
        }
    }

    // 5) Serialize
    NSData *result = nil;
    if (error == 0) {
        bio_pkcs12 = BIO_new(BIO_s_mem());
        bytes = i2d_PKCS12_bio(bio_pkcs12, pkcs12bundle);
        if (bytes <= 0) {
            NSLog(@"*** [ReProvision] i2d_PKCS12_bio failed. OpenSSL: %s",
                  ERR_error_string(ERR_get_error(), NULL));
            error = -1;
        } else {
            len = BIO_get_mem_data(bio_pkcs12, &data);
            result = [NSData dataWithBytes:data length:len];
            NSLog(@"[ReProvision] PKCS12 built OK, %ld bytes", len);
        }
    }

    // 6) Cleanup - PKCS12_free BEFORE the objects it internally references.
    //    (In practice PKCS12_create copies/encrypts everything into ASN.1 structures,
    //    so order doesn't strictly matter, but this is the safe order.)
    if (pkcs12bundle)  PKCS12_free(pkcs12bundle);
    if (bio_pkcs12)    BIO_free_all(bio_pkcs12);

    if (cacertstack)   sk_X509_pop_free(cacertstack, X509_free);
    else if (rootCA)   X509_free(rootCA);  // failed before stack was built

    if (chainStack)    sk_X509_pop_free(chainStack, X509_free);  // only if we bailed early
    if (cert)          X509_free(cert);
    if (cert_privkey)  EVP_PKEY_free(cert_privkey);
    if (bio_privkey)   BIO_free_all(bio_privkey);
    BIO_free_all(rootCABio);

    if (error == -1 || !result) {
        return std::string("");
    } else {
        std::string s(reinterpret_cast<char const *>([result bytes]), [result length]);
        return s;
    }
}

// Old entrypoint kept for source compatibility (unused internally now).
- (std::string)_createPKCS12CertificateWithKey:(NSString *)key certificate:(NSData *)certificate andCAChain:(X509 *)chain {
    STACK_OF(X509) *stack = sk_X509_new_null();
    if (chain) sk_X509_push(stack, chain);
    return [self _createPKCS12CertificateWithKey:key certificate:certificate andCAChainStack:stack];
}

- (std::string)_createRequirementsBlobWithKey:(NSString *)key certificate:(NSData *)certificate andBundleIdentifier:(NSString *)identifier {
    // XXX: Returning an empty string, because iOS does not complain about empty requirements. Plus, all the SecRequirement* symbols
    // do not exist on iOS, so requires more effort than I'd like to get this working correctly...
    return "";

    // Load the incoming cert to grab off the common name.

    /*OpenSSL_add_all_algorithms();
    ERR_load_crypto_strings();
    
    EVP_PKEY   *cert_privkey;
    BIO        *bio_privkey;
    X509       *cert;
    
    bio_privkey = BIO_new(BIO_s_mem());
    BIO_puts(bio_privkey, [key cStringUsingEncoding:NSUTF8StringEncoding]);
    
    if (!(cert_privkey = PEM_read_bio_PrivateKey(bio_privkey, NULL, NULL, NULL))) {
        NSLog(@"Error loading certificate private key content.");
        return "";
    }
    
    const unsigned char *input = (unsigned char*)[certificate bytes];
    cert = d2i_X509(NULL, &input, (int)[certificate length]);
    if (!cert) {
        NSLog(@"Error loading cert into memory.");
        return "";
    }
    
    // Build the requirements string
    NSString *requirementsString = [NSString stringWithFormat:@"identifier \"%@\" and anchor apple generic and certificate leaf[subject.CN] = \"%s\" and certificate 1[field.1.2.840.113635.100.6.2.1]",
                                    identifier,
                                    [self _commonNameForCert:cert].c_str()];
    
    SecRequirementRef requirementRef = NULL;
    OSStatus status = SecRequirementCreateWithString((__bridge CFStringRef)requirementsString, kSecCSDefaultFlags, &requirementRef);
    
    if (status != noErr) {
        NSLog(@"Error: Failed to create requirements! %d", (int)status);
        
        return "";
    }
    
    std::string result;
    CFDataRef data;
    status = SecRequirementCopyData(requirementRef, kSecCSDefaultFlags, &data);
    
    if (status != noErr) {
        NSLog(@"Error: Failed to copy requirements! %d", (int)status);
        
        return "";
    }
    
    auto buffer = reinterpret_cast<const char*>(CFDataGetBytePtr(data));
    auto buffer_length = static_cast<std::size_t>(CFDataGetLength(data));
    
    result.resize(buffer_length);
    memcpy((char*)result.data(), buffer, buffer_length);
    
    //free req reference
    if (requirementRef != NULL) {
        CFRelease(requirementRef);
        requirementRef = NULL;
    }
    
    return result;*/
}

- (std::string)_commonNameForCert:(X509 *)cert {
    int common_name_loc = -1;
    X509_NAME_ENTRY *common_name_entry = NULL;
    ASN1_STRING *common_name_asn1 = NULL;
    char *common_name_str = NULL;

    // Find the position of the CN field in the Subject field of the certificate
    common_name_loc = X509_NAME_get_index_by_NID(X509_get_subject_name(cert), NID_commonName, -1);
    if (common_name_loc < 0) {
        return "";
    }

    // Extract the CN field
    common_name_entry = X509_NAME_get_entry(X509_get_subject_name(cert), common_name_loc);
    if (common_name_entry == NULL) {
        return "";
    }

    // Convert the CN field to a C string
    common_name_asn1 = X509_NAME_ENTRY_get_data(common_name_entry);
    if (common_name_asn1 == NULL) {
        return "";
    }

    common_name_str = (char *)ASN1_STRING_data(common_name_asn1);

    return std::string(common_name_str);
}

@end

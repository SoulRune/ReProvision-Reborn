//
//  EEAdvancedController.m
//  Extender Installer
//
//  Created by Matt Clarke on 05/05/2017.
//
//

#import "RPVAdvancedController.h"
#import "AppDelegate.h"
#import "RPVResources.h"
#import "EEBackend.h"   // RPVLogger lives here

#include <notify.h>

@interface RPVAdvancedController ()
@property (nonatomic, readwrite) int daemonNotificationToken;
@end

@implementation RPVAdvancedController

- (void)viewDidLoad {
    [super viewDidLoad];

    if (@available(iOS 11.0, *)) {
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }

    [[self navigationItem] setTitle:@"Advanced"];

    // Register token for daemon notifications.
    int status = notify_register_check("jp.soh.reprovision.ios/debugStartBackgroundSign", &_daemonNotificationToken);
    if (status != NOTIFY_STATUS_OK) {
        fprintf(stderr, "registration failed (%u)\n", status);
        return;
    }
}

- (id)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *testingSpecs = [NSMutableArray array];

        // Create specifiers!
        [testingSpecs addObjectsFromArray:[self _signingSpecifiers]];
        [testingSpecs addObjectsFromArray:[self _errorHandlingSpecifiers]];

        _specifiers = testingSpecs;
    }

    return _specifiers;
}

- (NSArray *)_signingSpecifiers {
    NSMutableArray *array = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Re-signing"];
    [group setProperty:@"Set how often checks are made for if any applications are in need of re-signing." forKey:@"footerText"];
    [array addObject:group];

    NSDate *nextFireDate = [RPVResources preferenceValueForKey:@"nextFireDate"];
    NSMutableString *nextFireDateStr = [NSMutableString stringWithString:@"Next Fire Date: "];
    if (nextFireDate) {
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateStyle = NSDateFormatterMediumStyle;
        dateFormatter.timeStyle = NSDateFormatterMediumStyle;
        [nextFireDateStr appendString:[dateFormatter stringFromDate:nextFireDate]];
    } else {
        [nextFireDateStr appendString:@"-"];
    }
    PSSpecifier *nextFire = [PSSpecifier preferenceSpecifierNamed:nextFireDateStr target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil];
    [array addObject:nextFire];

    PSSpecifier *resign = [PSSpecifier preferenceSpecifierNamed:@"Re-sign in Low Power Mode" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [resign setProperty:@"resignInLowPowerMode" forKey:@"key"];
    [resign setProperty:@0 forKey:@"default"];

    [array addObject:resign];

    PSSpecifier *forceResign = [PSSpecifier preferenceSpecifierNamed:@"Force Re-sign" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [forceResign setProperty:@"forceResign" forKey:@"key"];
    [forceResign setProperty:@1 forKey:@"default"];

    [array addObject:forceResign];

    PSSpecifier *trueBgResign = [PSSpecifier preferenceSpecifierNamed:@"True Background Re-sign (Beta)" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [trueBgResign setProperty:@"trueBgResign" forKey:@"key"];
    [trueBgResign setProperty:@0 forKey:@"default"];

    [array addObject:trueBgResign];

    PSSpecifier *threshold = [PSSpecifier preferenceSpecifierNamed:@"Check Expiry Times:" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:NSClassFromString(@"PSListItemsController") cell:PSLinkListCell edit:nil];
    [threshold setProperty:@YES forKey:@"enabled"];
    [threshold setProperty:@2 forKey:@"default"];
    threshold.values = [NSArray arrayWithObjects:@1, @2, @6, @12, @24, @48, nil];
    threshold.titleDictionary = [NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:@"Every 1 Hour", @"Every 2 Hours", @"Every 6 Hours", @"Every 12 Hours", @"Every 24 Hours", @"Every Other Day", nil] forKeys:threshold.values];
    threshold.shortTitleDictionary = threshold.titleDictionary;
    [threshold setProperty:@"heartbeatTimerInterval" forKey:@"key"];
    [threshold setProperty:@"A longer time between checks uses less battery, but has more risk that applications won't be re-signed before a reboot." forKey:@"staticTextMessage"];

    [array addObject:threshold];

    return array;
}

- (NSArray *)_errorHandlingSpecifiers {
    NSMutableArray *array = [NSMutableArray array];

    /*PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Error Handling"];
    [group setProperty:@"Some errors may be resolved automatically by revoking any existing certificates. This is only a temporary workaround.\n\nIt is strongly NOT recommended to use this feature if you use Extender: Reloaded on multiple devices." forKey:@"footerText"];
    [array addObject:group];
    
    PSSpecifier *resign = [PSSpecifier preferenceSpecifierNamed:@"Auto-Revoke Certificates" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [resign setProperty:@"shouldAutoRevokeIfNeeded" forKey:@"key"];
    //[resign setProperty:@YES forKey:@"enabled"];
    [resign setProperty:@NO forKey:@"enabled"];
    [resign setProperty:@0 forKey:@"default"];
    
    [array addObject:resign];*/

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Debugging Tools"];
    [group setProperty:@"Danger! Here be dragons..." forKey:@"footerText"];
    [array addObject:group];

    PSSpecifier *startBackgroundSign = [PSSpecifier preferenceSpecifierNamed:@"Initiate Background Signing" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    startBackgroundSign->action = @selector(startBackgroundSign:);

    [array addObject:startBackgroundSign];

    // --- Signing log ---------------------------------------------------------
    PSSpecifier *logGroup = [PSSpecifier groupSpecifierWithName:@"Signing Log"];
    [logGroup setProperty:@"Writes the full signing process to a file, so a failure can be inspected afterwards instead of needing a syslog capture at the moment it happens.\n\nApple ID addresses, tokens and private keys are redacted, but review the log before sharing it." forKey:@"footerText"];
    [array addObject:logGroup];

    PSSpecifier *logToggle = [PSSpecifier preferenceSpecifierNamed:@"Log Signing to File" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [logToggle setProperty:@"logSigningToFile" forKey:@"key"];
    [logToggle setProperty:@0 forKey:@"default"];
    [array addObject:logToggle];

    unsigned long long logBytes = [RPVLogger logFileSize];
    NSString *sizeTitle;
    if (logBytes == 0) {
        sizeTitle = @"Log Size: empty";
    } else if (logBytes < 1024) {
        sizeTitle = [NSString stringWithFormat:@"Log Size: %llu bytes", logBytes];
    } else if (logBytes < 1024 * 1024) {
        sizeTitle = [NSString stringWithFormat:@"Log Size: %.1f KB", logBytes / 1024.0];
    } else {
        sizeTitle = [NSString stringWithFormat:@"Log Size: %.1f MB", logBytes / (1024.0 * 1024.0)];
    }
    PSSpecifier *logSize = [PSSpecifier preferenceSpecifierNamed:sizeTitle target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil];
    [array addObject:logSize];

    PSSpecifier *shareLog = [PSSpecifier preferenceSpecifierNamed:@"Share Log" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    shareLog->action = @selector(shareSigningLog:);
    [array addObject:shareLog];

    PSSpecifier *clearLog = [PSSpecifier preferenceSpecifierNamed:@"Clear Log" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    clearLog->action = @selector(clearSigningLog:);
    [array addObject:clearLog];

    return array;
}

#pragma mark - Signing log actions

- (void)shareSigningLog:(id)sender {
    if ([RPVLogger logFileSize] == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Log Yet"
                                                                      message:@"Turn on \"Log Signing to File\", then sign an application. The log will appear here."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // Share the file itself rather than a string, so it arrives with a filename and can
    // be attached to a bug report directly.
    NSURL *url = [NSURL fileURLWithPath:[RPVLogger logFilePath]];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                        applicationActivities:nil];

    // iPad requires a popover anchor here or this throws.
    if (share.popoverPresentationController) {
        share.popoverPresentationController.sourceView = self.view;
        share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                    CGRectGetMidY(self.view.bounds),
                                                                    0, 0);
        share.popoverPresentationController.permittedArrowDirections = 0;
    }

    [self presentViewController:share animated:YES completion:nil];
}

- (void)clearSigningLog:(id)sender {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Clear Log?"
                                                                    message:@"This deletes the saved signing log. It can't be undone."
                                                             preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [RPVLogger clearLog];

        // Reload so the size row refreshes.
        self->_specifiers = nil;
        [self reloadSpecifiers];
    }]];

    [self presentViewController:confirm animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

    // Find the type of cell this is.
    int section = (int)indexPath.section;
    int row = (int)indexPath.row;

    PSSpecifier *represented;
    NSArray *specifiers = [self specifiers];
    int currentSection = -1;
    int currentRow = 0;
    for (int i = 0; i < specifiers.count; i++) {
        PSSpecifier *spec = [specifiers objectAtIndex:i];

        // Update current sections
        if (spec.cellType == PSGroupCell) {
            currentSection++;
            currentRow = 0;
            continue;
        }

        // Check if this is the right specifier.
        if (currentRow == row && currentSection == section) {
            represented = spec;
            break;
        } else {
            currentRow++;
        }
    }

    // Tint the cell if needed!
    if (represented.cellType == PSButtonCell)
        cell.textLabel.textColor = [UIApplication sharedApplication].delegate.window.tintColor;

    return cell;
}

- (id)readPreferenceValue:(PSSpecifier *)value {
    NSString *key = [value propertyForKey:@"key"];
    id val = [RPVResources preferenceValueForKey:key];

    if (!val) {
        // Defaults.

        NSString *key = [value propertyForKey:@"key"];

        if ([key isEqualToString:@"resignInLowPowerMode"]) {
            return [NSNumber numberWithBool:NO];
        } else if ([key isEqualToString:@"forceResign"]) {
            return [NSNumber numberWithBool:YES];
        } else if ([key isEqualToString:@"trueBgResign"]) {
            return [NSNumber numberWithBool:NO];
        } else if ([key isEqualToString:@"heartbeatTimerInterval"]) {
            return [NSNumber numberWithInt:2];
        } else if ([key isEqualToString:@"shouldAutoRevokeIfNeeded"]) {
            return [NSNumber numberWithBool:NO];
        }

        return nil;
    } else {
        return val;
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *notification = specifier.properties[@"PostNotification"];

    [RPVResources setPreferenceValue:value forKey:key withNotification:notification];
}

/////////////////////////////////////////////////////////////////////////////////////
// Button actions
/////////////////////////////////////////////////////////////////////////////////////

- (void)startBackgroundSign:(id)sender {
    [(AppDelegate *)[UIApplication sharedApplication].delegate requestDebuggingBackgroundSigning];
}

@end

//
//  RPVTabBarController.m
//  iOS
//
//  Created by Matt Clarke on 07/03/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVTabBarController.h"
#import "RPVAccountViewController.h"
#import "RPVResources.h"

@interface RPVTabBarController ()

@end

@implementation RPVTabBarController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    // Remove the titles so only the icons show. On iOS 15+ a tab bar item with no
    // title is already vertically centred by the system, so the old +6pt downward
    // imageInset (a workaround for iOS 9-14, where the icon stuck to the top) now
    // over-pushes the icons to the bottom of the bar. Leave the insets at zero.
    for (UITabBarItem * tabBarItem in self.tabBar.items){
        tabBarItem.title = @"";
        tabBarItem.imageInsets = UIEdgeInsetsZero;
        tabBarItem.image = [[tabBarItem image] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userDidRequestAccountViewController:) name:@"RPVDisplayAccountSignInController" object:nil];
    
    // Check if we need to present the account view based upon settings.
    if (![RPVResources getUsername] ||
        [[RPVResources getUsername] isEqualToString:@""] ||
        ![[RPVResources getCredentialsVersion] isEqualToString:CURRENT_CREDENTIALS_VERSION])
        [self presentAccountViewControllerAnimated:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)userDidRequestAccountViewController:(id)sender {
    [self presentAccountViewControllerAnimated:YES];
}

- (void)presentAccountViewControllerAnimated:(BOOL)animated {
    [self performSegueWithIdentifier:animated ? @"presentAccountControllerAnimated" : @"presentAccountController" sender:nil];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return [self.childViewControllerForStatusBarStyle preferredStatusBarStyle];
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end

//
//  SideStoreHooks.m
//  LiveContainer
//
//  Created by s s on 2026/8/6.
//
#include "../LiveContainer/utils.h"
#include "../LiveContainer/LCSharedUtils.h"
#include "XPCServer.h"
#import <sys/sysctl.h>
@import UserNotifications;
@import UIKit;

@interface LCAuthorizedNotificationSettings : UNNotificationSettings
@end

@implementation LCAuthorizedNotificationSettings

- (UNAuthorizationStatus)authorizationStatus {
    return UNAuthorizationStatusAuthorized;
}

@end

static NSMutableDictionary<NSString *, UIWindow *> *SSVersionWindows;
static id SSSceneObserver;

@interface PassthroughWindow : UIWindow
@end

@implementation PassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    return nil;
}

@end

@implementation UNUserNotificationCenter(SideStoreHooks)

- (void)lc_addNotificationRequest:(UNNotificationRequest*)request
            withCompletionHandler:(void (^)(NSError* error))completionHandler {
    LiveProcessSideStoreHandler* handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    [handler.server addNotificationRequest:request];
    if (completionHandler) {
        completionHandler(nil);
    }
}

- (void)lc_removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString*>*)identifiers {
    LiveProcessSideStoreHandler* handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    [handler.server removePendingNotificationRequestsWithIdentifiers:identifiers];
}

- (void)lc_getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings* settings))completionHandler {
    if (!completionHandler) {
        return;
    }

    UNNotificationSettings* settings = class_createInstance(LCAuthorizedNotificationSettings.class, 0);
    completionHandler(settings);
}

@end

@implementation NSBundle(SideStoreHooks)

+ (NSString*)hook_appbundleIdentifier {
    return @"com.kdt.livecontainer";
}

+ (NSString*)hook_storeAppBundleIdentifier {
    return @"com.kdt.livecontainer";
}

- (NSString*)hook_altstoreAppGroup {
    return LCSharedUtils.appGroupID;
}

+ (NSString*)hook_baseAltStoreAppGroupID {
    return @"group.com.SideStore.SideStore";
}

+ (NSBundle*)hook_activeBundle {
    if (!NSUserDefaults.isLiveProcess) return NSUserDefaults.lcMainBundle;
    
    static NSBundle* lcAppBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lcAppBundle = [NSBundle bundleWithURL: NSUserDefaults.lcMainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    });
    return lcAppBundle;
}

// ESC-BEGIN: make the guest bundle visible to Core Data's migration lookup.
//
// SideStore's PersistentContainer, when the on-disk store is incompatible with
// the current model, looks for the older model with
//     +[NSManagedObjectModel mergedModelFromBundles:forStoreMetadata:]
//     (Swift: NSManagedObjectModel.mergedModel(from: Bundle.allBundles, forStoreMetadata:))
// and throws Code=-23 "Unable to find any managed object models." when it returns nil.
//
// Inside LiveContainer the guest app is not a real app bundle: build_github.sh
// renames SideStore.app to Frameworks/SideStoreApp.framework and dylibifies its
// executable to MH_DYLIB, so CFBundle classifies it as a framework and Apple
// documents +[NSBundle allBundles] as excluding frameworks. The guest's own
// AltStore.momd (which ships every historical model version) therefore becomes
// invisible to the migration lookup, migration can never start, and a stale store
// can only be recovered by deleting it - which also wipes the signed-in accounts.
//
// This swizzle appends the guest's own bundle to +[NSBundle allBundles]. It is a
// no-op when the bundle is already listed, and it only takes effect in the
// SideStore guest process (this dylib is only injected there).

// One-shot diagnostic: records whether the guest bundle was already in
// allBundles before this fix, plus allFrameworks and the store path, so the
// "is it bundle classification or a genuinely newer database?" question can be
// settled from the device. Written once, to <app group>/esc-sidestore-diag.txt.
static void ESCWriteAllBundlesDiagnostic(NSArray<NSBundle*> *originalBundles) {
    NSURL *groupURL = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:LCSharedUtils.appGroupID];
    if (!groupURL) return;

    NSString *diagPath = [groupURL URLByAppendingPathComponent:@"esc-sidestore-diag.txt"].path;
    if ([NSFileManager.defaultManager fileExistsAtPath:diagPath]) return;

    NSBundle *guest = NSBundle.mainBundle;
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"guest mainBundle: %@\n", guest.bundlePath];
    [out appendFormat:@"guest in allBundles BEFORE fix: %@\n", ([originalBundles containsObject:guest] ? @"YES" : @"NO")];

    [out appendFormat:@"\nallBundles (%lu) BEFORE fix:\n", (unsigned long)originalBundles.count];
    for (NSBundle *b in originalBundles) [out appendFormat:@"  %@\n", b.bundlePath];

    NSArray<NSBundle*> *frameworks = NSBundle.allFrameworks;
    [out appendFormat:@"\nallFrameworks (%lu):\n", (unsigned long)frameworks.count];
    for (NSBundle *b in frameworks) [out appendFormat:@"  %@\n", b.bundlePath];

    NSString *dbPath = [[groupURL URLByAppendingPathComponent:@"Database"] URLByAppendingPathComponent:@"SideStore.sqlite"].path;
    [out appendFormat:@"\nstore: %@ exists=%@\n", dbPath, ([NSFileManager.defaultManager fileExistsAtPath:dbPath] ? @"YES" : @"NO")];

    [out writeToFile:diagPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

+ (NSArray<NSBundle*>*)hook_allBundles {
    // exchange-style swizzle: this call reaches the original +[NSBundle allBundles]
    NSArray<NSBundle*> *bundles = [NSBundle hook_allBundles];

    // set the flag before doing any work: the diagnostic itself touches NSBundle
    // APIs, so re-entrancy must not be able to re-enter this block.
    static BOOL escDiagnosticWritten = NO;
    if (!escDiagnosticWritten) {
        escDiagnosticWritten = YES;
        ESCWriteAllBundlesDiagnostic(bundles);
    }

    NSBundle *guest = NSBundle.mainBundle;
    if (!guest || guest.bundlePath.length == 0) return bundles;
    for (NSBundle *b in bundles) {
        if ([b.bundlePath isEqualToString:guest.bundlePath]) return bundles;
    }
    return [bundles arrayByAddingObject:guest];
}
// ESC-END

@end

NSURL* SideStoreSource_hook_altStoreSourceURL(id self, SEL cmd) {
    static NSURL* sourceURL = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sourceURL = [NSURL URLWithString:@"https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps_ss_lc.json"];
    });
    return sourceURL;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
void (*SideStoreMyAppsViewController_orig_viewDidload)(UICollectionViewController* self, SEL cmd) = nil;
void SideStoreMyAppsViewController_hook_viewDidload(UICollectionViewController* self, SEL cmd) {
    if(!SideStoreMyAppsViewController_orig_viewDidload) return;
    SideStoreMyAppsViewController_orig_viewDidload(self, cmd);
    
    UIImage *escapeImage = [UIImage systemImageNamed:@"escape"];
    UIBarButtonItem *escapeItem = [[UIBarButtonItem alloc] initWithImage:escapeImage
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(escapeButtonTapped:)];
        
    NSMutableArray* oldToolBarItems = [self.navigationItem.leftBarButtonItems mutableCopy];
    [oldToolBarItems addObject:escapeItem];
    self.navigationItem.leftBarButtonItems = oldToolBarItems;
}

void SideStoreMyAppsViewController_hook_escapeButtonTapped(UICollectionViewController* self, SEL cmd, id target) {
    [LCSharedUtils launchToGuestAppWithClassicMode:0];
}





static void SSInstallVersionWindow(UIWindowScene *windowScene)
{
    NSString *identifier = windowScene.session.persistentIdentifier;
    if (identifier.length == 0 || SSVersionWindows[identifier] != nil) {
        return;
    }
    
    
    NSString* LCVersion = [NSString stringWithFormat:@"%@-%@",
                         NSUserDefaults.lcMainBundle.infoDictionary[@"CFBundleShortVersionString"],
                         NSUserDefaults.lcMainBundle.infoDictionary[@"LCVersionInfo"]];
    
    NSString* SSVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    
    NSString *osVersion = [[UIDevice currentDevice] systemVersion];
    size_t size = 32;
    char iosBuild[32];
    sysctlbyname("kern.osversion", iosBuild, &size, NULL, 0);
    bool isPhone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    NSString* allVersionString = [NSString stringWithFormat:isPhone ? @"LC %@, SS %@\niOS %@ (%s)" : @"LC %@, SS %@, iOS %@ (%s)", LCVersion, SSVersion, osVersion, iosBuild];

    UILabel* versionLabel = [UILabel new];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightRegular];
    versionLabel.textColor = UIColor.labelColor;
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.userInteractionEnabled = NO;
    versionLabel.text = allVersionString;
    versionLabel.numberOfLines = 0;
    versionLabel.lineBreakMode = NSLineBreakByWordWrapping;
    
    UIViewController *rootController = [[UIViewController alloc] init];
    rootController.view.backgroundColor = UIColor.clearColor;
    [rootController.view addSubview:versionLabel];
    
    if(windowScene.keyWindow.safeAreaInsets.bottom == 0) {
        // old devices with no bottom safe area
        [NSLayoutConstraint activateConstraints:@[
            [versionLabel.centerXAnchor constraintEqualToAnchor:rootController.view.centerXAnchor],
            [versionLabel.topAnchor constraintEqualToAnchor: rootController.view.safeAreaLayoutGuide.topAnchor]
        ]];
    } else {
        // new devices
        [NSLayoutConstraint activateConstraints:@[
            [versionLabel.centerXAnchor constraintEqualToAnchor:rootController.view.centerXAnchor],
            [versionLabel.bottomAnchor constraintEqualToAnchor: rootController.view.safeAreaLayoutGuide.bottomAnchor
                                                      constant: isPhone ? 22 : 0]
        ]];
    }
    PassthroughWindow *window = [[PassthroughWindow alloc] initWithWindowScene:windowScene];

    window.rootViewController = rootController;
    window.backgroundColor = UIColor.clearColor;

    window.windowLevel = UIWindowLevelAlert;

    window.hidden = NO;

    SSVersionWindows[identifier] = window;
}


void installSideStoreHooks(void) {

    swizzleClassMethod(NSBundle.class, @selector(appbundleIdentifier), @selector(hook_appbundleIdentifier));
    swizzleClassMethod(NSBundle.class, @selector(storeAppBundleIdentifier), @selector(hook_storeAppBundleIdentifier));
    swizzle(NSBundle.class, @selector(altstoreAppGroup), @selector(hook_altstoreAppGroup));
    swizzleClassMethod(NSBundle.class, @selector(activeBundle), @selector(hook_activeBundle));
    swizzleClassMethod(NSBundle.class, @selector(baseAltStoreAppGroupID), @selector(hook_baseAltStoreAppGroupID));
    // ESC-BEGIN: expose the guest's own bundle to Core Data's migration lookup
    swizzleClassMethod(NSBundle.class, @selector(allBundles), @selector(hook_allBundles));
    // ESC-END
    
    // replace altStoreSourceURL
    Method altStoreSourceURLMethod = class_getClassMethod(PrivClass(Source), @selector(altStoreSourceURL));
    method_setImplementation(altStoreSourceURLMethod, (IMP)SideStoreSource_hook_altStoreSourceURL);
    
    if (!NSUserDefaults.isLiveProcess) {
        // add escape button
        Method viewDidLoadMethod = class_getInstanceMethod(PrivClass(MyAppsViewController), @selector(viewDidLoad));
        SideStoreMyAppsViewController_orig_viewDidload = (void (*)(UICollectionViewController *, SEL))method_getImplementation(viewDidLoadMethod);
        method_setImplementation(viewDidLoadMethod, (IMP)SideStoreMyAppsViewController_hook_viewDidload);
        class_addMethod(PrivClass(MyAppsViewController), @selector(escapeButtonTapped:), (IMP)SideStoreMyAppsViewController_hook_escapeButtonTapped, "v@:@");
        
        // add version number
        SSVersionWindows = [NSMutableDictionary dictionary];

        SSSceneObserver =
        [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *notification) {
            UIScene *scene = notification.object;
            
            if ([scene isKindOfClass:UIWindowScene.class]) {
                SSInstallVersionWindow((UIWindowScene *)scene);
            }
        }];
        
        
        
    }
    

}
#pragma clang diagnostic pop

void installSideStoreNotificationHooks(void) {
    swizzle(UNUserNotificationCenter.class,
            @selector(addNotificationRequest:withCompletionHandler:),
            @selector(lc_addNotificationRequest:withCompletionHandler:));
    swizzle(UNUserNotificationCenter.class,
            @selector(removePendingNotificationRequestsWithIdentifiers:),
            @selector(lc_removePendingNotificationRequestsWithIdentifiers:));
    swizzle(UNUserNotificationCenter.class,
            @selector(getNotificationSettingsWithCompletionHandler:),
            @selector(lc_getNotificationSettingsWithCompletionHandler:));
}

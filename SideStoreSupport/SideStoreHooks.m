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
// ESC: Core Data is needed to read the guest's AltStore.momd and the on-disk
// store metadata. Autolinking is already relied upon in this file for
// UserNotifications/UIKit (neither is listed in the project's Frameworks
// phase), so `@import CoreData;` adds no manual link step.
@import CoreData;

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

// ESC-BEGIN: deterministic app group resolution for the SideStore guest.
//
// Upstream +[LCSharedUtils appGroupID] (LiveContainer/LCSharedUtils.m) picks
// between
//     group.com.SideStore.SideStore.<teamId>
//     group.com.rileytestut.AltStore.<teamId>
// preferring whichever already contains an "Apps" directory, and falls back to
// @"Unknown" when neither yields a container URL. It is dispatch_once-cached
// per process but NOT remembered across launches, so the picked group can
// change between launches. SideStore keys its Core Data store off
// +[NSBundle altstoreAppGroup], so a change makes it look at a different
// Database/SideStore.sqlite (user appears signed out), and @"Unknown" makes
// containerURLForSecurityApplicationGroupIdentifier: return nil so SideStore
// silently falls back to a brand new private empty store. Both present as
// "my account disappeared".
//
// This shim pins the value: the group that worked last time is remembered and
// reused, the two upstream candidates are tried in upstream's order, and when
// nothing is usable we log loudly and still return a real candidate so that
// SideStore fails visibly instead of silently creating an empty store.
// LCSharedUtils itself is deliberately left untouched (upstream file).

static NSString * const ESCStableAppGroupKey = @"ESCStableAppGroupID";
static NSString * const ESCUnknownAppGroup = @"Unknown";

// The remembered group is stored in the shared (app group) defaults, and also
// mirrored into standardUserDefaults. The shared defaults' suite name is itself
// derived from +[LCSharedUtils appGroupID] (LiveContainer/LCBootstrap.m), i.e.
// it moves together with the very value we are trying to pin, so it cannot be
// the only copy. standardUserDefaults does not depend on the app group and
// therefore survives such a flip.
static NSString *ESCReadStableAppGroup(void) {
    NSString *value = [NSUserDefaults.lcSharedDefaults stringForKey:ESCStableAppGroupKey];
    if (value.length) return value;
    return [NSUserDefaults.standardUserDefaults stringForKey:ESCStableAppGroupKey];
}

static void ESCRememberStableAppGroup(NSString *groupID) {
    [NSUserDefaults.lcSharedDefaults setObject:groupID forKey:ESCStableAppGroupKey];
    [NSUserDefaults.standardUserDefaults setObject:groupID forKey:ESCStableAppGroupKey];
    [NSUserDefaults.lcSharedDefaults synchronize];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static BOOL ESCAppGroupIsUsable(NSString *groupID) {
    if (groupID.length == 0) return NO;
    if ([groupID isEqualToString:ESCUnknownAppGroup]) return NO;
    return [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:groupID] != nil;
}

// Upstream candidate order. teamIdentifier can be nil on some jailbreaks, in
// which case the "<base>.<teamId>" ids cannot be built at all.
static NSArray<NSString *> *ESCCandidateAppGroups(void) {
    NSString *team = LCSharedUtils.teamIdentifier;
    if (team.length == 0) return @[];
    return @[
        [@"group.com.SideStore.SideStore." stringByAppendingString:team],
        [@"group.com.rileytestut.AltStore." stringByAppendingString:team],
    ];
}

static NSString *ESCResolveStableAppGroup(void) {
    static NSString *resolved = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. reuse the group that worked on a previous launch, if still usable
        NSString *remembered = ESCReadStableAppGroup();
        if (ESCAppGroupIsUsable(remembered)) {
            resolved = remembered;
            NSLog(@"[ESC] app group: reusing remembered %@", remembered);
            return;
        }

        NSArray<NSString *> *candidates = ESCCandidateAppGroups();

        // 2. upstream's first choice: a candidate that already holds "Apps"
        for (NSString *group in candidates) {
            NSURL *url = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if (!url) continue;
            if ([NSFileManager.defaultManager fileExistsAtPath:[url URLByAppendingPathComponent:@"Apps"].path]) {
                resolved = group;
                break;
            }
        }

        // 3. otherwise the first candidate that at least yields a container URL
        if (!resolved) {
            for (NSString *group in candidates) {
                if (ESCAppGroupIsUsable(group)) {
                    resolved = group;
                    break;
                }
            }
        }

        // 4. otherwise whatever LCSharedUtils managed to resolve
        if (!resolved && ESCAppGroupIsUsable(LCSharedUtils.appGroupID)) {
            resolved = LCSharedUtils.appGroupID;
        }

        if (resolved) {
            ESCRememberStableAppGroup(resolved);
            NSLog(@"[ESC] app group: resolved %@ (remembered for next launch)", resolved);
        } else {
            // Nothing usable: return the primary candidate anyway. SideStore then
            // fails to open its container instead of silently creating a private
            // empty store, which is easier to diagnose and never loses data.
            resolved = candidates.firstObject ?: LCSharedUtils.appGroupID;
            NSLog(@"[ESC] ERROR: no usable app group container (candidates=%@, teamIdentifier=%@, "
                  @"LCSharedUtils.appGroupID=%@); returning %@ so SideStore fails visibly instead of "
                  @"falling back to a private empty store",
                  candidates, LCSharedUtils.teamIdentifier, LCSharedUtils.appGroupID, resolved);
        }
    });
    return resolved;
}
// ESC-END

@implementation NSBundle(SideStoreHooks)

+ (NSString*)hook_appbundleIdentifier {
    return @"com.kdt.livecontainer";
}

+ (NSString*)hook_storeAppBundleIdentifier {
    return @"com.kdt.livecontainer";
}

// ESC-BEGIN: pin the app group so the guest's Database/SideStore.sqlite (and
// therefore the signed-in accounts) is always found at the same path.
- (NSString*)hook_altstoreAppGroup {
    return ESCResolveStableAppGroup();
}
// ESC-END

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
// NOTE: the on-device diagnostic below later proved that the guest bundle (and
// its AltStore.momd) is ALREADY present in +[NSBundle allBundles] even without
// this swizzle, so bundle visibility alone does not explain the -23. The swizzle
// is kept as a defensive no-op; the hash comparison in the diagnostic is what
// will settle whether the store matches any shipped model version.
//
// This swizzle appends the guest's own bundle to +[NSBundle allBundles]. It is a
// no-op when the bundle is already listed, and it only takes effect in the
// SideStore guest process (this dylib is only injected there).

// --- one-shot Core Data diagnostic ------------------------------------------
//
// Answers, from the device, the one question the -23 cannot answer by itself:
// do the store's per-entity hashes match any model version shipped in the
// guest's AltStore.momd?
//   1. every model version in the guest's AltStore.momd: versionIdentifiers and
//      per-entity hashes (hex)
//   2. the on-disk store's NSStoreModelVersionIdentifiers / ...Hashes (hex)
//   3. the result of the very lookup SideStore performs
//      (+[NSManagedObjectModel mergedModelFromBundles:forStoreMetadata:])
//   4. the app group state (resolved id, path, Apps/ and Database/ presence)
// Written once, to <app group>/esc-sidestore-diag.txt. Runs off the main thread
// and never lets an exception escape into the guest.

static NSString *ESCDataToHex(NSData *data) {
    if (![data isKindOfClass:NSData.class]) return @"(nil)";
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

static void ESCAppendModelHashes(NSMutableString *out, NSManagedObjectModel *model) {
    NSArray *ids = [model.versionIdentifiers.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [out appendFormat:@"    versionIdentifiers: %@\n", ids.count ? ids : @[]];
    NSDictionary<NSString *, NSData *> *hashes = model.entityVersionHashesByName;
    [out appendFormat:@"    entities (%lu):\n", (unsigned long)hashes.count];
    for (NSString *name in [hashes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [out appendFormat:@"      %@ = %@\n", name, ESCDataToHex(hashes[name])];
    }
}

// Locate the guest's compiled model directory. The guest bundle is
// .../Frameworks/SideStoreApp.framework and its AltStore.momd sits directly
// inside it.
static NSString *ESCFindGuestMomdPath(NSArray<NSBundle *> *bundles) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *mainPath = NSBundle.mainBundle.bundlePath;
    if (mainPath.length) [roots addObject:mainPath];
    for (NSBundle *b in bundles) {
        if ([b.bundlePath.lastPathComponent isEqualToString:@"SideStoreApp.framework"]) {
            [roots addObject:b.bundlePath];
        }
    }
    NSString *lcFrameworks = [NSUserDefaults.lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"];
    if (lcFrameworks.length) [roots addObject:lcFrameworks];
    for (NSString *root in roots) {
        NSString *candidate = [root stringByAppendingPathComponent:@"AltStore.momd"];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

// Where to drop the report. Falls back to the guest's tmp dir when no app group
// container is reachable, so the diagnostic is never silently lost.
static NSString *ESCDiagnosticPath(void) {
    NSString *groupID = ESCResolveStableAppGroup();
    NSURL *groupURL = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (groupURL) {
        return [groupURL URLByAppendingPathComponent:@"esc-sidestore-diag.txt"].path;
    }
    NSString *tmp = NSTemporaryDirectory();
    return tmp.length ? [tmp stringByAppendingPathComponent:@"esc-sidestore-diag.txt"] : nil;
}

// One-shot diagnostic. Written once, to <app group>/esc-sidestore-diag.txt.
static void ESCWriteAllBundlesDiagnostic(NSArray<NSBundle*> *originalBundles) {
    NSString *diagPath = ESCDiagnosticPath();
    if (diagPath.length == 0) {
        NSLog(@"[ESC] diag: no writable location, skipping");
        return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:diagPath]) return;

    NSBundle *guest = NSBundle.mainBundle;
    NSString *groupID = ESCResolveStableAppGroup();
    NSURL *groupURL = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:groupID];
    NSMutableString *out = [NSMutableString string];

    @try {
        [out appendFormat:@"diag path: %@\n", diagPath];
        [out appendFormat:@"guest mainBundle: %@\n", guest.bundlePath];
        [out appendFormat:@"guest in allBundles BEFORE fix: %@\n", ([originalBundles containsObject:guest] ? @"YES" : @"NO")];

        [out appendFormat:@"\nallBundles (%lu) BEFORE fix:\n", (unsigned long)originalBundles.count];
        for (NSBundle *b in originalBundles) [out appendFormat:@"  %@\n", b.bundlePath];

        NSArray<NSBundle*> *frameworks = NSBundle.allFrameworks;
        [out appendFormat:@"\nallFrameworks (%lu):\n", (unsigned long)frameworks.count];
        for (NSBundle *b in frameworks) [out appendFormat:@"  %@\n", b.bundlePath];

        // The list SideStore itself passes to mergedModelFromBundles:. Fetching
        // it here is safe: the one-shot guard is already set when this runs, so
        // re-entering +[NSBundle allBundles] cannot recurse.
        NSArray<NSBundle*> *effectiveBundles = NSBundle.allBundles;

        NSString *dbPath = groupURL
            ? [[groupURL URLByAppendingPathComponent:@"Database"] URLByAppendingPathComponent:@"SideStore.sqlite"].path
            : nil;
        BOOL dbExists = dbPath.length ? [NSFileManager.defaultManager fileExistsAtPath:dbPath] : NO;
        [out appendFormat:@"\nstore: %@ exists=%@\n", dbPath ?: @"(no app group container)", (dbExists ? @"YES" : @"NO")];

        // --- 1. model versions shipped in the guest's AltStore.momd ----------
        [out appendString:@"\n=== Core Data: models in guest AltStore.momd ===\n"];
        NSString *momdPath = ESCFindGuestMomdPath(effectiveBundles);
        if (!momdPath) {
            [out appendString:@"momd: NOT FOUND (checked guest mainBundle, allBundles, LC Frameworks)\n"];
        } else {
            [out appendFormat:@"momd: %@\n", momdPath];
            NSError *listErr = nil;
            NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:momdPath error:&listErr];
            if (!entries) {
                [out appendFormat:@"momd listing FAILED: %@\n", listErr.localizedDescription ?: @"(no error)"];
            } else {
                NSArray<NSString *> *sorted = [entries sortedArrayUsingSelector:@selector(compare:)];
                NSMutableArray<NSString *> *momNames = [NSMutableArray array];
                for (NSString *name in sorted) {
                    if ([name.pathExtension isEqualToString:@"mom"]) [momNames addObject:name];
                }
                [out appendFormat:@"model versions (%lu of %lu entries):\n", (unsigned long)momNames.count, (unsigned long)sorted.count];
                for (NSString *name in momNames) {
                    NSURL *momURL = [NSURL fileURLWithPath:[momdPath stringByAppendingPathComponent:name]];
                    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:momURL];
                    [out appendFormat:@"  %@:\n", name];
                    if (!model) {
                        [out appendString:@"    LOAD FAILED (initWithContentsOfURL: returned nil)\n"];
                        continue;
                    }
                    ESCAppendModelHashes(out, model);
                }
            }
        }

        // --- 2. on-disk store metadata --------------------------------------
        [out appendString:@"\n=== Core Data: on-disk store metadata ===\n"];
        NSDictionary *storeMeta = nil;
        NSError *metaErr = nil;
        if (dbExists) {
            storeMeta = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                  URL:[NSURL fileURLWithPath:dbPath]
                                                                              options:nil
                                                                                error:&metaErr];
        }
        if (storeMeta) {
            [out appendString:@"metadata: OK\n"];
            id ids = storeMeta[NSStoreModelVersionIdentifiersKey];
            [out appendFormat:@"  NSStoreModelVersionIdentifiers: %@\n", ids ?: @"(none)"];
            // The value is an NSDictionary of entity name -> NSData hash. Its
            // static type in the metadata dict is `id`, so cast explicitly.
            NSDictionary<NSString *, NSData *> *storeHashes =
                (NSDictionary<NSString *, NSData *> *)storeMeta[NSStoreModelVersionHashesKey];
            if (![storeHashes isKindOfClass:NSDictionary.class]) storeHashes = nil;
            [out appendFormat:@"  NSStoreModelVersionHashes entities (%lu):\n", (unsigned long)storeHashes.count];
            for (NSString *name in [storeHashes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                [out appendFormat:@"    %@ = %@\n", name, ESCDataToHex(storeHashes[name])];
            }
        } else {
            [out appendFormat:@"metadata: UNAVAILABLE (store exists=%@, error=%@)\n",
                              (dbExists ? @"YES" : @"NO"), metaErr.localizedDescription ?: @"(no error)"];
        }

        // --- 3. the lookup SideStore performs --------------------------------
        [out appendString:@"\n=== Core Data: mergedModelFromBundles:forStoreMetadata: ===\n"];
        if (storeMeta) {
            NSManagedObjectModel *merged = [NSManagedObjectModel mergedModelFromBundles:effectiveBundles
                                                                       forStoreMetadata:storeMeta];
            if (merged) {
                NSArray *mids = [merged.versionIdentifiers.allObjects sortedArrayUsingSelector:@selector(compare:)];
                [out appendFormat:@"result: NON-NIL, entities=%lu, versionIdentifiers=%@\n",
                                  (unsigned long)merged.entityVersionHashesByName.count, mids.count ? mids : @[]];
            } else {
                [out appendString:@"result: nil  <-- this is what makes SideStore throw Code=-23\n"];
            }
        } else {
            [out appendString:@"result: SKIPPED (no store metadata to match against)\n"];
        }

        // --- 4. app group state ---------------------------------------------
        [out appendString:@"\n=== app group ===\n"];
        [out appendFormat:@"LCSharedUtils.appGroupID: %@\n", LCSharedUtils.appGroupID];
        [out appendFormat:@"LCSharedUtils.teamIdentifier: %@\n", LCSharedUtils.teamIdentifier ?: @"(nil)"];
        [out appendFormat:@"ESC resolved app group: %@\n", groupID];
        [out appendFormat:@"candidates: %@\n", ESCCandidateAppGroups()];
        [out appendFormat:@"LCSharedUtils.appGroupPath: %@\n", LCSharedUtils.appGroupPath.path ?: @"(nil)"];
        if (groupURL) {
            [out appendFormat:@"<group>/Apps exists: %@\n",
                              ([NSFileManager.defaultManager fileExistsAtPath:[groupURL URLByAppendingPathComponent:@"Apps"].path] ? @"YES" : @"NO")];
            [out appendFormat:@"<group>/Database exists: %@\n",
                              ([NSFileManager.defaultManager fileExistsAtPath:[groupURL URLByAppendingPathComponent:@"Database"].path] ? @"YES" : @"NO")];
        } else {
            [out appendString:@"<group> containerURL: nil (cannot check Apps/ or Database/)\n"];
        }
    } @catch (NSException *e) {
        [out appendFormat:@"\n!!! diagnostic aborted: %@ (reason: %@)\n", e.name, e.reason];
        NSLog(@"[ESC] diag aborted: %@", e);
    }

    // Write whatever was collected; never throw into the guest.
    @try {
        [out writeToFile:diagPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[ESC] diag written to %@", diagPath);
    } @catch (NSException *e) {
        NSLog(@"[ESC] diag write failed: %@", e);
    }
}

+ (NSArray<NSBundle*>*)hook_allBundles {
    // exchange-style swizzle: this call reaches the original +[NSBundle allBundles]
    NSArray<NSBundle*> *bundles = [NSBundle hook_allBundles];

    // set the flag before doing any work: the diagnostic itself touches NSBundle
    // APIs, so re-entrancy must not be able to re-enter this block. The work
    // itself runs off the main thread, since it loads models and reads SQLite.
    static BOOL escDiagnosticScheduled = NO;
    if (!escDiagnosticScheduled) {
        escDiagnosticScheduled = YES;
        NSArray<NSBundle*> *beforeFix = bundles;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            ESCWriteAllBundlesDiagnostic(beforeFix);
        });
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

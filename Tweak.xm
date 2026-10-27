#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>

@interface SBIconView : UIView
- (id)icon;
- (BOOL)isEditing;
- (void)tapGestureDidChange:(UIGestureRecognizer *)gesture;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isEditing;
- (void)setIsEditing:(BOOL)editing;
@end

static NSMutableOrderedSet<NSString *> *MDSelectedBundleIDs;
static NSMutableSet<NSString *> *MDSelectedViaIconCapability;
static NSMutableSet<NSString *> *MDPendingWebClipCleanup;
static NSMutableDictionary<NSString *, NSNumber *> *MDWebClipCleanupResults;
static __weak UIWindow *MDPanelWindow;
static UIView *MDPanel;
static UILabel *MDCountLabel;
static UIButton *MDCancelButton;
static UIButton *MDDeleteButton;
static UIActivityIndicatorView *MDDeleteSpinner;
static UILabel *MDDeleteLoadingLabel;
static UIStackView *MDDeleteLoadingStack;
static BOOL MDDeletionInProgress;
static BOOL MDEditExitCheckScheduled;
static id MDApplicationBackgroundObserver;
static char MDBadgeAssociationKey;
static char MDTouchStartPointKey;
static char MDTouchStartTimeKey;
static char MDTouchStartEditingKey;
static BOOL MDNativeDragReentry;
static BOOL MDNativeDragCapability;

static void MDLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSString *line = [NSString stringWithFormat:@"[HomeManager] %@", message];
    NSLog(@"%@", line);
}

static void MDStartDeletion(NSArray<NSString *> *bundleIDs, NSArray<NSString *> *preflightFailures);
static void MDToggleSelection(id iconView, NSString *bundleID);

static id MDMessage(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL MDBoolMessage(id object, NSString *selectorName, BOOL *available) {
    SEL selector = NSSelectorFromString(selectorName);
    BOOL hasSelector = object && [object respondsToSelector:selector];
    if (available) *available = hasSelector;
    if (!hasSelector) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL MDBoolMessageWithObject(id object, NSString *selectorName, id argument, BOOL *available) {
    SEL selector = NSSelectorFromString(selectorName);
    BOOL hasSelector = object && [object respondsToSelector:selector];
    if (available) *available = hasSelector;
    if (!hasSelector) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(object, selector, argument);
}

static id MDIconForView(id iconView) {
    return MDMessage(iconView, @"icon");
}

static BOOL MDIconIsBookmark(id icon) {
    if (!icon) return NO;
    BOOL bookmarkCheckAvailable = NO;
    BOOL isBookmark = MDBoolMessage(icon, @"isBookmarkIcon", &bookmarkCheckAvailable);
    if (bookmarkCheckAvailable) return isBookmark;
    return [NSStringFromClass([icon class]) containsString:@"BookmarkIcon"];
}

static NSString *MDStringMessage(id object, NSString *selectorName) {
    id value = MDMessage(object, selectorName);
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

static NSString *MDBundleIDForIconView(id iconView) {
    id icon = MDIconForView(iconView);
    BOOL isApplicationIconAvailable = NO;
    BOOL isApplicationIcon = MDBoolMessage(icon, @"isApplicationIcon", &isApplicationIconAvailable);
    if (isApplicationIconAvailable && isApplicationIcon) {
        return MDStringMessage(icon, @"applicationBundleID");
    }

    if (!MDIconIsBookmark(icon)) return nil;

    // Web Clips are SBBookmarkIcons, not application icons. Their leaf identifier
    // is the stable SpringBoard identity used to find the icon again for deletion.
    NSString *leafIdentifier = MDStringMessage(icon, @"leafIdentifier");
    if (leafIdentifier) return leafIdentifier;

    id webClip = MDMessage(icon, @"webClip");
    NSString *webClipIdentifier = MDStringMessage(webClip, @"identifier");
    if (webClipIdentifier) return webClipIdentifier;
    NSString *webClipBundleID = MDStringMessage(webClip, @"bundleIdentifier");
    if (webClipBundleID) return webClipBundleID;
    return MDStringMessage(icon, @"applicationBundleID");
}

static id MDApplicationController(void) {
    Class cls = objc_getClass("SBApplicationController");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:sharedSelector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sharedSelector);
}

static id MDIconController(void) {
    return MDMessage(objc_getClass("SBIconController"), @"sharedInstance");
}

static id MDApplicationForBundleID(NSString *bundleID) {
    id controller = MDApplicationController();
    SEL selector = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!controller || ![controller respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, bundleID);
}

static id MDLaunchServicesWorkspace(void) {
    Class cls = objc_getClass("LSApplicationWorkspace");
    SEL selector = NSSelectorFromString(@"defaultWorkspace");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static BOOL MDApplicationIsInstalled(NSString *bundleID, BOOL *available) {
    id workspace = MDLaunchServicesWorkspace();
    SEL selector = NSSelectorFromString(@"applicationIsInstalled:");
    BOOL hasSelector = workspace && [workspace respondsToSelector:selector];
    if (available) *available = hasSelector;
    if (!hasSelector) return MDApplicationForBundleID(bundleID) != nil;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleID);
}

static BOOL MDIconModelContainsBundleID(NSString *bundleID) {
    id iconController = MDIconController();
    id iconManager = MDMessage(iconController, @"iconManager");
    id iconModel = MDMessage(iconManager, @"iconModel");
    if (!iconModel) iconModel = MDMessage(iconController, @"iconModel");
    id iconsByIdentifier = MDMessage(iconModel, @"leafIconsByIdentifier");
    SEL lookupSelector = @selector(objectForKey:);
    return [iconsByIdentifier respondsToSelector:lookupSelector] &&
           ((id (*)(id, SEL, id))objc_msgSend)(iconsByIdentifier, lookupSelector, bundleID) != nil;
}

static BOOL MDApplicationCanBeRemoved(id application) {
    BOOL available = NO;
    BOOL supported = MDBoolMessage(application, @"isUninstallSupported", &available);
    return available && supported;
}

static BOOL MDIconCanBeRemoved(id iconView, id application) {
    id icon = MDIconForView(iconView);
    BOOL isBookmark = MDIconIsBookmark(icon);
    if (application && !isBookmark) return MDApplicationCanBeRemoved(application);

    id iconController = MDIconController();
    BOOL iconControllerCheckAvailable = NO;
    BOOL iconControllerAllowsRemoval = MDBoolMessageWithObject(iconController,
                                                               @"isUninstallSupportedForIcon:",
                                                               icon,
                                                               &iconControllerCheckAvailable);
    if (iconControllerCheckAvailable && iconControllerAllowsRemoval) return YES;

    BOOL iconAllowsRemovalAvailable = NO;
    BOOL iconAllowsRemoval = MDBoolMessage(icon, @"allowsUninstall", &iconAllowsRemovalAvailable);
    if (iconAllowsRemovalAvailable && iconAllowsRemoval) return YES;

    BOOL canShowCloseBoxAvailable = NO;
    BOOL canShowCloseBox = MDBoolMessage(iconView, @"canShowCloseBox", &canShowCloseBoxAvailable);
    if (canShowCloseBoxAvailable && canShowCloseBox) return YES;

    BOOL closeBoxAvailable = NO;
    BOOL closeBoxAllowed = MDBoolMessage(iconView, @"allowsCloseBox", &closeBoxAvailable);
    if (closeBoxAvailable && closeBoxAllowed) return YES;

    BOOL canDisplayCloseBoxAvailable = NO;
    BOOL canDisplayCloseBox = MDBoolMessage(iconView, @"_canDisplayCloseBox", &canDisplayCloseBoxAvailable);
    return canDisplayCloseBoxAvailable && canDisplayCloseBox;
}

static BOOL MDRemoveWebClipFromDisk(id webClip) {
    SEL selector = NSSelectorFromString(@"removeFromDisk");
    if (!webClip || ![webClip respondsToSelector:selector]) {
        MDLog(@"Web Clip cleanup unavailable; object=%@", webClip ? NSStringFromClass([webClip class]) : @"nil");
        return NO;
    }

    NSMethodSignature *signature = [webClip methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) {
        MDLog(@"Web Clip removeFromDisk has an unexpected signature");
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = webClip;
    invocation.selector = selector;
    [invocation invoke];

    const char *returnType = signature.methodReturnType;
    while (*returnType == 'r' || *returnType == 'n' || *returnType == 'N' || *returnType == 'o' ||
           *returnType == 'O' || *returnType == 'R' || *returnType == 'V') returnType++;
    BOOL succeeded = YES;
    if (*returnType == 'B' || *returnType == 'c') {
        signed char result = 0;
        [invocation getReturnValue:&result];
        succeeded = result != 0;
    }
    MDLog(@"Web Clip removeFromDisk invoked on %@, return type %s, accepted=%@",
          NSStringFromClass([webClip class]), returnType, succeeded ? @"yes" : @"no");
    return succeeded;
}

static BOOL MDHomeScreenIsEditing(id iconView) {
    BOOL viewEditing = MDBoolMessage(iconView, @"isEditing", NULL);
    Class controllerClass = objc_getClass("SBIconController");
    BOOL controllerEditing = NO;
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    if (controllerClass && [controllerClass respondsToSelector:sharedSelector]) {
        id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
        controllerEditing = MDBoolMessage(controller, @"isEditing", NULL);
    }
    return viewEditing || controllerEditing;
}

static UIWindow *MDKeyWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *keyWindow = application.keyWindow;
    if (keyWindow && !keyWindow.hidden) return keyWindow;
    for (UIWindow *window in application.windows.reverseObjectEnumerator) {
        if (!window.hidden && window.windowLevel == UIWindowLevelNormal) return window;
    }
    return nil;
}

static UIViewController *MDTopViewController(void) {
    UIViewController *controller = MDKeyWindow().rootViewController;
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)controller).visibleViewController;
        }
        if (!next && [controller isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)controller).selectedViewController;
        }
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static id MDIconViewForBundleID(NSString *bundleID);

static NSString *MDDisplayName(NSString *bundleID) {
    id application = MDApplicationForBundleID(bundleID);
    id name = MDMessage(application, @"displayName");
    if ([name isKindOfClass:NSString.class] && [name length] > 0) return name;
    id iconView = MDIconViewForBundleID(bundleID);
    id iconName = MDMessage(MDIconForView(iconView), @"displayName");
    if ([iconName isKindOfClass:NSString.class] && [iconName length] > 0) return iconName;
    return bundleID;
}

static void MDLayoutPanel(void) {
    UIWindow *window = MDPanelWindow;
    if (!window || !MDPanel) return;
    CGFloat width = MIN(440.0, MAX(292.0, window.bounds.size.width - 24.0));
    width = MIN(width, window.bounds.size.width - 16.0);
    CGFloat height = 58.0;
    CGFloat x = (window.bounds.size.width - width) / 2.0;
    CGFloat y = window.safeAreaInsets.top + 8.0;
    MDPanel.frame = CGRectMake(x, y, width, height);
    MDCountLabel.frame = CGRectMake(16.0, 0.0, MAX(64.0, width - 220.0), height);
    MDCancelButton.frame = CGRectMake(width - 190.0, 0.0, 82.0, height);
    MDDeleteButton.frame = CGRectMake(width - 104.0, 0.0, 96.0, height);
}

static void MDRefreshPanel(void);

static UIView *MDMinusCloseBoxInView(UIView *view) {
    for (UIView *child in view.subviews) {
        NSString *className = NSStringFromClass(child.class);
        if ([className containsString:@"MinusCloseBox"]) return child;
        UIView *nested = MDMinusCloseBoxInView(child);
        if (nested) return nested;
    }
    return nil;
}

static CGRect MDBadgeFrameForIconView(UIView *iconView) {
    CGSize bounds = iconView.bounds.size;
    UIView *closeBox = MDMinusCloseBoxInView(iconView);
    if (closeBox) {
        CGRect closeFrame = [closeBox convertRect:closeBox.bounds toView:iconView];
        CGFloat diameter = MIN(32.0, MAX(24.0, MAX(closeFrame.size.width, closeFrame.size.height)));
        CGFloat x = CGRectGetMidX(closeFrame) < bounds.width / 2.0
            ? bounds.width - CGRectGetMaxX(closeFrame)
            : closeFrame.origin.x;
        return CGRectMake(x, closeFrame.origin.y, diameter, diameter);
    }
    return CGRectMake(MAX(0.0, bounds.width - 25.0), 3.0, 24.0, 24.0);
}

static void MDUpdateBadge(id iconView) {
    if (!iconView || ![iconView isKindOfClass:UIView.class]) return;
    NSString *bundleID = MDBundleIDForIconView(iconView);
    BOOL selected = MDHomeScreenIsEditing(iconView) && bundleID && [MDSelectedBundleIDs containsObject:bundleID];
    UIView *badge = objc_getAssociatedObject(iconView, &MDBadgeAssociationKey);

    if (!selected) {
        [badge removeFromSuperview];
        objc_setAssociatedObject(iconView, &MDBadgeAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (!badge) {
        badge = [[UIView alloc] initWithFrame:CGRectZero];
        badge.userInteractionEnabled = NO;
        badge.backgroundColor = UIColor.systemBlueColor;
        badge.layer.borderColor = UIColor.whiteColor.CGColor;
        badge.layer.borderWidth = 1.5;
        badge.layer.shadowColor = UIColor.blackColor.CGColor;
        badge.layer.shadowOpacity = 0.25;
        badge.layer.shadowRadius = 2.0;
        badge.layer.shadowOffset = CGSizeMake(0.0, 1.0);

        UILabel *check = [[UILabel alloc] initWithFrame:CGRectZero];
        check.text = @"✓";
        check.textAlignment = NSTextAlignmentCenter;
        check.textColor = UIColor.whiteColor;
        check.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
        check.userInteractionEnabled = NO;
        check.tag = 7401;
        [badge addSubview:check];
        [iconView addSubview:badge];
        objc_setAssociatedObject(iconView, &MDBadgeAssociationKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    badge.frame = MDBadgeFrameForIconView(iconView);
    badge.layer.cornerRadius = badge.bounds.size.height / 2.0;
    UILabel *check = [badge viewWithTag:7401];
    check.frame = badge.bounds;
}

static void MDRefreshIconViewsInView(UIView *view) {
    Class iconViewClass = objc_getClass("SBIconView");
    if (!iconViewClass || !view) return;
    if ([view isKindOfClass:iconViewClass]) MDUpdateBadge(view);
    for (UIView *child in view.subviews) MDRefreshIconViewsInView(child);
}

static void MDRefreshIconViews(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        MDRefreshIconViewsInView(window);
    }
}

static id MDIconViewForBundleIDInView(UIView *view, NSString *bundleID) {
    Class iconViewClass = objc_getClass("SBIconView");
    if (!view || !iconViewClass) return nil;
    if ([view isKindOfClass:iconViewClass] && [MDBundleIDForIconView(view) isEqualToString:bundleID]) return view;
    for (UIView *child in view.subviews) {
        id match = MDIconViewForBundleIDInView(child, bundleID);
        if (match) return match;
    }
    return nil;
}

static id MDIconViewForBundleID(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) return nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        id match = MDIconViewForBundleIDInView(window, bundleID);
        if (match) return match;
    }
    return nil;
}

static void MDClearSelection(void) {
    [MDSelectedBundleIDs removeAllObjects];
    [MDSelectedViaIconCapability removeAllObjects];
    MDRefreshPanel();
    MDRefreshIconViews();
}

static void MDHidePanel(void) {
    [MDPanel removeFromSuperview];
}

// SpringBoard can briefly report a false editing state while transitioning
// between edit-mode operations. Confirm on the next main-queue turn, after the
// lifecycle setter and its related state updates have completed.
static void MDScheduleEditExitCheck(void) {
    if (MDEditExitCheckScheduled) return;
    MDEditExitCheckScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        MDEditExitCheckScheduled = NO;
        if (!MDDeletionInProgress && MDSelectedBundleIDs.count > 0 &&
            !MDHomeScreenIsEditing(nil)) {
            MDClearSelection();
        }
    });
}

@interface MDActionHandler : NSObject
+ (instancetype)sharedHandler;
- (void)cancelSelection:(id)sender;
- (void)confirmDelete:(id)sender;
@end

@implementation MDActionHandler

+ (instancetype)sharedHandler {
    static MDActionHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [[self alloc] init]; });
    return handler;
}

- (void)cancelSelection:(id)sender {
    if (MDDeletionInProgress) return;
    MDClearSelection();
}

- (void)confirmDelete:(id)sender {
    if (MDDeletionInProgress || MDSelectedBundleIDs.count == 0) return;

    NSMutableArray<NSString *> *bundleIDs = [NSMutableArray array];
    NSMutableArray<NSString *> *preflightFailures = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *bundleID in MDSelectedBundleIDs) {
        id application = MDApplicationForBundleID(bundleID);
        BOOL supportedByApplication = MDApplicationCanBeRemoved(application);
        BOOL selectedByIconCapability = [MDSelectedViaIconCapability containsObject:bundleID];
        if (supportedByApplication || selectedByIconCapability) {
            [bundleIDs addObject:bundleID];
            [names addObject:MDDisplayName(bundleID)];
        } else {
            [preflightFailures addObject:bundleID];
        }
    }

    if (bundleIDs.count == 0) {
        NSMutableArray<NSString *> *failedNames = [NSMutableArray array];
        for (NSString *bundleID in preflightFailures) [failedNames addObject:MDDisplayName(bundleID)];
        NSString *message = preflightFailures.count > 0
            ? [NSString stringWithFormat:@"iOS no longer marks these apps as removable:\n%@", [failedNames componentsJoinedByString:@"\n"]]
            : @"No selected apps are available to remove.";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Removable Apps"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter = MDTopViewController();
        if (presenter && !presenter.presentedViewController) [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *title = [NSString stringWithFormat:@"Delete %lu %@?", (unsigned long)bundleIDs.count,
                       bundleIDs.count == 1 ? @"app" : @"apps"];
    NSString *message = [names componentsJoinedByString:@"\n"];
    if (preflightFailures.count > 0) {
        NSMutableArray<NSString *> *failedNames = [NSMutableArray array];
        for (NSString *bundleID in preflightFailures) [failedNames addObject:MDDisplayName(bundleID)];
        message = [message stringByAppendingFormat:@"\n\nThese apps are no longer removable and will be left installed:\n%@",
                   [failedNames componentsJoinedByString:@"\n"]];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        MDStartDeletion(bundleIDs, preflightFailures);
    }]];

    UIViewController *presenter = MDTopViewController();
    if (presenter && !presenter.presentedViewController) {
        [presenter presentViewController:alert animated:YES completion:nil];
    }
}

@end

static void MDRefreshPanel(void) {
    if (!MDHomeScreenIsEditing(nil) || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        MDHidePanel();
        return;
    }
    if (MDSelectedBundleIDs.count == 0) {
        [MDPanel removeFromSuperview];
        MDPanel = nil;
        MDCountLabel = nil;
        MDCancelButton = nil;
        MDDeleteButton = nil;
        MDDeleteSpinner = nil;
        MDDeleteLoadingLabel = nil;
        MDDeleteLoadingStack = nil;
        MDPanelWindow = nil;
        return;
    }

    UIWindow *window = MDKeyWindow();
    if (!window) return;

    if (!MDPanel) {
        MDPanel = [[UIView alloc] initWithFrame:CGRectZero];
        MDPanel.layer.cornerRadius = 16.0;
        MDPanel.layer.masksToBounds = YES;

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        blur.frame = MDPanel.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [MDPanel addSubview:blur];

        MDCountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        MDCountLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        MDCountLabel.textColor = UIColor.labelColor;
        MDCountLabel.adjustsFontSizeToFitWidth = YES;
        MDCountLabel.minimumScaleFactor = 0.75;
        [MDPanel addSubview:MDCountLabel];

        MDDeleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [MDDeleteButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
        MDDeleteButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        [MDDeleteButton setTitle:@"Delete" forState:UIControlStateNormal];
        [MDDeleteButton addTarget:MDActionHandler.sharedHandler action:@selector(confirmDelete:)
                 forControlEvents:UIControlEventTouchUpInside];
        [MDPanel addSubview:MDDeleteButton];

        MDDeleteSpinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        MDDeleteSpinner.color = UIColor.systemRedColor;
        MDDeleteSpinner.hidesWhenStopped = YES;
        MDDeleteSpinner.userInteractionEnabled = NO;
        MDDeleteSpinner.translatesAutoresizingMaskIntoConstraints = NO;

        MDDeleteLoadingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        MDDeleteLoadingLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        MDDeleteLoadingLabel.textColor = UIColor.systemRedColor;
        MDDeleteLoadingLabel.text = @"Deleting…";
        MDDeleteLoadingLabel.textAlignment = NSTextAlignmentLeft;
        MDDeleteLoadingLabel.adjustsFontSizeToFitWidth = YES;
        MDDeleteLoadingLabel.minimumScaleFactor = 0.75;
        MDDeleteLoadingLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [MDDeleteLoadingLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                             forAxis:UILayoutConstraintAxisHorizontal];
        MDDeleteLoadingLabel.userInteractionEnabled = NO;
        MDDeleteLoadingLabel.isAccessibilityElement = NO;

        MDDeleteLoadingStack = [[UIStackView alloc] initWithArrangedSubviews:@[MDDeleteSpinner, MDDeleteLoadingLabel]];
        MDDeleteLoadingStack.axis = UILayoutConstraintAxisHorizontal;
        MDDeleteLoadingStack.alignment = UIStackViewAlignmentCenter;
        MDDeleteLoadingStack.distribution = UIStackViewDistributionFill;
        MDDeleteLoadingStack.spacing = 4.0;
        MDDeleteLoadingStack.translatesAutoresizingMaskIntoConstraints = NO;
        MDDeleteLoadingStack.hidden = YES;
        MDDeleteLoadingStack.isAccessibilityElement = NO;
        [MDDeleteButton addSubview:MDDeleteLoadingStack];
        [NSLayoutConstraint activateConstraints:@[
            [MDDeleteLoadingStack.centerXAnchor constraintEqualToAnchor:MDDeleteButton.centerXAnchor],
            [MDDeleteLoadingStack.centerYAnchor constraintEqualToAnchor:MDDeleteButton.centerYAnchor],
            [MDDeleteLoadingStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:MDDeleteButton.leadingAnchor constant:4.0],
            [MDDeleteLoadingStack.trailingAnchor constraintLessThanOrEqualToAnchor:MDDeleteButton.trailingAnchor constant:-4.0],
        ]];

        MDCancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [MDCancelButton setTitleColor:UIColor.systemBlueColor forState:UIControlStateNormal];
        MDCancelButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
        [MDCancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
        [MDCancelButton addTarget:MDActionHandler.sharedHandler action:@selector(cancelSelection:)
                 forControlEvents:UIControlEventTouchUpInside];
        [MDPanel addSubview:MDCancelButton];
    }

    if (MDPanelWindow != window || MDPanel.superview != window) {
        [MDPanel removeFromSuperview];
        MDPanelWindow = window;
        [window addSubview:MDPanel];
    }

    NSUInteger count = MDSelectedBundleIDs.count;
    MDCountLabel.text = [NSString stringWithFormat:@"%lu %@ selected", (unsigned long)count,
                         count == 1 ? @"app" : @"apps"];
    MDDeleteButton.enabled = !MDDeletionInProgress;
    [MDDeleteButton setTitle:@"Delete" forState:UIControlStateNormal];
    MDDeleteButton.titleLabel.hidden = MDDeletionInProgress;
    MDDeleteButton.accessibilityLabel = MDDeletionInProgress ? @"Deleting" : @"Delete";
    MDDeleteLoadingStack.hidden = !MDDeletionInProgress;
    if (MDDeletionInProgress) {
        [MDDeleteSpinner startAnimating];
    } else {
        [MDDeleteSpinner stopAnimating];
    }
    MDCancelButton.enabled = !MDDeletionInProgress;
    MDLayoutPanel();
    [window bringSubviewToFront:MDPanel];
}

static BOOL MDIsBundleRegistered(id controller, NSString *bundleID) {
    if (MDIconViewForBundleID(bundleID) || MDIconModelContainsBundleID(bundleID)) return YES;
    SEL allIDsSelector = NSSelectorFromString(@"allBundleIdentifiers");
    if ([controller respondsToSelector:allIDsSelector]) {
        id identifiers = ((id (*)(id, SEL))objc_msgSend)(controller, allIDsSelector);
        if ([identifiers respondsToSelector:@selector(containsObject:)] &&
            [identifiers containsObject:bundleID]) return YES;
    }
    return MDApplicationForBundleID(bundleID) != nil;
}

static BOOL MDApplicationListContainsBundleID(id applications, NSString *bundleID) {
    if (![applications respondsToSelector:@selector(objectEnumerator)]) return NO;
    for (id application in applications) {
        NSString *candidate = MDStringMessage(application, @"bundleIdentifier");
        if (!candidate) candidate = MDStringMessage(application, @"applicationIdentifier");
        if ([candidate isEqualToString:bundleID]) return YES;
    }
    return NO;
}

static BOOL MDLaunchServicesStillContainsBundleID(NSString *bundleID) {
    id workspace = MDLaunchServicesWorkspace();
    return MDApplicationListContainsBundleID(MDMessage(workspace, @"placeholderApplications"), bundleID) ||
           MDApplicationListContainsBundleID(MDMessage(workspace, @"allApplications"), bundleID);
}

static BOOL MDRemovalIsComplete(id controller, NSString *bundleID) {
    NSNumber *webClipCleanup = [MDWebClipCleanupResults objectForKey:bundleID];
    if ([MDPendingWebClipCleanup containsObject:bundleID]) {
        if (!webClipCleanup) return NO;
        if (!webClipCleanup.boolValue) return NO;
        return !MDIsBundleRegistered(controller, bundleID);
    }

    if (MDLaunchServicesStillContainsBundleID(bundleID)) return NO;
    BOOL installCheckAvailable = NO;
    BOOL applicationIsInstalled = MDApplicationIsInstalled(bundleID, &installCheckAvailable);
    if (installCheckAvailable && applicationIsInstalled) return NO;
    return !MDIsBundleRegistered(controller, bundleID);
}

static BOOL MDCallIconUninstall(id iconManager, id iconController, id icon, void (^completion)(void)) {
    if (!icon) return NO;
    SEL uninstallIconCompletionSelector = NSSelectorFromString(@"uninstallIcon:animate:completion:");
    SEL uninstallIconSelector = NSSelectorFromString(@"uninstallIcon:animate:");
    SEL uninstallIconSimpleSelector = NSSelectorFromString(@"uninstallIcon:");
    BOOL started = NO;

    if ([iconManager respondsToSelector:uninstallIconCompletionSelector]) {
        void (^finished)(void) = completion ?: ^{};
        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(iconManager,
                                                       uninstallIconCompletionSelector,
                                                       icon,
                                                       YES,
                                                       finished);
        started = YES;
    } else if ([iconManager respondsToSelector:uninstallIconSelector]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(iconManager, uninstallIconSelector, icon, YES);
        started = YES;
    } else if ([iconManager respondsToSelector:uninstallIconSimpleSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(iconManager, uninstallIconSimpleSelector, icon);
        started = YES;
    } else if ([iconController respondsToSelector:uninstallIconSelector]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(iconController, uninstallIconSelector, icon, YES);
        started = YES;
    } else if ([iconController respondsToSelector:uninstallIconSimpleSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(iconController, uninstallIconSimpleSelector, icon);
        started = YES;
    }

    if (started && completion && ![iconManager respondsToSelector:uninstallIconCompletionSelector]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), completion);
    }
    return started;
}

static BOOL MDUninstallInstalledApplication(NSString *bundleID, id application) {
    id workspace = MDLaunchServicesWorkspace();
    SEL workspaceUninstallSelector = NSSelectorFromString(@"uninstallApplication:withOptions:");
    if (workspace && [workspace respondsToSelector:workspaceUninstallSelector]) {
        BOOL accepted = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(workspace,
                                                                  workspaceUninstallSelector,
                                                                  bundleID,
                                                                  @{});
        MDLog(@"LaunchServices uninstall for %@ accepted=%@", bundleID, accepted ? @"yes" : @"no");
        if (accepted) return YES;
    } else {
        MDLog(@"LaunchServices uninstall selector unavailable for %@", bundleID);
    }

    id controller = MDApplicationController();
    SEL uninstallSelector = NSSelectorFromString(@"uninstallApplication:");
    if (application && controller && [controller respondsToSelector:uninstallSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, uninstallSelector, application);
        MDLog(@"Fell back to SBApplicationController uninstall for %@", bundleID);
        return YES;
    }
    return NO;
}

static void MDFinishDeletion(NSArray<NSString *> *removed, NSArray<NSString *> *failed) {
    for (NSString *bundleID in removed) {
        [MDSelectedBundleIDs removeObject:bundleID];
        [MDSelectedViaIconCapability removeObject:bundleID];
    }
    [MDPendingWebClipCleanup removeAllObjects];
    MDDeletionInProgress = NO;
    BOOL remainsInEditMode = MDHomeScreenIsEditing(nil);
    if (!remainsInEditMode || failed.count == 0) MDClearSelection();
    MDRefreshPanel();
    MDRefreshIconViews();

    UIViewController *presenter = MDTopViewController();
    if (failed.count > 0) {
        NSMutableArray<NSString *> *failedNames = [NSMutableArray array];
        for (NSString *bundleID in failed) [failedNames addObject:MDDisplayName(bundleID)];
        NSString *failureState = remainsInEditMode
            ? @"These apps could not be removed and remain selected:"
            : @"These apps could not be removed (selection was cleared because edit mode ended):";
        NSString *message = [NSString stringWithFormat:@"Removed %lu %@. %@\n%@",
                             (unsigned long)removed.count, removed.count == 1 ? @"app" : @"apps",
                             failureState, [failedNames componentsJoinedByString:@"\n"]];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Some Apps Remain"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        if (presenter && !presenter.presentedViewController) [presenter presentViewController:alert animated:YES completion:nil];
    } else if (removed.count > 0) {
        NSString *message = [NSString stringWithFormat:@"Removed %lu %@.", (unsigned long)removed.count,
                             removed.count == 1 ? @"app" : @"apps"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apps Removed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        if (presenter && !presenter.presentedViewController) [presenter presentViewController:alert animated:YES completion:nil];
    }
}

static void MDPollDeletion(NSMutableArray<NSString *> *pending,
                           NSMutableArray<NSString *> *removed,
                           NSMutableArray<NSString *> *failed,
                           NSUInteger round,
                           NSUInteger index) {
    if (pending.count == 0) {
        MDFinishDeletion(removed, failed);
        return;
    }

    if (index >= pending.count) {
        round++;
        index = 0;
    }
    if (round >= 120) {
        MDLog(@"Removal verification timed out for %@", [pending componentsJoinedByString:@", "]);
        [failed addObjectsFromArray:pending];
        [pending removeAllObjects];
        MDFinishDeletion(removed, failed);
        return;
    }

    id controller = MDApplicationController();
    NSString *bundleID = pending[index];
    NSNumber *webClipCleanup = [MDWebClipCleanupResults objectForKey:bundleID];
    BOOL resolved = NO;
    if ([MDPendingWebClipCleanup containsObject:bundleID] && webClipCleanup && !webClipCleanup.boolValue) {
        MDLog(@"Web Clip cleanup failed for %@", bundleID);
        [failed addObject:bundleID];
        resolved = YES;
    } else if (controller && MDRemovalIsComplete(controller, bundleID)) {
        MDLog(@"Verified removal for %@ after poll round %lu", bundleID, (unsigned long)round);
        [removed addObject:bundleID];
        resolved = YES;
    }

    if (resolved) [pending removeObjectAtIndex:index];
    if (pending.count == 0) {
        MDFinishDeletion(removed, failed);
        return;
    }

    NSUInteger nextIndex = resolved ? index : index + 1;
    NSUInteger nextRound = round;
    if (nextIndex >= pending.count) {
        nextIndex = 0;
        nextRound++;
    }
    NSTimeInterval pollInterval = MAX(0.05, 0.5 / (NSTimeInterval)pending.count);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MDPollDeletion(pending, removed, failed, nextRound, nextIndex);
    });
}

static void MDProcessDeletionQueue(NSArray<NSString *> *bundleIDs,
                                   NSUInteger index,
                                   NSMutableArray<NSString *> *pending,
                                   NSMutableArray<NSString *> *failed) {
    if (index >= bundleIDs.count) {
        if (pending.count == 0) {
            MDFinishDeletion(@[], failed);
        } else {
            NSMutableArray<NSString *> *removed = [NSMutableArray array];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                MDPollDeletion(pending, removed, failed, 0, 0);
            });
        }
        return;
    }

    NSString *bundleID = bundleIDs[index];
    id iconController = MDIconController();
    id iconManager = MDMessage(iconController, @"iconManager");
    id application = MDApplicationForBundleID(bundleID);
    BOOL selectedByIconCapability = [MDSelectedViaIconCapability containsObject:bundleID];
    BOOL applicationSupportsUninstall = MDApplicationCanBeRemoved(application);
    id iconView = MDIconViewForBundleID(bundleID);
    id icon = MDIconForView(iconView);
    BOOL isBookmark = MDIconIsBookmark(icon);
    BOOL started = NO;

    MDLog(@"Delete requested for %@; bookmark=%@ appRecord=%@ appRemovable=%@ iconRoute=%@",
          bundleID,
          isBookmark ? @"yes" : @"no",
          application ? @"yes" : @"no",
          applicationSupportsUninstall ? @"yes" : @"no",
          selectedByIconCapability ? @"yes" : @"no");

    if (isBookmark && selectedByIconCapability) {
        id webClip = MDMessage(icon, @"webClip");
        if (!webClip || ![webClip respondsToSelector:NSSelectorFromString(@"removeFromDisk")]) {
            MDLog(@"Refusing to remove Web Clip %@ because its persisted record cannot be removed", bundleID);
            [failed addObject:bundleID];
        } else {
            [MDPendingWebClipCleanup addObject:bundleID];
            [MDWebClipCleanupResults removeObjectForKey:bundleID];
            __block BOOL cleanupPerformed = NO;
            void (^cleanup)(void) = ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (cleanupPerformed) return;
                    cleanupPerformed = YES;
                    BOOL succeeded = NO;
                    @try {
                        succeeded = MDRemoveWebClipFromDisk(webClip);
                    } @catch (NSException *exception) {
                        MDLog(@"Web Clip cleanup raised %@", exception.name);
                    }
                    [MDWebClipCleanupResults setObject:@(succeeded) forKey:bundleID];
                });
            };
            @try {
                started = MDCallIconUninstall(iconManager, iconController, icon, cleanup);
            } @catch (NSException *exception) {
                MDLog(@"SpringBoard icon uninstall raised %@ for %@", exception.name, bundleID);
                started = NO;
            }
            if (started) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), cleanup);
            } else {
                cleanup();
                MDLog(@"SpringBoard has no icon uninstall method for Web Clip %@", bundleID);
            }
        }
    } else if (application && applicationSupportsUninstall) {
        BOOL animationStarted = NO;
        @try {
            animationStarted = MDCallIconUninstall(iconManager, iconController, icon, nil);
            started = MDUninstallInstalledApplication(bundleID, application);
        } @catch (NSException *exception) {
            MDLog(@"Application uninstall raised %@ for %@", exception.name, bundleID);
            started = NO;
        }
        started = started || animationStarted;
    } else if (selectedByIconCapability && icon && !application) {
        BOOL animationStarted = NO;
        @try {
            animationStarted = MDCallIconUninstall(iconManager, iconController, icon, nil);
            started = MDUninstallInstalledApplication(bundleID, nil) || animationStarted;
        } @catch (NSException *exception) {
            MDLog(@"Offloaded icon uninstall raised %@ for %@", exception.name, bundleID);
            started = animationStarted;
        }
    } else {
        MDLog(@"No supported removal route for %@", bundleID);
    }

    if (started) {
        [pending addObject:bundleID];
    } else {
        [failed addObject:bundleID];
        [MDPendingWebClipCleanup removeObject:bundleID];
    }

    // Start one uninstall at a time and return to SpringBoard's run loop between
    // requests so it can render the progress state and handle its own animations.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MDProcessDeletionQueue(bundleIDs, index + 1, pending, failed);
    });
}

static void MDStartDeletion(NSArray<NSString *> *bundleIDs, NSArray<NSString *> *preflightFailures) {
    if (MDDeletionInProgress) return;
    MDDeletionInProgress = YES;
    MDRefreshPanel();

    // Let the alert dismiss and give the spinner a visible frame before invoking
    // SpringBoard and LaunchServices uninstall APIs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id controller = MDApplicationController();
        id iconController = MDIconController();
        id iconManager = MDMessage(iconController, @"iconManager");
        id workspace = MDLaunchServicesWorkspace();
        SEL workspaceUninstallSelector = NSSelectorFromString(@"uninstallApplication:withOptions:");
        SEL controllerUninstallSelector = NSSelectorFromString(@"uninstallApplication:");
        BOOL canUninstallApplication = (workspace && [workspace respondsToSelector:workspaceUninstallSelector]) ||
                                      (controller && [controller respondsToSelector:controllerUninstallSelector]);
        SEL uninstallIconCompletionSelector = NSSelectorFromString(@"uninstallIcon:animate:completion:");
        SEL uninstallIconSelector = NSSelectorFromString(@"uninstallIcon:animate:");
        SEL uninstallIconSimpleSelector = NSSelectorFromString(@"uninstallIcon:");
        BOOL canUninstallIcon = (iconManager && ([iconManager respondsToSelector:uninstallIconCompletionSelector] ||
                                                 [iconManager respondsToSelector:uninstallIconSelector] ||
                                                 [iconManager respondsToSelector:uninstallIconSimpleSelector])) ||
                                (iconController && ([iconController respondsToSelector:uninstallIconSelector] ||
                                                    [iconController respondsToSelector:uninstallIconSimpleSelector]));
        if (!canUninstallApplication && !canUninstallIcon) {
            MDDeletionInProgress = NO;
            MDRefreshPanel();
            MDScheduleEditExitCheck();
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unable to Remove Apps"
                                                                           message:@"SpringBoard's app uninstall service is unavailable. No apps were removed."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *presenter = MDTopViewController();
            if (presenter && !presenter.presentedViewController) {
                [presenter presentViewController:alert animated:YES completion:nil];
            }
            return;
        }

        NSMutableArray<NSString *> *failed = [preflightFailures mutableCopy] ?: [NSMutableArray array];
        MDProcessDeletionQueue(bundleIDs, 0, [NSMutableArray array], failed);
    });
}

static void MDToggleSelection(id iconView, NSString *bundleID) {
    if (MDDeletionInProgress || !MDHomeScreenIsEditing(iconView) || !bundleID) return;
    if ([MDSelectedBundleIDs containsObject:bundleID]) {
        [MDSelectedBundleIDs removeObject:bundleID];
        [MDSelectedViaIconCapability removeObject:bundleID];
    } else {
        id application = MDApplicationForBundleID(bundleID);
        if (!MDIconCanBeRemoved(iconView, application)) return;
        [MDSelectedBundleIDs addObject:bundleID];
        if (MDIconIsBookmark(MDIconForView(iconView)) || !MDApplicationCanBeRemoved(application)) {
            [MDSelectedViaIconCapability addObject:bundleID];
        } else {
            [MDSelectedViaIconCapability removeObject:bundleID];
        }
    }

    MDUpdateBadge(iconView);
    MDRefreshPanel();
}

%group IconViewHooks
%hook SBIconView

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL editing = MDHomeScreenIsEditing(self);
    for (UITouch *touch in touches) {
        objc_setAssociatedObject(touch, &MDTouchStartPointKey,
                                 [NSValue valueWithCGPoint:[touch locationInView:self]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(touch, &MDTouchStartTimeKey,
                                 @(touch.timestamp), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(touch, &MDTouchStartEditingKey,
                                 @(editing), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (MDDeletionInProgress) {
        %orig;
        return;
    }
    UITouch *touch = touches.count == 1 ? touches.anyObject : nil;
    NSValue *startPointValue = objc_getAssociatedObject(touch, &MDTouchStartPointKey);
    NSNumber *startTimeValue = objc_getAssociatedObject(touch, &MDTouchStartTimeKey);
    NSNumber *wasEditingValue = objc_getAssociatedObject(touch, &MDTouchStartEditingKey);
    if (touch && startPointValue && startTimeValue && wasEditingValue.boolValue && MDHomeScreenIsEditing(self)) {
        CGPoint startPoint = startPointValue.CGPointValue;
        CGPoint endPoint = [touch locationInView:self];
        CGFloat dx = endPoint.x - startPoint.x;
        CGFloat dy = endPoint.y - startPoint.y;
        CGFloat movementSquared = dx * dx + dy * dy;
        CFTimeInterval duration = touch.timestamp - startTimeValue.doubleValue;
        BOOL isTap = touch.tapCount == 1 && duration >= 0.0 && duration <= 0.45 && movementSquared <= 196.0;
        NSString *bundleID = isTap ? MDBundleIDForIconView(self) : nil;
        id application = bundleID ? MDApplicationForBundleID(bundleID) : nil;
        if (isTap && bundleID && MDIconCanBeRemoved(self, application)) {
            MDToggleSelection(self, bundleID);
            return;
        }
    }
    %orig;
}

- (void)tapGestureDidChange:(UIGestureRecognizer *)gesture {
    if (MDDeletionInProgress) {
        %orig;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        BOOL editing = MDHomeScreenIsEditing(self);
        NSString *bundleID = MDBundleIDForIconView(self);
        id app = bundleID ? MDApplicationForBundleID(bundleID) : nil;
        if (editing && bundleID && ([MDSelectedBundleIDs containsObject:bundleID] || MDIconCanBeRemoved(self, app))) {
            return;
        }
    }
    %orig;
}

- (void)layoutSubviews {
    %orig;
    MDUpdateBadge(self);
    // Layout also catches alternate exits; defer until SpringBoard's transient
    // editing state has settled rather than clearing during a transition.
    if (MDSelectedBundleIDs.count > 0 && !MDHomeScreenIsEditing(self)) MDScheduleEditExitCheck();
    if (MDSelectedBundleIDs.count > 0) MDRefreshPanel();
}

- (void)prepareForReuse {
    %orig;
    MDUpdateBadge(self);
}

%end
%end

%group NativeDragHooks
%hook SBIconView
- (NSArray *)dragInteraction:(UIDragInteraction *)interaction itemsForBeginningSession:(id)session {
    NSArray *original = %orig;
    if (MDNativeDragReentry || !MDNativeDragCapability || !MDHomeScreenIsEditing(self)) return original;
    NSString *sourceID = MDBundleIDForIconView(self);
    if (!sourceID || ![MDSelectedBundleIDs containsObject:sourceID] || MDSelectedBundleIDs.count < 2) return original;
    if (![interaction isEqual:MDMessage(self, @"dragInteraction")] || ![original isKindOfClass:NSArray.class] || original.count == 0) return original;
    NSMutableArray *group = [original mutableCopy];
    NSMutableSet *included = [NSMutableSet setWithObject:sourceID];
    for (NSString *bundleID in MDSelectedBundleIDs) {
        if ([included containsObject:bundleID]) continue;
        id view = MDIconViewForBundleID(bundleID);
        id drag = MDMessage(view, @"dragInteraction");
        if (!view || !drag) return original;
        SEL selector = @selector(dragInteraction:itemsForBeginningSession:);
        if (![view respondsToSelector:selector]) return original;
        MDNativeDragReentry = YES;
        NSArray *items = nil;
        @try {
            items = ((id (*)(id, SEL, id, id))objc_msgSend)(view, selector, drag, session);
        } @catch (NSException *exception) {
            MDLog(@"Native drag item creation failed for %@: %@", bundleID, exception.name);
        } @finally {
            MDNativeDragReentry = NO;
        }
        if (![items isKindOfClass:NSArray.class] || items.count == 0) return original;
        [group addObjectsFromArray:items];
        [included addObject:bundleID];
    }
    return group;
}
%end
%end

%group IconControllerHooks
%hook SBIconController

- (void)setIsEditing:(BOOL)editing {
    %orig;
    if (!editing && MDSelectedBundleIDs.count > 0) {
        MDScheduleEditExitCheck();
        MDHidePanel();
        MDRefreshIconViews();
    }
}

%end
%end

%ctor {
    @autoreleasepool {
        MDSelectedBundleIDs = [NSMutableOrderedSet orderedSet];
        MDSelectedViaIconCapability = [NSMutableSet set];
        MDPendingWebClipCleanup = [NSMutableSet set];
        MDWebClipCleanupResults = [NSMutableDictionary dictionary];
        MDLog(@"Loaded on iOS %@", UIDevice.currentDevice.systemVersion);
        Class iconViewClass = objc_getClass("SBIconView");
        BOOL touchMethodAvailable = iconViewClass && class_getInstanceMethod(iconViewClass, @selector(touchesEnded:withEvent:));
        if (touchMethodAvailable) {
            %init(IconViewHooks);
        }
        Class dragClass = objc_getClass("SBIconView");
        SEL dragSelector = NSSelectorFromString(@"dragInteraction:itemsForBeginningSession:");
        Method dragMethod = dragClass ? class_getInstanceMethod(dragClass, dragSelector) : NULL;
        if (dragMethod) {
            const char *types = method_getTypeEncoding(dragMethod);
            NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:types];
            const char *ret = sig.methodReturnType;
            while (*ret == 'r' || *ret == 'n' || *ret == 'N' || *ret == 'o' || *ret == 'O' || *ret == 'R' || *ret == 'V') ret++;
            MDNativeDragCapability = sig.numberOfArguments == 4 && *ret == '@' && objc_getClass("UIDragInteraction") != Nil;
            for (NSUInteger i = 2; MDNativeDragCapability && i < 4; i++) {
                const char *arg = [sig getArgumentTypeAtIndex:i];
                while (*arg == 'r' || *arg == 'n' || *arg == 'N' || *arg == 'o' || *arg == 'O' || *arg == 'R' || *arg == 'V') arg++;
                MDNativeDragCapability = *arg == '@';
            }
            if (MDNativeDragCapability) %init(NativeDragHooks);
        }
        MDLog(@"Native grouped drag capability %@", MDNativeDragCapability ? @"available" : @"unavailable; normal drag preserved");
        Class iconControllerClass = objc_getClass("SBIconController");
        if (iconControllerClass && class_getInstanceMethod(iconControllerClass, NSSelectorFromString(@"setIsEditing:"))) {
            %init(IconControllerHooks);
        }

        MDApplicationBackgroundObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                     usingBlock:^(__unused NSNotification *notification) {
            // Keep IDs and capability data intact while queued uninstall routes
            // (notably Web Clips and offloaded icons) finish. Hide controls now.
            MDHidePanel();
            if (!MDDeletionInProgress && MDSelectedBundleIDs.count > 0) MDClearSelection();
        }];
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
             if (!MDDeletionInProgress && MDSelectedBundleIDs.count > 0) MDClearSelection();
        }];
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            if (MDHomeScreenIsEditing(nil) && MDSelectedBundleIDs.count > 0) MDRefreshPanel();
        }];
    }
}

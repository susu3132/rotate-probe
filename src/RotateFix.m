//
//  RotateFix.m  --  阶段 1：让红果读书页可自由旋转
//
//  探测结论（来自阶段 0 实测）：
//    plist 只声明 P，但 AppDelegate 的 application:supportedInterfaceOrientationsForWindow:
//    返回 0x1a（P|LL|LR），且视频页实测能横屏 -> 第一道闸门不是障碍
//
//    读书页 VC 链：
//      0 SSRootViewController          0x02 P auto=0   <- 真正的闸门（根容器）
//      1 BDRReaderViewController       0x02 P auto=0
//      2 BDSlideViewController         0x02 P auto=0
//      3 BDRTextContentViewController  0x02 P auto=0
//
//    视频页能以 0x18 横屏，是因为它以全屏 modal 呈现，系统查询的是 modal 而非 root。
//    读书页是 root 的子 VC，系统只问 root，所以只 hook BDR 三层无效。
//
//  策略：读书页活跃时，把上述四类的 mask 放开到 0x1a、autorotate 置 YES。
//        不做强制旋转，交给重力感应自然跟随。
//
//  编译：见 .github/workflows/build.yml（macOS + Xcode SDK 交叉编译，不依赖 Theos / substrate）
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - 状态

static BOOL gEnabled = YES;      // 总开关（双击浮层切换）
static BOOL gReaderActive = NO;  // 读书页活跃标志（viewDidAppear / viewWillDisappear 维护）
static int  gHookedCount = 0;    // 成功安装的 hook 数量，用于自检

typedef UIInterfaceOrientationMask (*MaskFn)(id, SEL);
typedef BOOL (*BoolFn)(id, SEL);
typedef void (*AppearFn)(id, SEL, BOOL);

#pragma mark - 页面判定

// 递归检查 VC 链里是否有 BDR 前缀的类。深度限制防止异常结构导致栈溢出。
static BOOL hasReaderInChain(UIViewController *vc, int depth) {
    if (!vc || depth > 6) return NO;

    NSString *name = NSStringFromClass([vc class]) ?: @"";
    if ([name hasPrefix:@"BDR"]) return YES;

    for (UIViewController *child in vc.childViewControllers) {
        if (hasReaderInChain(child, depth + 1)) return YES;
    }
    if (vc.presentedViewController && hasReaderInChain(vc.presentedViewController, depth + 1)) {
        return YES;
    }
    return NO;
}

// 是否需要为 self 放开方向限制
static BOOL shouldRelax(id self) {
    if (!gEnabled) return NO;
    if (gReaderActive) return YES;

    NSString *name = NSStringFromClass([self class]) ?: @"";
    if ([name hasPrefix:@"BDR"]) return YES;

    if ([self isKindOfClass:[UIViewController class]]) {
        return hasReaderInChain((UIViewController *)self, 0);
    }
    return NO;
}

#pragma mark - hook 定义

#define DEF_MASK(NAME) \
static IMP gOrigMask_##NAME = NULL; \
static UIInterfaceOrientationMask gHookMask_##NAME(id self, SEL _cmd) { \
    if (shouldRelax(self)) return UIInterfaceOrientationMaskAllButUpsideDown; \
    return ((MaskFn)gOrigMask_##NAME)(self, _cmd); \
}

#define DEF_AUTO(NAME) \
static IMP gOrigAuto_##NAME = NULL; \
static BOOL gHookAuto_##NAME(id self, SEL _cmd) { \
    if (shouldRelax(self)) return YES; \
    return ((BoolFn)gOrigAuto_##NAME)(self, _cmd); \
}

DEF_MASK(ROOT)
DEF_AUTO(ROOT)
DEF_MASK(READER)
DEF_AUTO(READER)
DEF_MASK(SLIDE)
DEF_AUTO(SLIDE)
DEF_MASK(TEXT)
DEF_AUTO(TEXT)

// 为单个类安装 mask + autorotate 两个 hook
#define INSTALL_PAIR(NAME, CLSSTR) do { \
    Class c = NSClassFromString(@CLSSTR); \
    if (c) { \
        Method mm = class_getInstanceMethod(c, @selector(supportedInterfaceOrientations)); \
        if (mm) { \
            gOrigMask_##NAME = method_getImplementation(mm); \
            class_replaceMethod(c, @selector(supportedInterfaceOrientations), \
                                (IMP)gHookMask_##NAME, method_getTypeEncoding(mm)); \
            gHookedCount++; \
        } \
        Method ma = class_getInstanceMethod(c, @selector(shouldAutorotate)); \
        if (ma) { \
            gOrigAuto_##NAME = method_getImplementation(ma); \
            class_replaceMethod(c, @selector(shouldAutorotate), \
                                (IMP)gHookAuto_##NAME, method_getTypeEncoding(ma)); \
            gHookedCount++; \
        } \
    } \
} while (0)

#pragma mark - 读书页进出

static IMP gOrigReaderAppear = NULL;
static IMP gOrigReaderDisappear = NULL;

static void gHookReaderAppear(id self, SEL _cmd, BOOL animated) {
    gReaderActive = YES;
    if (gOrigReaderAppear) ((AppearFn)gOrigReaderAppear)(self, _cmd, animated);
}

static void gHookReaderDisappear(id self, SEL _cmd, BOOL animated) {
    gReaderActive = NO;
    if (gOrigReaderDisappear) ((AppearFn)gOrigReaderDisappear)(self, _cmd, animated);
}

static void installReaderLifecycle(void) {
    Class rc = NSClassFromString(@"BDRReaderViewController");
    if (!rc) return;

    Method m1 = class_getInstanceMethod(rc, @selector(viewDidAppear:));
    if (m1) {
        gOrigReaderAppear = method_getImplementation(m1);
        class_replaceMethod(rc, @selector(viewDidAppear:),
                            (IMP)gHookReaderAppear, method_getTypeEncoding(m1));
    }
    Method m2 = class_getInstanceMethod(rc, @selector(viewWillDisappear:));
    if (m2) {
        gOrigReaderDisappear = method_getImplementation(m2);
        class_replaceMethod(rc, @selector(viewWillDisappear:),
                            (IMP)gHookReaderDisappear, method_getTypeEncoding(m2));
    }
}

static void installAllHooks(void) {
    INSTALL_PAIR(ROOT,   "SSRootViewController");
    INSTALL_PAIR(READER, "BDRReaderViewController");
    INSTALL_PAIR(SLIDE,  "BDSlideViewController");
    INSTALL_PAIR(TEXT,   "BDRTextContentViewController");
    installReaderLifecycle();
}

#pragma mark - 浮层（调试用，双击切换总开关）

static UILabel *gLabel = nil;
static NSTimer *gTimer = nil;
static NSLayoutConstraint *gWidthConstraint = nil;
static NSArray<NSLayoutConstraint *> *gConstraints = nil;

@interface FixGestureTarget : NSObject
+ (instancetype)shared;
@end

@implementation FixGestureTarget

+ (instancetype)shared {
    static FixGestureTarget *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[FixGestureTarget alloc] init]; });
    return instance;
}

- (void)onSingleTap:(UITapGestureRecognizer *)g {
    if (gLabel) gLabel.alpha = (gLabel.alpha > 0.5) ? 0.20 : 0.92;
}

- (void)onDoubleTap:(UITapGestureRecognizer *)g {
    gEnabled = !gEnabled;
}

@end

static UIWindow *fixKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *fallback = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (!w.isKeyWindow) continue;
                if (w.windowLevel <= UIWindowLevelNormal + 10.0) return w;
                if (!fallback) fallback = w;
            }
        }
    }
    if (fallback) return fallback;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
}

static void attachLabel(UIWindow *w) {
    if (!gLabel) return;

    if (gConstraints.count) {
        [NSLayoutConstraint deactivateConstraints:gConstraints];
        gConstraints = nil;
    }
    [gLabel removeFromSuperview];
    [w addSubview:gLabel];

    gWidthConstraint = [gLabel.widthAnchor constraintEqualToConstant:320.0];
    gConstraints = @[
        [gLabel.topAnchor constraintEqualToAnchor:w.safeAreaLayoutGuide.topAnchor constant:2.0],
        [gLabel.leadingAnchor constraintEqualToAnchor:w.safeAreaLayoutGuide.leadingAnchor constant:2.0],
        gWidthConstraint,
    ];
    [NSLayoutConstraint activateConstraints:gConstraints];
    [w bringSubviewToFront:gLabel];
}

static void setupLabel(UIWindow *w) {
    if (gLabel) return;

    UILabel *l = [[UILabel alloc] init];
    l.numberOfLines = 0;
    l.font = [UIFont fontWithName:@"Menlo" size:10.0]
             ?: [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    l.layer.cornerRadius = 5.0;
    l.layer.masksToBounds = YES;
    l.userInteractionEnabled = YES;
    l.alpha = 0.92;
    l.translatesAutoresizingMaskIntoConstraints = NO;

    UITapGestureRecognizer *single = [[UITapGestureRecognizer alloc]
        initWithTarget:[FixGestureTarget shared] action:@selector(onSingleTap:)];
    [l addGestureRecognizer:single];

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:[FixGestureTarget shared] action:@selector(onDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [single requireGestureRecognizerToFail:doubleTap];
    [l addGestureRecognizer:doubleTap];

    gLabel = l;
    attachLabel(w);
}

static void tickLabel(void) {
    UIWindow *w = fixKeyWindow();
    if (!w) return;

    if (!gLabel) setupLabel(w);
    if (!gLabel) return;

    if (gLabel.superview != w) {
        attachLabel(w);
    } else {
        [w bringSubviewToFront:gLabel];
    }

    CGFloat maxWidth = w.bounds.size.width - 4.0;
    if (maxWidth < 120.0) maxWidth = 120.0;
    gWidthConstraint.constant = MIN(320.0, maxWidth);

    NSString *text = [NSString stringWithFormat:
        @"RotateFix 0.1  2tap:on/off\n"
        @"hook %d/8   state %@\n"
        @"reader %@   win %.0fx%.0f",
        gHookedCount,
        gEnabled ? @"ON" : @"OFF",
        gReaderActive ? @"YES" : @"NO",
        w.bounds.size.width, w.bounds.size.height];

    if (![text isEqualToString:gLabel.text]) {
        gLabel.text = text;
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void fixInit(void) {
    // 延迟安装，确保主二进制与阅读器 framework 的类都已注册
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installAllHooks();
        tickLabel();
        gTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
            tickLabel();
        }];
    });
}

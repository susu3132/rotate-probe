//
//  RotateFix.m  --  阶段 1 / 0.3：红果自由旋转
//
//  探测结论（阶段 0 实测）：
//    plist 只声明 P，但 AppDelegate 返回 0x1a（P|LL|LR），视频页实测能横屏
//    -> delegate 覆盖 plist，不必改 Info.plist
//
//    读书页：SSRootViewController(0x02 auto=0) -> BDRReaderViewController
//            -> BDSlideViewController -> BDRTextContentViewController  全锁竖屏
//    视频页：FQVShortVideoListViewController(0x02 auto=0) 锁竖屏
//            FQVShortVideoLandscapeViewController(0x18 auto=1) 本来就能横屏
//
//    真正的闸门是根容器 SSRootViewController —— 子 VC 被它锁住，系统只问 root。
//
//  0.3 变更：
//    1. 放开范围增加 FQVShortVideoListViewController（竖版短视频，居中两侧黑边）
//    2. hook 分项计数 + 定时重试（应对阅读器 framework 懒加载）
//    3. 浮层打印 BDRText 子树，用于判断文本容器类型与尺寸
//    4. 横屏时把文本块水平居中（transform 平移，不动约束、不影响分页）
//
//  编译：见 .github/workflows/build.yml（macOS + Xcode SDK 交叉编译，不依赖 Theos / substrate）
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - 状态

#define HOOK_SLOTS 5

static BOOL gEnabled = YES;
static BOOL gReaderActive = NO;

static int  gHookCounts[HOOK_SLOTS] = {0};
static BOOL gMaskDone[HOOK_SLOTS]    = {NO};
static BOOL gAutoDone[HOOK_SLOTS]    = {NO};

typedef UIInterfaceOrientationMask (*MaskFn)(id, SEL);
typedef BOOL (*BoolFn)(id, SEL);
typedef void (*AppearFn)(id, SEL, BOOL);

#pragma mark - 页面判定

static NSString *classNameForIndex(int idx) {
    switch (idx) {
        case 0: return @"SSRootViewController";
        case 1: return @"BDRReaderViewController";
        case 2: return @"BDSlideViewController";
        case 3: return @"BDRTextContentViewController";
        case 4: return @"FQVShortVideoListViewController";
        default: return nil;
    }
}

// 该 VC 是否是「需要放开旋转」的页面
static BOOL isRelaxTargetVC(UIViewController *vc) {
    NSString *name = NSStringFromClass([vc class]) ?: @"";
    if ([name hasPrefix:@"BDR"]) return YES;
    if ([name isEqualToString:@"FQVShortVideoListViewController"]) return YES;
    return NO;
}

// 递归查找目标页面
static BOOL hasRelaxTargetInChain(UIViewController *vc, int depth) {
    if (!vc || depth > 6) return NO;
    if (isRelaxTargetVC(vc)) return YES;

    for (UIViewController *child in vc.childViewControllers) {
        if (hasRelaxTargetInChain(child, depth + 1)) return YES;
    }
    if (vc.presentedViewController && hasRelaxTargetInChain(vc.presentedViewController, depth + 1)) {
        return YES;
    }
    return NO;
}

static BOOL shouldRelax(id self) {
    if (!gEnabled) return NO;
    if (gReaderActive) return YES;

    if ([self isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)self;
        if (isRelaxTargetVC(vc)) return YES;
        return hasRelaxTargetInChain(vc, 0);
    }
    return NO;
}

// 按类名片段查找 VC
static UIViewController *findVCContaining(UIViewController *vc, NSString *frag, int depth) {
    if (!vc || depth > 8) return nil;
    NSString *name = NSStringFromClass([vc class]) ?: @"";
    if ([name containsString:frag]) return vc;

    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *r = findVCContaining(child, frag, depth + 1);
        if (r) return r;
    }
    if (vc.presentedViewController) {
        return findVCContaining(vc.presentedViewController, frag, depth + 1);
    }
    return nil;
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
DEF_MASK(VIDEO)
DEF_AUTO(VIDEO)

static IMP *gOrigMaskSlots[HOOK_SLOTS] = {
    &gOrigMask_ROOT, &gOrigMask_READER, &gOrigMask_SLIDE, &gOrigMask_TEXT, &gOrigMask_VIDEO
};
static IMP *gOrigAutoSlots[HOOK_SLOTS] = {
    &gOrigAuto_ROOT, &gOrigAuto_READER, &gOrigAuto_SLIDE, &gOrigAuto_TEXT, &gOrigAuto_VIDEO
};
static IMP gHookMaskFns[HOOK_SLOTS] = {
    (IMP)gHookMask_ROOT, (IMP)gHookMask_READER, (IMP)gHookMask_SLIDE,
    (IMP)gHookMask_TEXT, (IMP)gHookMask_VIDEO
};
static IMP gHookAutoFns[HOOK_SLOTS] = {
    (IMP)gHookAuto_ROOT, (IMP)gHookAuto_READER, (IMP)gHookAuto_SLIDE,
    (IMP)gHookAuto_TEXT, (IMP)gHookAuto_VIDEO
};

// 安装单类 hook。类不存在或已装好时直接返回，可在定时器里反复调用做补挂。
static void installPair(int idx) {
    if (idx < 0 || idx >= HOOK_SLOTS) return;
    if (gMaskDone[idx] && gAutoDone[idx]) return;

    NSString *name = classNameForIndex(idx);
    if (!name) return;

    Class c = NSClassFromString(name);
    if (!c) return;

    if (!gMaskDone[idx]) {
        Method mm = class_getInstanceMethod(c, @selector(supportedInterfaceOrientations));
        if (mm) {
            *gOrigMaskSlots[idx] = method_getImplementation(mm);
            class_replaceMethod(c, @selector(supportedInterfaceOrientations),
                                gHookMaskFns[idx], method_getTypeEncoding(mm));
            gMaskDone[idx] = YES;
            gHookCounts[idx]++;
        }
    }
    if (!gAutoDone[idx]) {
        Method ma = class_getInstanceMethod(c, @selector(shouldAutorotate));
        if (ma) {
            *gOrigAutoSlots[idx] = method_getImplementation(ma);
            class_replaceMethod(c, @selector(shouldAutorotate),
                                gHookAutoFns[idx], method_getTypeEncoding(ma));
            gAutoDone[idx] = YES;
            gHookCounts[idx]++;
        }
    }
}

static int totalHooks(void) {
    int n = 0;
    for (int i = 0; i < HOOK_SLOTS; i++) n += gHookCounts[i];
    return n;
}

#pragma mark - 读书页进出

static IMP gOrigReaderAppear = NULL;
static IMP gOrigReaderDisappear = NULL;
static BOOL gLifecycleHooked = NO;

static void gHookReaderAppear(id self, SEL _cmd, BOOL animated) {
    gReaderActive = YES;
    if (gOrigReaderAppear) ((AppearFn)gOrigReaderAppear)(self, _cmd, animated);
}

static void gHookReaderDisappear(id self, SEL _cmd, BOOL animated) {
    gReaderActive = NO;
    if (gOrigReaderDisappear) ((AppearFn)gOrigReaderDisappear)(self, _cmd, animated);
}

static void installReaderLifecycle(void) {
    if (gLifecycleHooked) return;

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
    gLifecycleHooked = YES;
}

#pragma mark - 布局：文本块水平居中

// 找面积最大的 UITextView / UILabel
static UIView *findLargestText(UIView *root, UIView *best, int depth) {
    if (!root || depth > 7) return best;

    if ([root isKindOfClass:[UITextView class]] || [root isKindOfClass:[UILabel class]]) {
        CGFloat area = root.bounds.size.width * root.bounds.size.height;
        CGFloat bestArea = best ? (best.bounds.size.width * best.bounds.size.height) : -1.0;
        if (area > bestArea) best = root;
    }
    for (UIView *sub in root.subviews) {
        best = findLargestText(sub, best, depth + 1);
    }
    return best;
}

// 横屏时把文本块水平居中。用 transform 平移，不动约束，翻页逻辑不受影响。
static void applyHorizontalCentering(UIWindow *w) {
    if (!gEnabled) return;
    if (w.bounds.size.width <= w.bounds.size.height) return;  // 仅横屏

    UIViewController *reader = findVCContaining(w.rootViewController, @"BDRText", 0);
    if (!reader || !reader.view) return;

    UIView *text = findLargestText(reader.view, nil, 0);
    if (!text) return;

    CGRect inWindow = [text convertRect:text.bounds toView:w];
    if (inWindow.size.width <= 1.0) return;

    CGFloat dx = (w.bounds.size.width - inWindow.size.width) / 2.0 - inWindow.origin.x;
    if (dx > -1.0 && dx < 1.0) return;

    text.transform = CGAffineTransformMakeTranslation(dx, 0.0);
}

#pragma mark - 浮层

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
    l.font = [UIFont fontWithName:@"Menlo" size:9.0]
             ?: [UIFont monospacedSystemFontOfSize:9.0 weight:UIFontWeightRegular];
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

// 广度优先描述子树，最多 maxItems 个节点
static NSString *describeSubtree(UIView *root, int maxItems) {
    if (!root) return @"(nil)";

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    int n = 0;

    while (queue.count > 0 && n < maxItems) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        [lines addObject:[NSString stringWithFormat:@"%@ %.0fx%.0f",
                          NSStringFromClass([v class]),
                          v.frame.size.width, v.frame.size.height]];
        for (UIView *sub in v.subviews) [queue addObject:sub];
        n++;
    }
    return [lines componentsJoinedByString:@"\n"];
}

static void tickLabel(void) {
    UIWindow *w = fixKeyWindow();
    if (!w) return;

    // 懒加载的类在这里补挂
    for (int i = 0; i < HOOK_SLOTS; i++) installPair(i);
    installReaderLifecycle();

    if (!gLabel) setupLabel(w);
    if (!gLabel) return;

    if (gLabel.superview != w) {
        attachLabel(w);
    } else {
        [w bringSubviewToFront:gLabel];
    }

    CGFloat maxWidth = w.bounds.size.width - 4.0;
    if (maxWidth < 120.0) maxWidth = 120.0;
    gWidthConstraint.constant = MIN(330.0, maxWidth);

    // 每次刷新都尝试居中。函数内部会算 dx，已居中时 dx≈0 直接返回，
    // 这样先横屏再进读书页、或 Auto Layout 重排后偏移失效的情况都能被纠正。
    applyHorizontalCentering(w);

    UIViewController *reader = findVCContaining(w.rootViewController, @"BDRText", 0);
    NSString *tree = reader ? describeSubtree(reader.view, 5) : @"(不在读书页)";

    NSString *text = [NSString stringWithFormat:
        @"RotateFix 0.3  2tap:on/off\n"
        @"hook %d/10  %@  reader %@\n"
        @"SSRoot%d BDRRead%d BDSlide%d\n"
        @"BDRText%d FQVList%d  %.0fx%.0f\n"
        @"-- BDRText 子树 --\n%@",
        totalHooks(),
        gEnabled ? @"ON " : @"OFF",
        gReaderActive ? @"YES" : @"NO",
        gHookCounts[0], gHookCounts[1], gHookCounts[2],
        gHookCounts[3], gHookCounts[4],
        w.bounds.size.width, w.bounds.size.height,
        tree];

    if (![text isEqualToString:gLabel.text]) {
        gLabel.text = text;
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void fixInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (int i = 0; i < HOOK_SLOTS; i++) installPair(i);
        installReaderLifecycle();
        tickLabel();
        gTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
            tickLabel();
        }];
    });
}

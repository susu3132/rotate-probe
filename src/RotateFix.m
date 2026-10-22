//
//  RotateFix.m  --  0.4：深度探测 + 实验性布局
//
//  已确认事实（阶段 0 / 0.2 / 0.3 实测）：
//    plist 只有 P，delegate 返回 0x1a -> delegate 覆盖 plist，不必改 Info.plist
//    读书页锁链：SSRootViewController -> BDRReaderViewController
//                -> BDSlideViewController -> BDRTextContentViewController
//    真正闸门是根容器 SSRootViewController
//
//    BDRTextContentView 尺寸随屏幕自适应：
//      竖屏 336x654  横屏 773x225
//    但内部文字视图没有跟着重排，导致横屏时文字只占左侧、底部被裁切
//
//  0.4 变更：
//    1. 类查找兜底：NSClassFromString 失败时按类名片段遍历已注册类
//       （应对 Swift 类名带模块前缀，解决 BDRRead 0 的问题）
//    2. 浮层分别打印 BDRTextContentView 与视频页子树
//    3. 长按切换「实验布局」：
//       - 视频页：AVPlayerLayer.videoGravity = ResizeAspect（完整显示并居中）
//       - 读书页：把最宽文本视图撑到容器宽，触发重排
//
//  编译：见 .github/workflows/build.yml（macOS + Xcode SDK 交叉编译）
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - 状态

#define HOOK_SLOTS 5

static BOOL gEnabled = YES;
static BOOL gReaderActive = NO;
static BOOL gExperimental = NO;   // 长按切换

static int  gHookCounts[HOOK_SLOTS] = {0};
static BOOL gMaskDone[HOOK_SLOTS]    = {NO};
static BOOL gAutoDone[HOOK_SLOTS]    = {NO};
static int  gAttempts[HOOK_SLOTS]    = {0};

typedef UIInterfaceOrientationMask (*MaskFn)(id, SEL);
typedef BOOL (*BoolFn)(id, SEL);
typedef void (*AppearFn)(id, SEL, BOOL);

#pragma mark - 类查找

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

// 按类名片段在全部已注册类里查找，应对 Swift 类名的模块前缀
static Class findClassContaining(NSString *fragment) {
    if (fragment.length == 0) return Nil;

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;

    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return Nil;

    count = objc_getClassList(classes, count);
    Class found = Nil;
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!c) continue;
        const char *nm = class_getName(c);
        if (!nm) continue;
        NSString *name = [NSString stringWithUTF8String:nm];
        if (name && [name containsString:fragment]) {
            found = c;
            break;
        }
    }
    free(classes);
    return found;
}

static Class resolveClass(NSString *name) {
    if (name.length == 0) return Nil;
    Class c = NSClassFromString(name);
    if (c) return c;
    return findClassContaining(name);
}

#pragma mark - 页面判定

static BOOL isRelaxTargetVC(UIViewController *vc) {
    NSString *name = NSStringFromClass([vc class]) ?: @"";
    if ([name hasPrefix:@"BDR"]) return YES;
    if ([name containsString:@"FQVShortVideoListViewController"]) return YES;
    return NO;
}

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

static UIView *findViewByClassName(UIView *root, NSString *cls, int depth) {
    if (!root || depth > 9) return nil;
    if ([NSStringFromClass([root class]) isEqualToString:cls]) return root;

    for (UIView *sub in root.subviews) {
        UIView *r = findViewByClassName(sub, cls, depth + 1);
        if (r) return r;
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

static void installPair(int idx) {
    if (idx < 0 || idx >= HOOK_SLOTS) return;
    if (gMaskDone[idx] && gAutoDone[idx]) return;
    if (gAttempts[idx] > 40) return;   // 遍历全部类开销大，限次避免长期空转
    gAttempts[idx]++;

    NSString *name = classNameForIndex(idx);
    if (!name) return;

    Class c = resolveClass(name);
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
static int  gLifecycleAttempts = 0;

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
    if (gLifecycleAttempts > 40) return;
    gLifecycleAttempts++;

    Class rc = resolveClass(@"BDRReaderViewController");
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

#pragma mark - 布局：探测与实验

static UIView *findLargestText(UIView *root, UIView *best, int depth) {
    if (!root || depth > 8) return best;

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
                          v.bounds.size.width, v.bounds.size.height]];
        for (UIView *sub in v.subviews) [queue addObject:sub];
        n++;
    }
    return [lines componentsJoinedByString:@"\n"];
}

// 视频：把播放层改成等比完整显示（等比缩放 + 居中由 layer 自己处理）
static int fixVideoGravity(UIView *root, int depth) {
    if (!root || depth > 9) return 0;

    int fixed = 0;
    Class playerLayerCls = NSClassFromString(@"AVPlayerLayer");
    if (playerLayerCls && [root.layer isKindOfClass:playerLayerCls]) {
        AVPlayerLayer *pl = (AVPlayerLayer *)root.layer;
        if (![pl.videoGravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
            pl.videoGravity = AVLayerVideoGravityResizeAspect;
            fixed++;
        }
    }
    for (UIView *sub in root.subviews) {
        fixed += fixVideoGravity(sub, depth + 1);
    }
    return fixed;
}

// 书本：把最宽文本视图撑到容器宽，触发内部重排
static BOOL stretchReaderText(UIViewController *readerVC) {
    if (!readerVC || !readerVC.view) return NO;

    UIView *content = findViewByClassName(readerVC.view, @"BDRTextContentView", 0);
    if (!content) return NO;

    UIView *text = findLargestText(content, nil, 0);
    if (!text) return NO;

    CGFloat target = content.bounds.size.width;
    if (target <= 1.0) return NO;
    if (text.bounds.size.width >= target - 1.0) return NO;

    CGRect f = text.frame;
    f.size.width = target;
    text.frame = f;
    [text setNeedsLayout];
    [text layoutIfNeeded];
    return YES;
}

static void applyExperimentalLayout(UIWindow *w) {
    if (!gExperimental || !gEnabled) return;

    UIViewController *videoVC = findVCContaining(w.rootViewController, @"FQVShortVideoList", 0);
    if (videoVC && videoVC.view) {
        fixVideoGravity(videoVC.view, 0);
    }

    UIViewController *reader = findVCContaining(w.rootViewController, @"BDRText", 0);
    if (reader) {
        stretchReaderText(reader);
    }
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

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    gExperimental = !gExperimental;
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

    gWidthConstraint = [gLabel.widthAnchor constraintEqualToConstant:340.0];
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
    l.font = [UIFont fontWithName:@"Menlo" size:8.5]
             ?: [UIFont monospacedSystemFontOfSize:8.5 weight:UIFontWeightRegular];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.80];
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

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[FixGestureTarget shared] action:@selector(onLongPress:)];
    [l addGestureRecognizer:longPress];

    gLabel = l;
    attachLabel(w);
}

static void tickLabel(void) {
    UIWindow *w = fixKeyWindow();
    if (!w) return;

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
    if (maxWidth < 140.0) maxWidth = 140.0;
    gWidthConstraint.constant = MIN(340.0, maxWidth);

    applyExperimentalLayout(w);

    UIViewController *reader = findVCContaining(w.rootViewController, @"BDRText", 0);
    UIView *content = reader ? findViewByClassName(reader.view, @"BDRTextContentView", 0) : nil;
    NSString *readerTree = content ? describeSubtree(content, 6) : @"(不在读书页)";

    UIViewController *videoVC = findVCContaining(w.rootViewController, @"FQVShortVideoList", 0);
    NSString *videoTree = videoVC ? describeSubtree(videoVC.view, 5) : @"(不在视频页)";

    NSString *text = [NSString stringWithFormat:
        @"RotateFix 0.4  tap:dim 2tap:on/off hold:exp\n"
        @"hook %d/10 %@ exp %@ reader %@\n"
        @"SSR%d BDR%d SLD%d TXT%d VID%d  %.0fx%.0f\n"
        @"-- 书本 --\n%@\n"
        @"-- 视频 --\n%@",
        totalHooks(),
        gEnabled ? @"ON " : @"OFF",
        gExperimental ? @"ON" : @"OFF",
        gReaderActive ? @"Y" : @"N",
        gHookCounts[0], gHookCounts[1], gHookCounts[2], gHookCounts[3], gHookCounts[4],
        w.bounds.size.width, w.bounds.size.height,
        readerTree, videoTree];

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
        gTimer = [NSTimer scheduledTimerWithTimeInterval:0.6
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
            tickLabel();
        }];
    });
}

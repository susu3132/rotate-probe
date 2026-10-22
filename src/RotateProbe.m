//
//  RotateProbe.m  --  阶段 0：只读探测
//
//  设计原则：
//    1. 不 hook 任何方法，不修改任何返回值，不改变 App 现有行为
//    2. 只做采样：定时读取顶层 VC 链 + 各 VC 声明的方向掩码 + App 级掩码 + Info.plist
//    3. 结果同时输出到「屏幕浮层」和「沙盒日志文件」，卸载即完全恢复
//
//  目的：拿到红果「读书页」的真实 ViewController 类名，为阶段 1 的精准白名单提供依据
//
//  编译：见 .github/workflows/build.yml（macOS + Xcode 交叉编译，不依赖 Theos / substrate）
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#pragma mark - 全局状态

static UILabel *gLabel = nil;
static NSTimer *gTimer = nil;
static NSLayoutConstraint *gWidthConstraint = nil;
static NSArray<NSLayoutConstraint *> *gConstraints = nil;
static NSString *gLogPath = nil;
static CGFloat gAlpha = 0.92;
static NSUInteger gLogCount = 0;

#pragma mark - 手势

@interface ProbeGestureTarget : NSObject
+ (instancetype)shared;
@end

@implementation ProbeGestureTarget

+ (instancetype)shared {
    static ProbeGestureTarget *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[ProbeGestureTarget alloc] init];
    });
    return instance;
}

// 单击：切换透明度（0.92 <-> 0.20），不隐藏，避免点没了找不回来
- (void)onTap:(UITapGestureRecognizer *)g {
    gAlpha = (gAlpha > 0.5) ? 0.20 : 0.92;
    if (gLabel) gLabel.alpha = gAlpha;
}

// 长按：把当前浮层内容复制到剪贴板
- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = gLabel.text ?: @"";
}

@end

#pragma mark - 采样工具

// 取当前 key window。优先普通层级窗口，跳过系统 alert / statusbar 等高 level 窗口
static UIWindow *probeKeyWindow(void) {
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

// 从 rootViewController 一路向下，收集整条容器链（最多 8 层）
static NSArray<UIViewController *> *probeVCChainFrom(UIWindow *w) {
    UIViewController *vc = w.rootViewController;
    NSMutableArray<UIViewController *> *chain = [NSMutableArray array];
    int guard = 0;

    while (vc && guard++ < 8) {
        [chain addObject:vc];

        UIViewController *next = nil;
        if (vc.presentedViewController) {
            next = vc.presentedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            next = ((UINavigationController *)vc).topViewController;
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            next = ((UITabBarController *)vc).selectedViewController;
        } else if (vc.childViewControllers.count > 0) {
            next = vc.childViewControllers.lastObject;
        }

        if (!next || next == vc) break;
        vc = next;
    }
    return chain;
}

// 方向掩码转可读字符串
static NSString *probeMaskString(UIInterfaceOrientationMask m) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (m & UIInterfaceOrientationMaskPortrait) [parts addObject:@"P"];
    if (m & UIInterfaceOrientationMaskLandscapeLeft) [parts addObject:@"LL"];
    if (m & UIInterfaceOrientationMaskLandscapeRight) [parts addObject:@"LR"];
    if (m & UIInterfaceOrientationMaskPortraitUpsideDown) [parts addObject:@"PU"];
    if (parts.count == 0) [parts addObject:@"-"];
    return [NSString stringWithFormat:@"0x%02lx %@",
            (unsigned long)m, [parts componentsJoinedByString:@","]];
}

// 读 Info.plist 声明的方向（App 级硬限制）
static NSString *probePlistOrientations(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    id value = info[@"UISupportedInterfaceOrientations~iphone"]
               ?: info[@"UISupportedInterfaceOrientations"];
    if (![value isKindOfClass:[NSArray class]]) return @"?";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *s in (NSArray *)value) {
        if (![s isKindOfClass:[NSString class]]) continue;
        if ([s containsString:@"PortraitUpsideDown"])      [parts addObject:@"PU"];
        else if ([s containsString:@"Portrait"])           [parts addObject:@"P"];
        else if ([s containsString:@"LandscapeLeft"])      [parts addObject:@"LL"];
        else if ([s containsString:@"LandscapeRight"])     [parts addObject:@"LR"];
        else                                               [parts addObject:s];
    }
    return parts.count ? [parts componentsJoinedByString:@","] : @"-";
}

#pragma mark - 报告生成

static NSString *probeBuildReport(UIWindow *w) {
    NSMutableString *s = [NSMutableString string];
    UIApplication *app = [UIApplication sharedApplication];

    [s appendString:@"RotateProbe 0.1  tap:dim  hold:copy\n"];

    CGFloat scale = 1.0;
    if (@available(iOS 13.0, *)) {
        if (w.windowScene && w.windowScene.screen) scale = w.windowScene.screen.scale;
    }
    if (scale <= 0.0) scale = [UIScreen mainScreen].scale;

    [s appendFormat:@"win %.0fx%.0f @%.1fx\n",
     w.bounds.size.width, w.bounds.size.height, scale];

    // App 级：走公开的 delegate 方法。这是系统实际调用的路径，
    // 且 UIApplication 类上并没有公开声明 supportedInterfaceOrientationsForWindow:，
    // 直接对 app 发该消息无法通过编译。
    UIInterfaceOrientationMask appMask = UIInterfaceOrientationMaskAll;
    NSString *appMaskSource = @"none";
    id<UIApplicationDelegate> del = app.delegate;
    if ([del respondsToSelector:@selector(application:supportedInterfaceOrientationsForWindow:)]) {
        appMask = [del application:app supportedInterfaceOrientationsForWindow:w];
        appMaskSource = @"delegate";
    }
    [s appendFormat:@"app  %@ (%@)\n", probeMaskString(appMask), appMaskSource];
    [s appendFormat:@"plist %@\n", probePlistOrientations()];

    // 页面级：整条容器链
    NSArray<UIViewController *> *chain = probeVCChainFrom(w);
    if (chain.count == 0) {
        [s appendString:@"vc   <none>\n"];
        return s;
    }

    for (NSUInteger i = 0; i < chain.count; i++) {
        UIViewController *vc = chain[i];
        NSString *name = NSStringFromClass([vc class]) ?: @"?";
        UIInterfaceOrientationMask m = [vc supportedInterfaceOrientations];
        BOOL autorotate = [vc shouldAutorotate];

        [s appendFormat:@"%lu %@\n   %@ auto=%d\n",
         (unsigned long)i, name, probeMaskString(m), autorotate ? 1 : 0];
    }
    return s;
}

#pragma mark - 日志

static void probeLog(NSString *text) {
    if (gLogCount > 800) return;
    gLogCount++;

    if (!gLogPath) {
        NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES) firstObject];
        if (!doc) return;
        gLogPath = [doc stringByAppendingPathComponent:@"rotate_probe.log"];
    }

    static NSDateFormatter *df = nil;
    if (!df) {
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
    }

    NSString *line = [NSString stringWithFormat:@"[%@]\n%@\n---\n",
                      [df stringFromDate:[NSDate date]], text];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!fh) {
        [line writeToFile:gLogPath atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused NSException *e) {
        // 只读探测，写日志失败不应影响 App
    }
}

#pragma mark - 浮层

// 把浮层挂到指定 window 上。约束必须相对「当前」window 的 safeArea 重建，
// 否则全屏播放器换窗口后旧约束仍指向旧 window，布局会失效。
static void probeAttachLabel(UIWindow *w) {
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

static void probeSetupLabel(UIWindow *w) {
    if (gLabel) return;

    UILabel *l = [[UILabel alloc] init];
    l.numberOfLines = 0;
    l.font = [UIFont fontWithName:@"Menlo" size:10.0]
             ?: [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    l.layer.cornerRadius = 5.0;
    l.layer.masksToBounds = YES;
    l.textAlignment = NSTextAlignmentLeft;
    l.userInteractionEnabled = YES;
    l.alpha = gAlpha;
    l.translatesAutoresizingMaskIntoConstraints = NO;

    [l addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:[ProbeGestureTarget shared] action:@selector(onTap:)]];
    [l addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
        initWithTarget:[ProbeGestureTarget shared] action:@selector(onLongPress:)]];

    gLabel = l;
    probeAttachLabel(w);
}

#pragma mark - 主循环

static void probeTick(void) {
    UIWindow *w = probeKeyWindow();
    if (!w) return;

    if (!gLabel) probeSetupLabel(w);
    if (!gLabel) return;

    // key window 可能切换（全屏播放器会新建窗口），跟着搬并重建约束
    if (gLabel.superview != w) {
        probeAttachLabel(w);
    } else {
        [w bringSubviewToFront:gLabel];
    }

    CGFloat maxWidth = w.bounds.size.width - 4.0;
    if (maxWidth < 120.0) maxWidth = 120.0;
    gWidthConstraint.constant = MIN(330.0, maxWidth);

    NSString *report = probeBuildReport(w);
    if (![report isEqualToString:gLabel.text]) {
        gLabel.text = report;
        probeLog(report);
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void probeInit(void) {
    // 等 UI 起来再挂浮层
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        probeTick();
        gTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
            probeTick();
        }];
    });
}

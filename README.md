# RotateProbe — 阶段 0 只读探测

给 iPhone 13 mini / iOS 16.6.1 / TrollStore 用的探测型 dylib。

## 它做什么

**不 hook、不改返回值、不改变 App 任何行为。** 只做采样：

- 定时读取当前顶层 ViewController 链（最多 8 层）的类名
- 每个 VC 声明的 `supportedInterfaceOrientations` 与 `shouldAutorotate`
- App 级 `supportedInterfaceOrientationsForWindow:`
- `Info.plist` 里声明的方向

结果同时输出到：

1. **屏幕左上角浮层**（直接截图即可）
2. **App 沙盒** `Documents/rotate_probe.log`

浮层交互：单击切换透明度，长按复制当前内容到剪贴板。

## 为什么需要它

iOS 16 的旋转要连过三道闸门（App 级 plist → 页面级 VC → `requestGeometryUpdate`）。
红果的视频页能转、读书页不能转，说明卡点在「页面级」。

**拿到读书页的真实类名，阶段 1 才能做精准白名单**——只对读书页放行，其余页面维持原样。
不做这一步直接写全局强制旋转，等于对所有页面无差别开刀。

## 构建

无需本地环境。推到 GitHub，Actions 自动编译：

```
Settings → Actions → General → Workflow permissions
确认允许 Actions 运行
```

push 后进入 **Actions → build-rotateprobe → 最新一次运行 → Artifacts → RotateProbe-dylib**，
下载得到 `RotateProbe.dylib`（zip 内单个文件）。

编译链路：`macos-14` runner + Xcode 自带 iPhoneOS SDK + clang 交叉编译，
**不依赖 Theos，不依赖 substrate**（`otool -L` 里不会出现 `libsubstrate.dylib`，
这是 TrollStore 环境能正常加载的前提）。

## 使用

1. 把 `RotateProbe.dylib` 传到手机（AirDrop / 文件 App / iMazing 均可）
2. 打开 **TrollFools** → 找到红果 → 注入 → 选这个 dylib
3. 打开红果，依次走到：
   - 首页（记一次）
   - 短剧播放页（横过来，确认能转，记一次）
   - **读书页（关键，停留 10 秒）**
4. 每个页面截一张图（浮层内容要清晰）

## 回传内容

- 三张截图（首页 / 视频页 / 读书页）
- 如果浮层挡事：长按浮层复制，粘贴给我也行

## 卸载

TrollFools 里对该 App 移除注入即可，日志文件在 App 沙盒 `Documents/` 下，删不删都不影响。

## 注意

`TrollFools` 对 **App Store 原装应用** 的注入有前提：App 需要由 TrollStore 安装过（有 CoreTrust 豁免）。
如果 TrollFools 列表里找不到红果，或注入后 App 启动闪退，说明红果是纯 App Store 原装，
需要先用 TrollStore 重装一次（从 App Store 导出 IPA 或用已有 IPA）。

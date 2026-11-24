# MuseFrame

在 Mac 上浏览开放馆藏的绘画，把喜欢的作品设为桌面。MuseFrame 使用 SwiftUI、AppKit、SwiftData 和 WidgetKit，支持 macOS 26 及以上版本。当前版本为 **0.5.0 (10)**。

- **画廊**支持中英文搜索、艺术家与流派筛选，并根据显示器尺寸推荐适合作为壁纸的作品。默认在线搜索大都会艺术博物馆，另收录经核对的 Wikimedia Commons 作品。
- **桌面**支持填满、完整显示和居中裁切。浏览时图片只进入内存，收藏保存作品资料，实际设为桌面的画作会保存在本机。
- **艺术史**可按年代或关系浏览艺术家及作品。随包提供365条作品资料和93篇中文导览，断网时仍可阅读文字和查看已保存的壁纸。

## 从源码运行

需要 macOS 26 或更高版本以及提供 Swift 6.2 或更高版本的 Xcode 工具链。首次使用 Xcode 时先完成系统提示的组件安装。下载此仓库的源码，在解压后的目录打开终端，运行：

```sh
./scripts/build-app.sh --launch
```

脚本在你自己的 Mac 上编译并打开应用。下次可以直接在这个目录中打开 `.build/MuseFrame.app`。这个构建适合浏览、收藏和手动设置桌面。

桌面小组件和退出主程序后的自动轮换依赖系统注册及共享容器。要开发或验证这两项功能，请在 Xcode 打开 `MuseFrame.xcodeproj`，为 App、Widget 和 Helper 选择自己的开发团队，并配置该团队拥有的 Bundle ID 与 App Group。为其他团队修改标识时，需要同步调整三个 target 的签名设置、Info.plist、entitlements、共享容器标识以及 Helper 的 LaunchAgent 注册标识。完整功能需在签名安装后由系统授权。

## 内容更新

馆方提供的作品和图片直接联网加载。在「设置 → 内容」可手动更新馆藏。网络中断时保留文字与现有桌面。不同图片来源的响应速度和可用性取决于馆方。

维护者可以独立发布中文导览与精选目录。修改 `MuseFrame/Data/SeedData/seed.json` 和 `MuseFrame/Resources/ArtHistory/` 中的资料，增加修订号，生成新的静态目录：

```sh
python3 scripts/build-content.py --revision 2 --output catalog/edition.json
```

把同一个 HTTPS 地址填入「设置 → 内容 → 策展目录地址」，客户端在启动时检查更新。文件通过校验后才会替换上次可用的版本。[当前目录文件](catalog/edition.json)

## 测试和贡献

在项目目录运行测试：

```sh
./scripts/test.sh -Xswiftc -warnings-as-errors
```

欢迎通过 Issue 报告问题，请附 macOS 版本、复现步骤及预期结果。提交作品请附馆方对象页、可访问的图片链接和明确的权利标记。修改中文导览时请保留可核对的资料来源。

## 许可

程序源码及构建脚本采用 [MIT License](LICENSE)。馆藏图片、元数据、编辑文字和应用标识的使用说明见 [内容与署名](CONTENT-NOTICES.md)。

# Music Viewer for Mac

本地导入曲谱、模拟乐器演奏，并生成纸面光点动画影片的 macOS 应用。当前是可运行的开发版本；功能边界和验收缺口见 [开发记录](Docs/09-development-status.md)。

## 运行

需要 Xcode 与 Swift 6。项目使用 SwiftPM，最低部署版本为 macOS 14；当前实际运行验证仅覆盖 Apple Silicon、macOS 27.0.1。

```sh
./script/build_and_run.sh
```

脚本构建并打开 `dist/Music Viewer.app`，同时带上离线排版库、演示谱和音源。Codex 的 Run 按钮调用同一脚本。可用 `--build-only` 只构建，或 `--verify` 检查启动。尚未配置签名发布或公证。

远程仓库：[jxzy999/music-viewer](https://github.com/jxzy999/music-viewer)，SSH 地址为 `git@github.com:jxzy999/music-viewer.git`。`dist/`、`Outputs/`、构建缓存与 `files/` 中的大型参考录屏保留在本机，不纳入源码版本管理。

## 使用

1. 在首页选择内置示例，或导入 `.musicxml`、`.xml`、`.mxl`、`.scorefilm`。
2. 选择声部，在右侧指定钢琴或小提琴；“编辑段落配器”可设置小节与有理拍值范围。
3. 选择电影纸面或清晰跟谱、轨迹和运镜选项，等待准备完成后播放或定位。
4. 保存为 `.scorefilm` 工程，或导出带 AAC 音轨的 1080p、30／60 fps MP4。

制作页左上角的房子按钮可「返回首页」，快捷键为 ⌘⇧H。内置示例首次修改设置时自动创建独立工程，并保存到 `~/Library/Application Support/Music Viewer/Projects/`；回到首页可在「我的工程」继续打开。再次打开内置示例仍使用原始设置。外部未保存工程返回首页时保留恢复副本。

在首页「我的工程」中，点击对应工程最右侧的垃圾桶，或右键选择「移到废纸篓」，确认后移入系统废纸篓。正在其他窗口打开的工程需要先关闭或返回首页。误删后可从访达的废纸篓恢复，再点击「我的工程」右侧的「刷新」；如需手动放回，原目录为上述 `Music Viewer/Projects/`。内置示例、导出的影片和原始导入文件不随个人工程删除。

右侧顶部提供总音量，每个演奏轨道下的各声部还可独立调到 0%–400%。《致爱丽丝》的蓝色主旋律为声部 1，橙色伴奏为声部 5；可提升声部 1 或降低声部 5 来调整平衡。默认输出会统一提升偏小的整曲音量，并保留谱面强弱变化；松开滑杆后更新声音、保留当前播放位置，设置随用户工程保存并用于导出。

示例库提供《致爱丽丝》主题选段（钢琴独奏）、巴赫《加沃特回旋曲》主题选段（小提琴独奏），以及《欢乐颂》《绿袖子》《奇异恩典》（小提琴与钢琴合奏）。来源与改编说明见[示例曲谱说明](Sources/ScoreFilm/Resources/Examples/README.md)。

轨迹仅来自显式 slur 连奏组或 tie 延音链。普通相邻音、音源尾音和 MIDI 重叠不会生成连线。尚未验证的演奏特性会明确阻止生成不完整成片；原始 MusicXML 随工程保存。

未保存的工作写入 `~/Library/Application Support/ScoreFilm/Recovery/`，欢迎页可恢复最近一份。它是恢复副本，正常保存仍需选择工程文件。曲谱与音视频在本机处理。

## 验证与工程

```sh
swift test
python3 script/make_validation_fixtures.py
python3 script/make_validation_fixtures.py --stress
python3 script/make_validation_fixtures.py --features
python3 script/build_example_library.py
```

开发构建可通过 `--sample --fps 60 --validate /绝对路径/验收目录` 生成原生排版、帧一致性、运镜与导出记录；请先退出已有实例，再用 `open -n "dist/Music Viewer.app" --args …` 启动。验收目录须为新的目录。`python3 script/verify_movie.py /绝对路径/验收目录` 完整解码成片并检查音视频元数据与帧时间；该开发工具使用 ffmpeg／ffprobe，应用运行不需要它们。

`ScoreCore` 负责导入、时间线、关系和保存；`ScoreMedia` 负责排版适配、声音、Metal 与编码；`ScoreFilm` 负责原生窗口与操作。

方案、格式和架构在 [Docs](Docs/README.md)。第三方资源来源与许可见 [第三方说明](Docs/10-third-party-resources.md) 及应用内的许可目录。

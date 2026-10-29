# 技术决策与官方资料

## 决策记录

| 决策 | 当前选择 | 原因与复查条件 |
| --- | --- | --- |
| 首发平台 | 原生 macOS | 文档操作、较长导出任务和调试便利；后续共享核心到 iOS |
| 界面 | SwiftUI 为主，必要处 AppKit | 保留原生文档、窗口、菜单与键盘操作；不引入跨平台 UI 框架 |
| 记谱权威数据 | 原始 MusicXML 4.0 | 保留完整记谱源；应用 JSON 只补充自身功能 |
| 排版引擎 | 本地 OSMD 与 SVG 后端 | 直接面向 MusicXML，具有符头图形接口；P0 必须验证 ID、坐标与纹理输出 |
| 排版备选 | Verovio | SVG 与语义能力成熟；转换支持范围和 LGPL 分发方式需另评估 |
| 音频 | AVAudioEngine 与 AVAudioUnitSampler | 可加载 SF2 或 DLS；先验证离线事件精度，避免首版引入复杂插件宿主 |
| 预览声音 | 先合成 PCM，再播放 | 与导出复用音频，降低定位、踏板和设备时钟风险 |
| 动态画面 | Metal 与 MetalKit | 控制纸面、光轨及离屏输出；场景较轻，不需要大型游戏引擎 |
| 轨迹资格 | 显式 slur 连奏组或 tie 延音链 | 普通相邻音与分离伴奏不补线；连奏短拖尾和延音持音线分别计时，模式或覆盖不能绕过关系 |
| 视频 | Metal 离屏帧加 AVAssetWriter | 固定帧率、可等待编码、支持音轨封装，不依赖屏幕录制 |
| 项目容器 | ZIP 与 JSON 加原始曲谱 | 单文件携带，版本与资源清楚；缓存可重建 |
| 音源 | 许可明确的应用资源库 | 跨机器可重现；不依赖隐含系统文件路径 |

当前工程已固定 OSMD 2.2.1 和 GeneralUser GS 2.0.3，并随应用携带排版代码、音源和许可；具体来源、哈希与复现方法见[第三方资源与复现](10-third-party-resources.md)。本地 JS 工具使用 npm；应用运行时不依赖 Node。版本变更必须重跑排版兼容语料及导出样例。

## 备选路线的取舍

**全部使用 WebKit 与 Three.js。** 开发可视原型较快，也方便跨平台。代价是最终视频逐帧导出、WebKit 生命周期与原生音频时钟之间需要更多桥接。可以用来验证美术和轨迹，不作为当前最终导出主路线。

**全部原生从零打谱。** 动态渲染与系统整合直接，但排版涉及复杂音符避让、跨谱表、连梁、文字和多声部。首版投入应集中在音乐可视化，暂不自行重做完整打谱引擎。

**把 MuseScore 源码集成成排版和播放引擎。** 功能丰富，但需要承担大型代码库、构建依赖、接口维护和许可评估。未决定应用开源与分发方式前，不把嵌入该引擎当作默认捷径。使用用户自行从制谱软件导出的 MusicXML 则是独立的输入流程。

**Blender 后台渲染。** 能做高质量成片，但安装体积、等待时间、手机复用和嵌入式交互成本较高。只作为美术参考与离线人工制作路线，不要求本应用用户安装 Blender。

## 依赖与素材约束

OSMD 的仓库许可证采用 BSD 条款；仍需保留相应声明，并分别核对其依赖和字体资源。不能把开源排版库的许可推及付费音频组件、商标或其他附加产品。[OSMD LICENSE](https://raw.githubusercontent.com/opensheetmusicdisplay/opensheetmusicdisplay/develop/LICENSE)

Verovio 仓库包含 LGPL v3 许可证文本。若改用它，需要在实际链接和分发方式确定后核对相应义务；不预设“放进 WebView”就免除分发要求。[Verovio LICENSE](https://github.com/rism-digital/verovio/blob/develop/COPYING.LESSER)

音源的“免费下载”不等于允许打包进应用。资源登记应包含来源、版本、哈希、许可文本、是否允许再分发和必要署名。乐谱、纸纹和字体同样独立登记。原创示例仅为数据验证使用，不包含参考视频的曲谱拷贝、音频或付费模板资产。

## 官方资料

下列资料于 2026 年 10 月 28 日核对，连奏与延音资料及轨迹决策于 2026 年 10 月 29 日补充。官方接口说明支持选型可行性；本文中的模块拆分、显示参数、工期和性能指标属于本项目方案，需要后续原型验证。

| 资料 | 用途 |
| --- | --- |
| [MusicXML 4.0](https://www.w3.org/2021/06/musicxml40/) | 记谱与互换格式 |
| [MusicXML 文件结构](https://www.w3.org/2021/06/musicxml40/tutorial/structure-of-musicxml-files/) | part、小节与乐器声明 |
| [MusicXML 声音与 MIDI 对应](https://www.w3.org/2021/06/musicxml40/tutorial/midi-compatible-part/) | 声部时间、反复与声音提示 |
| [MusicXML note](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/note/) | 图形和声音语义的区别 |
| [MusicXML slur](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/slur/) | 连奏组的开始、结束与跨系统继续标记 |
| [MusicXML tied](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/tied/) | 同音延续的印刷连接，与声音 tie 的区别 |
| [MusicXML instrument](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/instrument/) | 每个音符的乐器引用 |
| [MusicXML instrument change](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/instrument-change/) | 同一乐器声明的音色变化 |
| [MusicXML swing](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/swing/) | 摇摆节奏的结构化解释 |
| [OSMD 官方介绍](https://opensheetmusicdisplay.org/) | 本地 MusicXML 排版路线 |
| [OSMD GraphicalNote](https://opensheetmusicdisplay.github.io/classdoc/classes/GraphicalNote.html) | 语义音符与图形对象 |
| [OSMD VexFlowGraphicalNote](https://opensheetmusicdisplay.github.io/classdoc/classes/VexFlowGraphicalNote.html) | 符头 SVG、图形身份与几何 |
| [Verovio 输入格式](https://book.verovio.org/toolkit-reference/input-formats.html) | MusicXML 与压缩文件支持范围 |
| [Verovio 输出格式](https://book.verovio.org/toolkit-reference/output-formats.html) | SVG、转换、MIDI 与时间映射限制 |
| [Apple AVAudioUnitSampler 音源加载](https://developer.apple.com/documentation/avfaudio/avaudiounitsampler/loadsoundbankinstrument(at:program:bankmsb:banklsb:)) | SF2、DLS 和非实时加载要求 |
| [Apple 离线音频处理](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing) | AVAudioEngine 手动离线渲染 |
| [Apple MIDI 调度](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/schedulemidieventblock) | 按采样时间提交事件 |
| [Apple AUScheduleMIDIEventBlock](https://developer.apple.com/documentation/audiotoolbox/auschedulemidieventblock) | 事件块的时间和数据参数 |
| [Apple 播放器时间转换](https://developer.apple.com/documentation/avfaudio/avaudioplayernode/playertime(fornodetime:)) | 预览媒体位置 |
| [Apple AVAssetWriter](https://developer.apple.com/documentation/avfoundation/avassetwriter) | 音视频文件封装 |
| [Apple 像素缓冲写入适配器](https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor) | 兼容较早系统的帧写入路线 |
| [Apple CVMetalTextureCache](https://developer.apple.com/documentation/corevideo/cvmetaltexturecache) | Core Video 与 Metal 纹理连接 |
| [Polyfjord Melody Visualizer 介绍](https://polyfjord.teachable.com/) | 相近的纸面光轨美术参考 |

Apple 文档部分页面通过其官方 Markdown 入口读取；本机工程已使用实际 SDK 构建并运行。导出、时钟、文件与性能的实测结论分别记录在[开发与验证记录](09-development-status.md)；未测试的系统和硬件不能由接口说明推断通过。

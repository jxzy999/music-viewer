# 第三方资源与复现

## 离线排版

应用内分发 OpenSheetMusicDisplay **2.2.1** 的 UMD 文件，来源为官方 npm 包，BSD 3-Clause；开发依赖固定在 `Tools/Notation/package.json` 和 `package-lock.json`。运行时使用本机 WKWebView，不需要 Node 或网络。

OSMD 包含 VexFlow 及其他运行依赖。相关许可随应用放在 `ScoreMedia` 资源的 `Licenses/`，应用设置中可打开此目录。文本排版当前使用系统字体；谱面字形来自固定排版库。

重新下载排版库使用：

```sh
cd Tools/Notation
npm ci --ignore-scripts --no-audit --no-fund
```

应用实际加载的是 `Sources/ScoreMedia/Resources/Notation/opensheetmusicdisplay.min.js`；更新依赖后必须同步该文件、许可和映射适配器，并重跑媒体验证。不能仅修改 npm 版本便宣称排版映射仍然兼容。

## 钢琴与小提琴

当前使用 S. Christian Collins 的 GeneralUser GS **2.0.3**，License 2.0。固定来源是作者仓库 [mrbumpy409/GeneralUser-GS](https://github.com/mrbumpy409/GeneralUser-GS)，提交 `684543d5e5efaef08d02be50dcda8d552478fa60`。应用打包的是本项目对钢琴范围数据正规化后的兼容版本。

| 资源 | SHA-256 |
| --- | --- |
| 作者原始 SF2 | `9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe` |
| 应用内 GeneralUser-GS.sf2（兼容版本） | `baaae7f10324582107051c8a23acf014d163a5118ac2e0250b3bc2fe0c0e2e40` |
| 作者 LICENSE.txt | `7b32efefdf95ce38a043799f0659853ddc00fbaa14d8c50f0aca16b9b8b405be` |

内置钢琴使用零起算 GM program 0，小提琴使用 program 40；melodic bank MSB 121、LSB 0。音源文件作为应用资源分发，不依赖用户电脑上未承诺存在的系统 DLS 路径。

本机 AUSampler 载入作者原始钢琴时，部分 preset 与 instrument 的音高／力度范围未按交集过滤，E5／力度 33 本应匹配 1 个采样却触发 19 个，最终出现后续起音被忽略的断音。`script/prepare_builtin_soundfont.py` 仅对 bank 0／program 0 的 48 个 preset local zone 追加范围已裁剪的独立 instrument；移除空交集，保留原有采样、其他生成器和调制器。原始 1056 个候选组合得到 200 个合法区域；原生导入合并为 191 层、200 个 sample zone。穷举 16256 种音高／非零力度组合，采样 ID 集合与原谱音源定义一致。其余 286 个 preset 和 PCM 字节保留。修改说明和原始许可一同放在应用的 `Licenses/`。

复现时从固定来源取得通过上表原始 SHA-256 校验的文件，然后运行：

```sh
python3 script/prepare_builtin_soundfont.py /path/to/original.sf2 Sources/ScoreMedia/Resources/GeneralUser-GS.sf2 --report /tmp/music-viewer-soundfont.json
swift test --filter PianoOnsetTests
```

脚本固定输入版本，保持原始输入文件，确定性生成兼容版本；不会调整曲谱音高、时值或 `pp` 力度。范围交集依据 [SoundFont 2.04 规范 §9.4](https://www.synthfont.com/sfspec24.pdf)。原生音源读取和《致爱丽丝》完整反复的实际 PCM 发声均有回归检查，单纯成功编码不能证明音符已经发声。

原始许可允许用于音乐创作、软件工程及修改包装，同时说明部分历史采样来源并非完全可追溯；保留完整原文，不把本轮开发验证写成已经独立审计全部采样来源。发布商业版本前仍需完成资源和完整依赖的分发复核。

## 自有语料

`Docs/Examples/Duet` 和 Paper and Light 是本项目原创演示资料；压力谱由 `script/make_validation_fixtures.py --stress` 生成，附加排版语料由 `--features` 生成，覆盖连音组、divisions 变化、同音和弦以及跨系统跨页延音。媒体测试另使用自行生成的短脉冲样本，验证采样调度、混响、分组混音与音画同步。不把参考录屏中的作品随应用作为可再分发曲谱使用。生成脚本会固定包内时间戳，使演示工程可以复现。

## 首页曲谱库

五首完整演奏示例由 `script/build_example_library.py` 确定性生成。原始来源在 `Docs/Examples/Sources/`，可读 MusicXML、工程设置、许可和完整性报告在 `Docs/Examples/Library/`，应用加载 `Sources/ScoreFilm/Resources/Examples/*.scorefilm`。每个工程都内含 `Licenses/score.txt` 与 `Metadata/completeness.json`；重新生成不访问网络、不安装依赖，不修改用户个人工程。

- 《致爱丽丝》使用全部 106 个书面小节，第一第二结尾和原谱反复展开为 127 次小节访问、1020 次起音；原速四分音符 72，音乐 156.25 秒。固定源 SHA-256 为 `f665fc5d0c8ad5c96e7e099a4bf927756d1087ea5a58d0d85816c2e8c3530f5c`。`compile_fur_elise.py` 将 3 个装饰音按明示挤占策略写为实音，将 14 处有量震音写为十六分重击；和弦一起重击，全部主音、三连音、踏板、连奏和真实音高保留。原始 OpenScore CC0 源档保持不变。
- 巴赫《加沃特回旋曲》由 `compile_bach_gavotte.py` 完整转写 102 个源小节、两声部和全部插部。6 处颤音和 1 处波音显式实音化；弱起的双声部空排版占位被压缩。基础音高与时值对照来源官方 MIDI 的 763 个事件全部匹配，源双声部另外 4 个同音事件在 MIDI 中被合并，生成版继续保留。只反复源谱开头，111 次小节访问、872 次起音，110 QPM 下约 235.636 秒。来源 Mutopia 1471，改编曲谱按 CC BY-SA 3.0。
- 《绿袖子》改用 [Mutopia 1730 的完整历史器乐变奏](https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1730)，来源为 1705 年 Playford《Division Violin》影印本，Allen Garvin 排版并贡献至公有领域。全部 15 个变奏及同源固定低音由 `compile_greensleeves.py` 合为小提琴与钢琴，保留每段原有反复，120 个书面小节、240 次访问、2076 次起音，二分音符 80，音乐 540 秒。来源 SHA-256 `67ab58455b600931aa85b06056f0611fc35468a1161c19007360804aeca14601`。第 5 变奏开头 3 音的源隐含时值使小节超出 3/2 拍，明确校正为四分音符；其余 795 个旋律时值及全部 798 个音高与官方 MIDI 相符。旧版 hymn tune 源档继续保留作来源历史，不再作为当前内置谱。
- 《欢乐颂》与《奇异恩典》在完整传统主题的基础上，由 `compile_duet_arrangements.py` 创作完整独立器乐编曲，分别 56、50 小节，约 143.954、165.869 秒；包括前奏、完整主题、答奏／对答、再现或变奏、尾声，没有增加整曲循环。小提琴和钢琴两次完整主题都与固定源旋律逐音高、时值及偏移核对。《欢乐颂》采用 Mutopia 528 公有领域 hymn 主题，新增编曲数据按 CC0 提供；《奇异恩典》基于 Mutopia 1832，改编数据继续按 CC BY-SA 3.0 提供。这不是贝多芬第九交响曲第四乐章全长版，也不把原创前尾奏称作历史原谱的缺失段落。

完整逐首署名、改动和许可见[应用内示例说明](../Sources/ScoreFilm/Resources/Examples/README.md)，设置窗口也提供入口。此说明针对曲谱数据，不是整个应用代码的许可声明。既有个人工程副本保留原内容，不随内置模板更新而被覆盖。

旧《致爱丽丝》主题工程原样保存在 `Tests/Fixtures/FurEliseTheme.scorefilm`，继续用于两处历史漏音和音量回归，不再作为可见的内置示例。Ode 与 Grace 的源主题 MusicXML 也保存在测试语料中，用于验证完整版没有截掉或改写主题；前者沿用公有领域声明，后者继续按 CC BY-SA 3.0 提供。

## 可下载的 MusicXML 资源

2026-10-29 实际核对：

| 资源 | 格式与用途 | 下载及使用说明 |
| --- | --- | --- |
| [致爱丽丝 MusicXML](https://github.com/sightreader/sheet-music/blob/master/Beethoven%20-%20Bagatelle%20No.%2025%20%28Fur%20Elise%29.musicxml) | 可直接下载 `.musicxml`；本次下载文件约 370 KB | 原文件中有 OpenScore (CC0) 与源站署名，已保留到本项目来源档案；应用示例现使用完整原曲 |
| [MusicXML 官方样例](https://www.musicxml.com/music-in-musicxml/example-set/) | `.musicxml`、`.mxl`；也有全部样例的 ZIP | 无需安装工具，逐曲下载；包含完整曲目与首页选段，部分现代作品只授予该网站展示许可，不统一视为 App 内置授权 |
| [music21 曲库目录](https://music21.org/music21docs/about/referenceCorpus.html) | 大量 `.mxl`、`.xml`，也包含其他格式 | 官方文档列出具体文件路径，可从项目曲库获取；[许可说明](https://music21.org/music21docs/moduleReference/moduleCorpus.html)要求按曲目来源理解许可，不等同于软件代码许可 |
| [PDMX](https://github.com/pnlong/PDMX) | 大规模数据集，包含 `.mxl`、PDF、MIDI 与元数据 | 从项目链接的 Zenodo 下载；优先结合 `no_license_conflict` 与 `all_valid` 筛选，保留单曲来源与许可元数据 |

Mutopia 主要提供 LilyPond、PDF 与 MIDI，并非直接 MusicXML 下载库；本项目四首来自 Mutopia 的示例经过显式转写与校验，不把 `.ly` 或 PDF 文件伪装成 `.musicxml`。能免费下载也不等于当前演奏器已经支持文件中的所有记谱特性，仍需实际解析与试听。

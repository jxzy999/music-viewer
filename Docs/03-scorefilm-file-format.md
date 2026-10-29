# 曲谱项目文件格式

## 设计目标

文件需要同时表达完整乐谱、演奏安排和视觉设置，并允许用户用一个文件带走项目。建议扩展名为 `.scorefilm`，格式名为 ScoreFilm，初始草案版本为 `1.0.0`。应用名称与最终 UTType 标识在建立工程时确定，不提前修改签名或发布配置。

**以 MusicXML 4.0 保存记谱，以项目 JSON 保存应用选项。** 不重新发明一套只有音高和时长的“全曲谱 JSON”。MusicXML 负责音符、谱表、声部、速度、力度、记谱关系和乐器声明；项目 JSON 负责覆盖配器、演奏解释、视觉效果、运镜与导出参数。[MusicXML 4.0](https://www.w3.org/2021/06/musicxml40/)

## 容器结构

`.scorefilm` 是 ZIP 容器，解包后结构如下：

```text
Example.scorefilm
├── manifest.json
├── score.musicxml
├── project.json
└── Assets/                 可选的音源与纸面素材
```

`manifest.json` 指定曲谱与设置入口、能力要求及文件哈希；不能通过扫描“第一个 XML 文件”猜测入口。单独的 `.musicxml` 和 `.mxl` 导入后自动形成此结构。MXL 先读取其 `META-INF/container.xml`，明确选择乐谱入口，再进行转换。

自动生成的语义索引、排版 SVG、音频与预览图默认存应用缓存，不作为必须随项目分发的数据。缓存缺失时应能重建。后续可以增加可选缓存目录，但读入时必须校验全部输入哈希和引擎版本。

## Manifest

字段与约束见 [manifest.schema.json](Schemas/manifest.schema.json)。主要字段如下：

| 字段 | 含义 |
| --- | --- |
| `format` | 固定为 `scorefilm` |
| `version` | 容器语义版本，当前 `1.0.0` |
| `profile` | 当前应用支持范围，初始 `scorefilm-mac-v1` |
| `projectId` | UUID，用于文档身份；内容缓存另用哈希 |
| `files.notation` | 原谱入口的容器相对路径 |
| `files.settings` | 项目设置入口的容器相对路径 |
| `integrity` | 入口及内嵌资产的 SHA-256；不包含 manifest 自身 |
| `requiredCapabilities` | 理解项目所必需的特性；未知能力阻止演奏导出 |
| `extensions` | 可选的命名空间扩展，读取后原样保存 |

示例工程中的真实哈希由文件内容生成，不能用占位哈希冒充完整性验证。

## 记谱表达与支持范围

原始 `score.musicxml` 是保存和再次导入的权威来源，不能以排版库转换后的副本覆盖它。曲谱的不可识别节点与属性通过原始字节保留；只读语义模型无须为每个未知节点建立业务对象。

| 记谱内容 | 文件如何表达 | 首版处理 |
| --- | --- | --- |
| 音高、临时记号、八度、移调乐器 | MusicXML `pitch`、`transpose` 等 | 区分印刷音高与实际音高 |
| 多声部、多谱表与和弦 | `voice`、`staff`、`backup`、`forward`、`chord` | 正确建立同时发生的事件 |
| 节奏、附点与连音组 | `duration`、`divisions`、`dot`、`time-modification`、`tuplet` | 有理数时值，不按图形距离估算时间 |
| 延音与连奏 | 声音用 `tie`，图形用 `tied` 与 `slur` | 延音链合并发声；保留各自组 ID 与端点，作为动画允许连线的依据 |
| 速度、渐变、延长记号 | 速度指示与方向标记；应用可补充确定的演奏解释 | 无明确数值时采用已显示的解释规则 |
| 力度、重音、断奏与踏板 | 对应 direction、articulations 和 pedal | 转为速度、力度、门控或控制器事件 |
| 反复、不同结尾、D.C.、D.S.、Coda、Fine | 对应 repeat、ending 与 sound 跳转信息 | 按能力语料验证；未知或矛盾跳转阻止导出 |
| 歌词、标题、指法与文字 | 保留在原谱 | 首版以排版为主，不自动生成歌声 |
| 装饰音、颤音、震音和滑音 | 原谱对应元素 | 逐特性声明演奏支持；不得静默忽略 |
| 打击乐、微分音、吉他谱和特殊记谱 | 保留原始表达 | 格式可承载；未验证的排版或声音能力明确告警或阻止 |

首版采用常规对齐小节轴。自由节拍、各声部不同小节边界的复杂复合结构须单独验证；不能靠“MusicXML 能写出来”推断排版和演奏已经支持。

## 稳定身份与全曲拍轴

每个音符需要稳定 `sourceNoteId`，每个小节需要稳定 ID。原谱已有合法 ID 时保留；缺失时，归一化工作副本生成确定的 ID，另保留“原始位置到归一化 ID”的映射。不能把排版库的临时 SVG ID 写成唯一曲谱身份。

`scoreAxis.referencePartId` 指定全曲位置的参考 part。`ScorePosition` 写作：

```json
{
  "measureId": "p1-m3",
  "beat": { "n": 1, "d": 2 }
}
```

它表示参考 part 的 `p1-m3` 小节内，从零开始的二分之一个四分音符拍。小节编号文本可能重复或出现弱起编号，故不能用显示的“第 3 小节”代替内部 ID。其他 part 的事件先对齐到全曲拍轴，再应用同一个范围。

范围采用 `[from, to)`，左闭右开。可用末小节内 `beat = 小节总拍数` 表示全曲终点。分数分母必须为正，数值约分，使用 Int64 并检查运算溢出。不能把三连音的三分之一拍持久化成 `0.333333`。

反复发生后，一份印刷音符产生多次 `PerformanceOccurrence`。路由范围默认作用于该源谱范围的所有演奏次数；首版不提供“只在第二遍换乐器”的界面。该功能未来通过明确的 occurrence 选择能力扩展，不能挪用小节编号猜测播放次数。

## 乐器与配器

`instruments` 定义可复用的声音配置，`partInstruments` 定义 part 的默认选择，`routes` 覆盖某个 part、voice 或 staff 在某段源谱中的选择。乐器实例、逻辑声部和 MIDI channel 是不同概念。

```json
{
  "id": "lead-after-m3",
  "selector": { "partId": "P1", "voiceId": "1" },
  "range": {
    "from": { "measureId": "p1-m3", "beat": { "n": 0, "d": 1 } },
    "to": { "measureId": "p1-m4", "beat": { "n": 4, "d": 1 } }
  },
  "instrumentId": "violin",
  "priority": 100
}
```

这个范围把旋律从第三小节开始交给小提琴，其他 part 可继续由钢琴演奏。完整例子见 [project.json](Examples/Duet/project.json)。

解析顺序为：匹配覆盖路由，选择最高 `priority`；没有覆盖时使用 `partInstruments`；仍未选择时，尝试解析原谱的逐音符乐器与默认乐器声明。相同优先级的重叠路由视为歧义并报告错误，不靠数组顺序决定结果。未映射到可用音源的乐器必须由用户确认替代，不能静默改成钢琴。

`partInstruments` 表示用户选择的整 part 覆盖。导入具有多种乐器的 part 时，不能仅根据第一个音符自动填入此覆盖，否则会抹平原谱的乐器变化。保留原谱配器时，该 part 不写入覆盖，由逐音符乐器声明解析到应用的可用音源。

MusicXML 支持在 part 内声明多个 `score-instrument`，并通过音符的 `instrument` 引用进行区分。[官方 instrument 定义](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/instrument/)。导入器要把这种信息带入配器层，而不是一整个 part 只读一次 program。

规则还需满足：

- 一个音符在开始时绑定合成实例，note off 和踏板释放始终发往该实例。
- 延音链按第一次起音确定乐器，中途路由变化默认不重新触发；用户需要重新起音时必须明确断开延音或设置未来的重新演奏覆盖。
- 换乐器预先加载新实例，旧实例保留到尾音结束；不在仍有发声音符的同一 sampler 上直接换 program。
- 同一音高的并发音符使用独立实例或明确的复音槽位，不能用一个不区分身份的 note off 把另一个音符一起关闭。
- JSON 的 program 为 `0...127`；MusicXML 的 `midi-program` 是 `1...128`，边界转换只做一次。
- 声部颜色默认按音乐身份保持，不因换成小提琴就自动换颜色。

首版 bank 支持应用内置资源键和容器内嵌的 SF2 或 DLS。`piano-v1`、`violin-v1` 已分别映射到随应用分发的 GeneralUser GS 钢琴与小提琴音源，版本与哈希见[资源登记](10-third-party-resources.md)。使用内嵌资源时提供相对路径及哈希，并声明来源与分发许可。[Apple 音源加载接口](https://developer.apple.com/documentation/avfaudio/avaudiounitsampler/loadsoundbankinstrument(at:program:bankmsb:banklsb:))

## 演奏与视觉设置

`performance` 保存默认速度、速度比例、延长记号解释及固定随机种子；可选 `tempoOverrides` 在全曲拍轴上补充速度点。所有 QPM 都以四分音符每分钟为单位；复合拍的附点四分音符速度需要先换算。

速度覆盖点与原谱速度点合并，同位置用户覆盖优先；重复的用户覆盖点报错。`step` 保持到下一速度点，`linearQPM` 在曲谱拍轴上插值到下一个明确速度点，最后一个速度点之后保持恒速。人性化偏移对同一和弦共享时间偏移，不拆散延音链；以 occurrence ID 与固定 seed 生成，限制在不改变必要事件顺序的范围内。

`visual` 保存纸面风格、按声部配色、轨迹历史长度、同时显示的轨迹数量、延音脉冲以及逐音符覆盖。`camera` 保存运镜预设、关注的 part、前瞻时长和运动幅度；`export` 保存尺寸、帧率、编解码、采样率与尾音。Schema 中列出的字段是当前草案的规范字段，未来镜头逐段编辑通过版本化能力补充。

轨迹遵守统一的音乐资格条件：候选端点属于同一次有效 slur 连奏组，或是 tie 延音链中明确相接的符头。普通相邻音、无关系的重复音、音色、音量、长时值与 MIDI 重叠均不能单独创建连接。显式休止处不跨接，跨页显示分段但保留组身份；无法解析关系时报告并只显示光点。

`trailMode = off` 关闭全部发光连接；`auto` 自动显示并控制合格连接的密度；`travel` 尽量保留合格连接，也不能绕过音乐资格和几何约束。`noteOverrides[].trail` 只关闭或调整该音符出发的合格连接，不能强制给关系之外补线，全局 `off` 优先。`trailHistoryMS` 仅控制连奏短拖尾的历史长度；tie 持音线按对应延音区间显现、保持和衰减，不按该毫秒数裁短。`sustainMode` 控制符头持续高光，不单独触发连线；`repeatNoteMode = loop` 仅用于已合格且位置重合的 slur 连接，其他重复音使用脉冲。

颜色 selector 优先采用约束更多的匹配项，例如 part 加 voice 加 staff 优先于只指定 part；同等具体程度的冲突报错。Schema 可以存储更宽范围的画幅和有理帧率，但 `scorefilm-mac-v1` 的产品导出仅开放已验证的 1080p、30 或 60 fps；语法合法不代表当前编码能力可用。更高规格需能力校验并明确报告，不静默降级。

音源缓存、排版坐标和生成后的镜头曲线均为派生数据，不能代替原始设置。仅改光点颜色时不应重新合成音频。

## 校验和保存

校验分为容器、JSON Schema、XML 结构、语义引用、特性兼容与资源可用性六层。JSON Schema 不负责证明曲谱 ID 存在、范围顺序正确、多个声部时间对齐或音源实际可播放。

最低输入保护为：拒绝 ZIP 路径穿越、符号链接和外部路径；限制解包大小、条目数及压缩比；禁用 XML 外部实体与网络访问；拒绝 SVG 脚本和远程资产。建议初始上限为 100 MB 乐谱、500 MB 工程解包总量和 10000 个条目，音源大包在后续以独立资源库处理。这些是可调整的产品限制，不是已测性能结论。

保存时先写完整临时容器、回读入口和哈希，再原子替换目标。自动保存也遵守此流程；取消导入或导出不能覆盖用户原文件。

未知 major 版本禁止覆盖保存；未知 minor 字段或命名空间扩展原样保留。已知 major 的兼容读取也必须检查 `requiredCapabilities`。未知必需能力可以显示项目元数据，但不能冒充完整播放或导出。

## 首版实现补充

`performance` 新增可选 `mutedPartIds` 与 `soloPartIds` 数组，缺失时为空；静音优先，不压缩时间或改变音乐连接资格。Schema 与开发记录已同步。

可选的 `performance.reverbWetDryMix` 表示总线混响比例，范围 0 至 100，缺失时采用 12；0 关闭混响。它与原始音符、踏板共同离线合成，进入音频缓存 key，不改变轨迹资格。钢琴双谱表共用同一物理延音踏板，谱表编号只定位踏板符号；需要独立踏板时使用不同逻辑 part。

原谱缺失 GM program 或音符引用了未声明的乐器时，保留记谱并要求明确的声部或段落配器；不默认改为钢琴。

MusicXML 的 `<sound>` 既可位于小节，也可位于 direction；其声音偏移优先于 direction 偏移。导入器处理这两种形式的速度、力度与完整踩下／释放踏板，未验证的半踏板及声音切换会报告。依据为 [MusicXML sound 定义](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/sound/)。

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

当前使用 S. Christian Collins 的 GeneralUser GS **2.0.3**，License 2.0。固定来源是作者仓库 [mrbumpy409/GeneralUser-GS](https://github.com/mrbumpy409/GeneralUser-GS)，提交 `684543d5e5efaef08d02be50dcda8d552478fa60`。

| 资源 | SHA-256 |
| --- | --- |
| GeneralUser-GS.sf2 | `9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe` |
| 作者 LICENSE.txt | `7b32efefdf95ce38a043799f0659853ddc00fbaa14d8c50f0aca16b9b8b405be` |

内置钢琴使用零起算 GM program 0，小提琴使用 program 40；melodic bank MSB 121、LSB 0。音源文件作为应用资源分发，不依赖用户电脑上未承诺存在的系统 DLS 路径。

原始许可允许用于音乐创作、软件工程及修改包装，同时说明部分历史采样来源并非完全可追溯；保留完整原文，不把本轮开发验证写成已经独立审计全部采样来源。发布商业版本前仍需完成资源和完整依赖的分发复核。

## 自有语料

`Docs/Examples/Duet` 和 Paper and Light 是本项目原创演示资料；压力谱由 `script/make_validation_fixtures.py --stress` 生成，附加排版语料由 `--features` 生成，覆盖连音组、divisions 变化、同音和弦以及跨系统跨页延音。媒体测试另使用自行生成的短脉冲样本，验证采样调度、混响、分组混音与音画同步。不把参考录屏中的作品随应用作为可再分发曲谱使用。生成脚本会固定包内时间戳，使演示工程可以复现。

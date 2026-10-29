# Music Viewer 示例曲谱

曲谱数据与应用代码分别管理。以下示例由 Music Viewer 根据列明来源改编为结构化 MusicXML，并制作钢琴／小提琴演奏设置。完整曲调不等于原作的全部乐章；巴赫一首明确为主题选段。

| 示例 | 来源与署名 | 改动与许可 |
| --- | --- | --- |
| 致爱丽丝 · WoO 59 | L. van Beethoven；OpenScore (CC0)，https://musescore.com/score/4053926 ；MusicXML 镜像：https://github.com/sightreader/sheet-music/blob/master/Beethoven%20-%20Bagatelle%20No.%2025%20%28Fur%20Elise%29.musicxml | 保留开头主题及双谱表；仅重复该主题，移除第一结尾括号并让末小节补足弱起；速度设为四分音符 66；源排版标注 CC0，https://creativecommons.org/publicdomain/zero/1.0/ |
| 加沃特回旋曲 · BWV 1006 | J. S. Bach；Hajo Dezelski，Mutopia-2008/07/13-1471；https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1471 | 小提琴主题选段；保留双音声部，省略装饰音，调整弱起首尾并重新标注乐句；改编曲谱数据按 CC BY-SA 3.0 提供 |
| 欢乐颂 | L. van Beethoven；Peter Chubb，Mutopia-2009/08/05-528；https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=528 | 源排版由排版者贡献至公有领域；取完整 16 小节主题，四声部改为小提琴主旋律与钢琴三声部和声，添加乐句标记 |
| 绿袖子 | 英国传统旋律；Steve Dunlop，Mutopia-2014/03/30-1247；https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1247 | 源排版由排版者贡献至公有领域；保留完整曲调，将四声部安排为小提琴与钢琴，添加乐句标记 |
| 奇异恩典 | 传统旋律；Breizh Partitions，Mutopia-2012/02/12-1832；https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1832 | 从该风笛改编版保留完整旋律及 9/8 拍，省略风笛装饰音，加入钢琴伴奏与乐句标记；改编曲谱数据按 CC BY-SA 3.0 提供 |

CC BY-SA 3.0 许可链接：https://creativecommons.org/licenses/by-sa/3.0/ 。每个 `.scorefilm` 也内含 `Licenses/score.txt`，用户副本继续保留此说明。署名不表示原作者或排版者为本应用背书；来源资料按原样提供，不保证没有排版或音乐错误。

《Rush E》未纳入本次示例库，按用户最终选择使用《致爱丽丝》钢琴独奏主题替代。当前支持 MusicXML、MXL 与 `.scorefilm`；PDF 和 MIDI 需要先转换为支持的结构化曲谱。

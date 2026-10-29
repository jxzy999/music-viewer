import Foundation

struct ExampleScore: Identifiable {
    let id: String
    let title: String
    let composer: String
    let ensemble: String
    let detail: String
    let filename: String
    let source: URL

    static let all: [Self] = [
        .init(id: "fur-elise", title: "致爱丽丝", composer: "L. van Beethoven · WoO 59", ensemble: "钢琴独奏", detail: "主题选段 · 熟悉的钢琴旋律，双谱表与反复演奏。", filename: "FurElise.scorefilm", source: URL(string: "https://github.com/sightreader/sheet-music/blob/master/Beethoven%20-%20Bagatelle%20No.%2025%20%28Fur%20Elise%29.musicxml")!),
        .init(id: "bach-gavotte", title: "加沃特回旋曲", composer: "J. S. Bach · BWV 1006", ensemble: "小提琴独奏", detail: "主题选段 · 保留双音声部，省略装饰音，体验连奏与反复。", filename: "BachGavotte.scorefilm", source: URL(string: "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1471")!),
        .init(id: "ode-to-joy", title: "欢乐颂", composer: "L. van Beethoven", ensemble: "小提琴 + 钢琴", detail: "完整主题 · 旋律由小提琴演奏，钢琴承担三声部和声。", filename: "OdeToJoy.scorefilm", source: URL(string: "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=528")!),
        .init(id: "greensleeves", title: "绿袖子", composer: "英国传统旋律", ensemble: "小提琴 + 钢琴", detail: "完整曲调 · 6/8 拍，弱起与流动的多声部伴奏。", filename: "Greensleeves.scorefilm", source: URL(string: "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1247")!),
        .init(id: "amazing-grace", title: "奇异恩典", composer: "传统旋律 · 改编版", ensemble: "小提琴 + 钢琴", detail: "完整曲调 · 保留 9/8 拍主题，省略风笛装饰音并加入钢琴。", filename: "AmazingGrace.scorefilm", source: URL(string: "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1832")!)
    ]
}

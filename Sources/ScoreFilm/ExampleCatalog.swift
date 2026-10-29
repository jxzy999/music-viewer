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
        .init(id: "fur-elise", title: "致爱丽丝", composer: "L. van Beethoven · WoO 59", ensemble: "钢琴独奏", detail: "完整原曲 · 106 小节，约 2 分 36 秒，保留全部中段与原谱反复。", filename: "FurElise.scorefilm", source: URL(string: "https://github.com/sightreader/sheet-music/blob/master/Beethoven%20-%20Bagatelle%20No.%2025%20%28Fur%20Elise%29.musicxml")!),
        .init(id: "bach-gavotte", title: "加沃特回旋曲", composer: "J. S. Bach · BWV 1006", ensemble: "小提琴独奏", detail: "完整乐章 · 102 小节，约 3 分 56 秒，含全部插部、双音与装饰音。", filename: "BachGavotte.scorefilm", source: URL(string: "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1471")!),
        .init(id: "ode-to-joy", title: "欢乐颂", composer: "L. van Beethoven", ensemble: "小提琴 + 钢琴", detail: "完整二重奏编曲 · 56 小节，约 2 分 24 秒，前奏、主题、答奏、变奏与尾声。", filename: "OdeToJoy.scorefilm", source: URL(string: "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=528")!),
        .init(id: "greensleeves", title: "绿袖子：十五段变奏", composer: "英国传统旋律 · Playford 1705", ensemble: "小提琴 + 钢琴", detail: "历史器乐全本 · 15 段不同变奏与固定低音，约 9 分钟，保留原谱反复。", filename: "Greensleeves.scorefilm", source: URL(string: "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1730")!),
        .init(id: "amazing-grace", title: "奇异恩典", composer: "传统旋律 · 改编版", ensemble: "小提琴 + 钢琴", detail: "完整二重奏编曲 · 50 小节，约 2 分 46 秒，前奏、完整主题、器乐对答与尾声。", filename: "AmazingGrace.scorefilm", source: URL(string: "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1832")!)
    ]
}

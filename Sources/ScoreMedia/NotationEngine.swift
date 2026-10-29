import Foundation
import WebKit
import ScoreCore

@MainActor
public final class NotationEngine: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var navigation: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?

    public func layout(score: ScoreDocument, settings: LayoutSettings) async throws -> LayoutSnapshot {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1600), configuration: configuration)
        web.navigationDelegate = self
        webView = web
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                navigation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.fail(ScoreError.invalid("本地排版页面加载超时，可以重试。"))
                }
                web.loadFileURL(MediaResources.notationRoot.appendingPathComponent("index.html"), allowingReadAccessTo: MediaResources.notationRoot)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
        }
        try Task.checkCancellation()
        let output = try await web.callAsyncJavaScript("return await window.scorefilm.layout(xml, options);", arguments: ["xml": score.normalizedXML, "options": ["scale": settings.staffScale, "paper": settings.paper, "orientation": settings.orientation, "preserveBreaks": settings.preserveSourceBreaks]], in: nil, contentWorld: .page)
        try Task.checkCancellation()
        guard let result = output as? [String: Any], let rawPages = result["pages"] as? [[String: Any]], let rawAnchors = result["anchors"] as? [[String: Any]] else { throw ScoreError.invalid("排版结果不完整。") }
        let anchorData = try JSONSerialization.data(withJSONObject: rawAnchors)
        let anchors = try JSONDecoder().decode([LayoutAnchor].self, from: anchorData)
        let pages = try rawPages.enumerated().map { index, page in
            guard let width = page["width"] as? Double, let height = page["height"] as? Double, let base64 = page["png"] as? String, let data = Data(base64Encoded: base64), width > 0, height > 0 else { throw ScoreError.invalid("无法生成乐谱页面图像。") }
            return LayoutPage(index: index, width: width, height: height, png: data)
        }
        guard pages.count <= 128, anchors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.radius.isFinite && pages.indices.contains($0.page) && $0.radius > 0 }) else { throw ScoreError.invalid("排版页数或符头坐标超出范围。") }
        let mapped = Dictionary(anchors.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = score.notes.filter { !$0.isRest && mapped[$0.id] == nil }.map(\.id)
        guard !pages.isEmpty else { throw ScoreError.invalid("排版引擎没有生成页面。") }
        return LayoutSnapshot(pages: pages, anchors: mapped, missingNoteIDs: missing, mappingIssues: result["issues"] as? [String] ?? [])
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.cancel(); timeout = nil
        self.navigation?.resume(); self.navigation = nil
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(ScoreError.invalid("排版进程已退出，请重试。")) }
    private func fail(_ error: any Error) {
        timeout?.cancel(); timeout = nil
        navigation?.resume(throwing: error); navigation = nil; webView?.stopLoading()
    }
}

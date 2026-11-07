import UIKit
import WebKit
import UserNotifications

/// WKWebView 壳：离线加载内置看板，用 URLSession 取官方快照后注入页面（绕开 CORS），
/// 并把关注条目转成系统本地通知（提前 30 分钟）。
final class ViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

    private let bridgeName = "wf"
    private let endpoint = URL(string: "https://api.warframe.com/cdn/worldState.php")!
    private var webView: WKWebView!
    private var pageReady = false
    private var didRequestInitial = false
    private var pendingJSON: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        let background = UIColor(red: 10 / 255, green: 14 / 255, blue: 19 / 255, alpha: 1)
        view.backgroundColor = background

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: bridgeName)

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = background
        web.scrollView.backgroundColor = background
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)

        // 占满全屏，页面自身用 env(safe-area-inset-*) 处理状态栏与底部安全区
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(requestRefresh), for: .valueChanged)
        web.scrollView.refreshControl = control
        webView = web

        loadBundledPage()
    }

    private func loadBundledPage() {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "warframe-worldstate", withExtension: "html")
            ?? bundle.url(forResource: "warframe-worldstate", withExtension: "html", subdirectory: "Resources")
        guard let fileURL = url else {
            showMessage("内置页面缺失：warframe-worldstate.html 没有打进 Bundle")
            return
        }
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .lightGray
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8)
        ])
    }

    @objc private func requestRefresh() {
        var request = URLRequest(url: endpoint,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
                         forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var result: String?
            if error == nil,
               let data = data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let text = String(data: data, encoding: .utf8),
               text.contains("\"Time\"") {
                result = text
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.webView.scrollView.refreshControl?.endRefreshing()
                if let result = result {
                    self.inject(result)
                } else {
                    self.report("在线刷新失败，当前显示内置快照")
                }
            }
        }.resume()
    }

    private func jsLiteral(_ text: String) -> String? {
        guard let data = try? JSONEncoder().encode(text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func report(_ message: String) {
        guard let literal = jsLiteral(message) else { return }
        webView.evaluateJavaScript("window.setWorldStateStatus && window.setWorldStateStatus(\(literal));") { _, _ in }
    }

    private func inject(_ jsonText: String) {
        pendingJSON = jsonText
        attemptInject()
    }

    private func attemptInject() {
        guard pageReady, let jsonText = pendingJSON, let literal = jsLiteral(jsonText) else { return }
        pendingJSON = nil
        webView.evaluateJavaScript("window.applyWorldState && window.applyWorldState(\(literal));") { _, error in
            if let error = error { NSLog("worldstate inject failed: %@", error.localizedDescription) }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageReady = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        if !didRequestInitial {
            didRequestInitial = true
            requestRefresh()
        }
        attemptInject()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showMessage("页面加载失败：\(error.localizedDescription)")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "refresh":
            requestRefresh()
        case "permission":
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        case "stars":
            schedule(body["items"] as? [[String: Any]] ?? [])
        default:
            break
        }
    }

    /// 关注条目 -> 系统本地通知，即使 App 没打开也能在到期前 30 分钟提醒
    private func schedule(_ items: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for item in items {
            guard let id = item["id"] as? String,
                  let label = item["label"] as? String,
                  let expiry = item["exp"] as? NSNumber else { continue }
            let fire = expiry.doubleValue / 1000.0 - 30 * 60
            guard fire > Date().timeIntervalSince1970 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Warframe 即将到期"
            content.body = label + " · 30 分钟内到期"
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: Date(timeIntervalSince1970: fire)
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: "wf." + id, content: content, trigger: trigger)
            center.add(request) { error in
                if let error = error { NSLog("local notification failed: %@", error.localizedDescription) }
            }
        }
    }
}

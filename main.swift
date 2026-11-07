import AppKit
import SwiftUI

// MARK: - Model

enum Provider: String {
    case codex = "Codex"
    case grok = "Grok"
}

struct QuotaWindow {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
}

struct UsageInfo {
    var lifetimeTokens = 0
    var peakDailyTokens = 0
    var currentStreakDays = 0
    var days: [String: Int] = [:]
}

struct AccountQuota: Identifiable {
    let id: String
    let provider: Provider
    var name: String
    var plan = ""
    var weekly: QuotaWindow?
    var session: QuotaWindow?
    var resetCards = 0
    var resetExpiry: Date?
    var usage = UsageInfo()
    var prepaid: Double?
    var productUsage: [(name: String, percent: Double)] = []
    var error: String?

    var remaining: Double? {
        guard let w = weekly else { return nil }
        return max(0, min(100, 100 - w.usedPercent))
    }

    var weekStart: Date? {
        guard let w = weekly, let reset = w.resetsAt else { return nil }
        return reset.addingTimeInterval(-Double(w.windowMinutes) * 60)
    }

    var weekTokens: Int {
        guard let start = weekStart else { return 0 }
        let startDay = Calendar.current.startOfDay(for: start)
        var total = 0
        for (key, value) in usage.days {
            if let date = dayKeyFormatter.date(from: key), date >= startDay {
                total += value
            }
        }
        return total
    }

    var last7: [(date: Date, tokens: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [(Date, Int)] = []
        for i in stride(from: 6, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -i, to: today)!
            let key = dayKeyFormatter.string(from: day)
            out.append((day, usage.days[key] ?? 0))
        }
        return out
    }
}

// MARK: - Helpers

let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    return f
}()

func intVal(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
func dblVal(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
func strVal(_ v: Any?) -> String? { v as? String }

func quotaColor(_ remaining: Double?) -> NSColor {
    guard let r = remaining else { return .systemGray }
    if r >= 50 { return .systemGreen }
    if r >= 20 { return .systemOrange }
    return .systemRed
}

func quotaSwiftColor(_ remaining: Double?) -> Color {
    guard let r = remaining else { return .gray }
    if r >= 50 { return .green }
    if r >= 20 { return .orange }
    return .red
}

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 100_000_000 { return String(format: "%.2f亿", d / 100_000_000) }
    if d >= 10_000 { return String(format: "%.1f万", d / 10_000) }
    return "\(n)"
}

func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var seg = String(parts[1])
    seg = seg.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while seg.count % 4 != 0 { seg += "=" }
    guard let data = Data(base64Encoded: seg),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let exp = intVal(obj["exp"]) else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(exp))
}

func findCodex() -> (path: String, args: [String]) {
    let candidates = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        NSHomeDirectory() + "/.local/bin/codex",
        NSHomeDirectory() + "/.npm-global/bin/codex",
    ]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
        return (c, ["app-server"])
    }
    return ("/usr/bin/env", ["codex", "app-server"])
}

func httpGET(_ urlStr: String, headers: [String: String], timeout: TimeInterval = 15) -> Result<(Int, Data), FetchFailure> {
    guard let url = URL(string: urlStr) else { return .failure(FetchFailure(message: "非法 URL")) }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let sem = DispatchSemaphore(value: 0)
    var status = 0
    var body = Data()
    var failure: Error?
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err { failure = err }
        else {
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            body = data ?? Data()
        }
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
        return .failure(FetchFailure(message: "请求超时"))
    }
    if let failure = failure { return .failure(FetchFailure(message: failure.localizedDescription)) }
    return .success((status, body))
}

struct FetchFailure: Error { let message: String }

final class LineReader {
    private let fh: FileHandle
    private var buf = Data()
    init(_ fh: FileHandle) { self.fh = fh }

    func next() -> String? {
        while true {
            if let idx = buf.firstIndex(of: 0x0a) {
                let slice = buf[buf.startIndex..<idx]
                buf = buf[buf.index(after: idx)...]
                var s = String(decoding: slice, as: UTF8.self)
                if s.hasSuffix("\r") { s.removeLast() }
                return s
            }
            let chunk = fh.availableData
            if chunk.isEmpty { return nil }
            buf.append(chunk)
        }
    }
}

// MARK: - Codex client

enum CodexClient {
    static func fetch() -> AccountQuota {
        let (codexPath, codexArgs) = findCodex()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: codexPath)
        proc.arguments = codexArgs
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch {
            var a = AccountQuota(id: "codex", provider: .codex, name: "Codex")
            a.error = "无法启动 codex: \(error.localizedDescription)"
            return a
        }

        let reader = LineReader(stdoutPipe.fileHandleForReading)
        let writer = stdinPipe.fileHandleForWriting

        func send(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            writer.write(line.data(using: .utf8)!)
        }

        send(["id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "codex_usage_bar", "title": "Codex Usage Bar", "version": "1.1.0"]]])

        var rateResult: [String: Any]?
        var usageResult: [String: Any]?
        var initialized = false
        let deadline = Date().addingTimeInterval(25)

        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: watchdog)

        while Date() < deadline {
            guard let line = reader.next() else { break }
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let id = intVal(msg["id"])
            if id == 1 && !initialized {
                initialized = true
                send(["method": "initialized", "params": [:]])
                send(["id": 10, "method": "account/rateLimits/read"])
                send(["id": 11, "method": "account/usage/read"])
            } else if id == 10 {
                rateResult = msg["result"] as? [String: Any]
                if usageResult != nil { break }
            } else if id == 11 {
                usageResult = msg["result"] as? [String: Any]
                if rateResult != nil { break }
            }
        }
        watchdog.cancel()
        if proc.isRunning { proc.terminate() }

        guard let rl = rateResult else {
            var a = AccountQuota(id: "codex", provider: .codex, name: "Codex")
            a.error = "读取 Codex 额度失败"
            return a
        }

        let byId = rl["rateLimitsByLimitId"] as? [String: Any]
        let codex = byId?["codex"] as? [String: Any] ?? rl["rateLimits"] as? [String: Any] ?? rl
        let plan = strVal(codex["planType"]) ?? strVal(rl["planType"]) ?? ""
        let accountId = strVal(rl["accountId"]) ?? "default"

        func window(_ raw: Any?) -> QuotaWindow? {
            guard let d = raw as? [String: Any],
                  let used = dblVal(d["usedPercent"]),
                  let mins = intVal(d["windowDurationMins"]) else { return nil }
            let reset = intVal(d["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return QuotaWindow(usedPercent: used, windowMinutes: mins, resetsAt: reset)
        }

        let primary = window(codex["primary"])
        let secondary = window(codex["secondary"])
        let all = [primary, secondary].compactMap { $0 }

        var acct = AccountQuota(id: "codex:" + accountId, provider: .codex, name: "Codex")
        acct.plan = plan
        acct.weekly = all.first { $0.windowMinutes >= 10080 } ?? primary
        acct.session = all.first { $0.windowMinutes == 300 }

        if let rc = rl["rateLimitResetCredits"] as? [String: Any] {
            acct.resetCards = intVal(rc["availableCount"]) ?? 0
            if let credits = rc["credits"] as? [[String: Any]] {
                let exps = credits.compactMap { intVal($0["expiresAt"]) }.filter { $0 > 0 }.sorted()
                if let first = exps.first {
                    acct.resetExpiry = Date(timeIntervalSince1970: TimeInterval(first))
                }
            }
        }

        if let usage = usageResult {
            if let summary = usage["summary"] as? [String: Any] {
                acct.usage.lifetimeTokens = intVal(summary["lifetimeTokens"]) ?? 0
                acct.usage.peakDailyTokens = intVal(summary["peakDailyTokens"]) ?? 0
                acct.usage.currentStreakDays = intVal(summary["currentStreakDays"]) ?? 0
            }
            if let buckets = usage["dailyUsageBuckets"] as? [[String: Any]] {
                for b in buckets {
                    if let d = strVal(b["startDate"]), let t = intVal(b["tokens"]) {
                        acct.usage.days[d] = t
                    }
                }
            }
        }
        return acct
    }
}

// MARK: - Grok client

struct GrokHome {
    let path: String
    let email: String
    let userID: String
    let token: String
    let expiry: Date?
    let mtime: Date
}

enum GrokClient {
    static func discover() -> [GrokHome] {
        let home = NSHomeDirectory()
        var dirs = Set<String>()
        if let env = ProcessInfo.processInfo.environment["GROK_HOME"], !env.isEmpty {
            dirs.insert(env)
        }
        if let items = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for name in items where name == ".grok" || name.hasPrefix(".grok") {
                dirs.insert(home + "/" + name)
            }
        }

        var byUser: [String: GrokHome] = [:]
        for dir in dirs {
            let authPath = dir + "/auth.json"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: authPath),
                  let mtime = attrs[.modificationDate] as? Date,
                  let data = FileManager.default.contents(atPath: authPath),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for (_, value) in obj {
                guard let a = value as? [String: Any],
                      let key = strVal(a["key"]),
                      let uid = strVal(a["user_id"]) else { continue }
                let gh = GrokHome(path: dir,
                                  email: strVal(a["email"]) ?? uid,
                                  userID: uid,
                                  token: key,
                                  expiry: jwtExpiry(key),
                                  mtime: mtime)
                if let cur = byUser[uid] {
                    if mtime > cur.mtime { byUser[uid] = gh }
                } else {
                    byUser[uid] = gh
                }
                break
            }
        }
        return byUser.values.sorted { $0.email < $1.email }
    }

    static func fetch(_ gh: GrokHome) -> AccountQuota {
        var acct = AccountQuota(id: "grok:" + gh.userID, provider: .grok, name: gh.email)

        if let exp = gh.expiry, exp.timeIntervalSinceNow < 60 {
            acct.error = "登录已过期，运行一次 grok 刷新"
            return acct
        }

        let result = httpGET("https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: [
            "Authorization": "Bearer \(gh.token)",
            "x-grok-client-version": "1.0.77",
            "x-grok-client-mode": "cli",
            "Accept": "application/json",
        ])

        switch result {
        case .failure(let err):
            acct.error = "Grok 额度读取失败：\(err.message)"
            return acct
        case .success(let (status, data)):
            if status == 401 {
                acct.error = "登录已过期，运行一次 grok 刷新"
                return acct
            }
            guard status == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let config = root["config"] as? [String: Any] else {
                acct.error = "Grok 额度返回异常 (HTTP \(status))"
                return acct
            }

            let used = dblVal(config["creditUsagePercent"]) ?? 0
            var resetsAt: Date?
            var minutes = 10080
            if let period = config["currentPeriod"] as? [String: Any] {
                let start = parseISO(strVal(period["start"]) ?? "")
                let end = parseISO(strVal(period["end"]) ?? "")
                resetsAt = end
                if let s = start, let e = end {
                    minutes = max(1, Int(e.timeIntervalSince(s) / 60))
                }
            }
            acct.weekly = QuotaWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt)
            acct.plan = "SuperGrok"

            if let balance = (config["prepaidBalance"] as? [String: Any]).flatMap({ dblVal($0["val"]) }) {
                acct.prepaid = balance / 100
            }
            if let products = config["productUsage"] as? [[String: Any]] {
                for p in products {
                    if let name = strVal(p["product"]), let pct = dblVal(p["usagePercent"]) {
                        acct.productUsage.append((name, pct))
                    }
                }
            }
            if let onDemand = (config["onDemandCap"] as? [String: Any]).flatMap({ dblVal($0["val"]) }), onDemand > 0 {
                acct.productUsage.append(("OnDemandCap", onDemand))
            }
            return acct
        }
    }

    static func fetchAll() -> [AccountQuota] {
        discover().map { fetch($0) }
    }
}

// MARK: - App model

final class AppModel: ObservableObject {
    @Published var accounts: [AccountQuota] = []
    @Published var errorText: String?
    @Published var loading = false
    @Published var fetchedAt: Date?
    @Published var selectedID: String?

    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "usage.fetch", qos: .utility)
    private var busy = false

    init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedAccountID")
    }

    var worstRemaining: Double? {
        accounts.compactMap { $0.remaining }.min()
    }

    var worstAccount: AccountQuota? {
        accounts.filter { $0.remaining != nil }.min { ($0.remaining ?? 0) < ($1.remaining ?? 0) }
    }

    var activeAccount: AccountQuota? {
        if let id = selectedID, let a = accounts.first(where: { $0.id == id }) { return a }
        return worstAccount ?? accounts.first
    }

    func select(_ id: String) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: "selectedAccountID")
        objectWillChange.send()
        onUpdate?()
    }

    var ordered: [AccountQuota] {
        let providerOrder: [Provider: Int] = [.codex: 0, .grok: 1]
        return accounts.sorted {
            let pa = providerOrder[$0.provider] ?? 9
            let pb = providerOrder[$1.provider] ?? 9
            if pa != pb { return pa < pb }
            return ($0.remaining ?? 999) < ($1.remaining ?? 999)
        }
    }

    func refresh() {
        if busy { return }
        busy = true
        if accounts.isEmpty { loading = true }
        queue.async {
            var result: [AccountQuota] = [CodexClient.fetch()]
            result.append(contentsOf: GrokClient.fetchAll())
            DispatchQueue.main.async {
                self.accounts = result
                self.errorText = nil
                self.fetchedAt = Date()
                self.loading = false
                self.busy = false
                self.onUpdate?()
            }
        }
    }
}

// MARK: - Status bar ring rendering

func statusRingImage(percent: Double?, size: CGFloat = 17) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let line: CGFloat = 2.6
        let inset = line / 2 + 0.6
        let r = rect.insetBy(dx: inset, dy: inset)
        let bg = NSBezierPath(ovalIn: r)
        NSColor.labelColor.withAlphaComponent(0.20).setStroke()
        bg.lineWidth = line
        bg.stroke()

        if let pct = percent {
            let frac = CGFloat(max(0, min(100, pct)) / 100)
            if frac > 0.001 {
                let fg = NSBezierPath()
                fg.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                             radius: r.width / 2,
                             startAngle: 90,
                             endAngle: 90 - 360 * frac,
                             clockwise: true)
                quotaColor(pct).setStroke()
                fg.lineWidth = line
                fg.lineCapStyle = .round
                fg.stroke()
            }
        }
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - SwiftUI views

func providerColor(_ p: Provider) -> Color {
    switch p {
    case .codex: return .indigo
    case .grok: return .teal
    }
}

struct RingView: View {
    let remaining: Double?
    let lineWidth: CGFloat
    let diameter: CGFloat

    var body: some View {
        let frac = CGFloat((remaining ?? 0) / 100)
        let color = quotaSwiftColor(remaining)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, frac))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: frac)
            VStack(spacing: 0) {
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: diameter < 80 ? 15 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

struct MiniBarChart: View {
    let data: [(date: Date, tokens: Int)]
    let tint: Color
    private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        let maxVal = max(data.map { $0.tokens }.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(data.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(item.tokens == 0 ? Color.primary.opacity(0.08) : tint.opacity(0.8))
                        .frame(height: max(2, 34 * CGFloat(item.tokens) / CGFloat(maxVal)))
                        .frame(maxWidth: .infinity)
                    Text(weekdayNames[Calendar.current.component(.weekday, from: item.date) - 1])
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: 46)
    }
}

func resetLine(_ w: QuotaWindow?) -> String {
    guard let w = w, let reset = w.resetsAt else { return "重置时间未知" }
    let f = DateFormatter()
    f.dateFormat = "M月d日 HH:mm"
    let interval = reset.timeIntervalSinceNow
    var countdown = ""
    if interval > 0 {
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let mins = (Int(interval) % 3600) / 60
        if days > 0 { countdown = "剩 \(days)天\(hours)小时" }
        else if hours > 0 { countdown = "剩 \(hours)小时\(mins)分" }
        else { countdown = "剩 \(mins)分" }
    }
    return "\(f.string(from: reset)) 重置 · \(countdown)"
}

struct AccountCard: View {
    let acct: AccountQuota
    let isWorst: Bool
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                RingView(remaining: acct.remaining,
                         lineWidth: 7,
                         diameter: 62)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(acct.provider.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(providerColor(acct.provider).opacity(0.18)))
                            .foregroundStyle(providerColor(acct.provider))
                        if !acct.plan.isEmpty {
                            Text(acct.plan.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .foregroundStyle(.secondary)
                        }
                        if isWorst {
                            Text("最紧张")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(quotaSwiftColor(acct.remaining).opacity(0.18)))
                                .foregroundStyle(quotaSwiftColor(acct.remaining))
                        }
                        if isSelected {
                            Text("菜单栏")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(providerColor(acct.provider).opacity(0.2)))
                                .foregroundStyle(providerColor(acct.provider))
                        }
                    }
                    Text(acct.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("已用 \(Int((acct.weekly?.usedPercent ?? 0).rounded()))% · \(resetLine(acct.weekly))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let err = acct.error {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            } else {
                if acct.provider == .codex {
                    HStack(spacing: 8) {
                        statPill("本周 Token", fmtTokens(acct.weekTokens), .blue)
                        statPill("重置卡", "\(acct.resetCards) 张", .indigo)
                        statPill("累计", fmtTokens(acct.usage.lifetimeTokens), .primary)
                    }
                    MiniBarChart(data: acct.last7, tint: quotaSwiftColor(acct.remaining))
                        .padding(.top, 2)
                } else {
                    HStack(spacing: 8) {
                        if let prepaid = acct.prepaid, prepaid > 0 {
                            statPill("预付余额", String(format: "%.2f", prepaid), .teal)
                        }
                        if let gb = acct.productUsage.first(where: { $0.name == "GrokBuild" }) {
                            statPill("GrokBuild", "\(Int(gb.percent.rounded()))%", quotaSwiftColor(100 - gb.percent))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.10 : (hover ? 0.075 : 0.045)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? providerColor(acct.provider).opacity(0.85)
                        : (hover ? Color.primary.opacity(0.18) : Color.clear),
                        lineWidth: isSelected ? 1.6 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onTap() }
        .onHover { hovering in hover = hovering }
    }

    private func statPill(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(quotaSwiftColor(model.worstRemaining))
                Text("用量看板")
                    .font(.system(size: 15, weight: .bold))
                Text("\(model.accounts.count) 个账号")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(model.loading ? 360 : 0))
                        .animation(model.loading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: model.loading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("刷新")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 10) {
                    if model.accounts.isEmpty {
                        Text(model.loading ? "读取中…" : "暂无账号")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        ForEach(model.ordered) { acct in
                            AccountCard(acct: acct,
                                        isWorst: acct.id == model.worstAccount?.id,
                                        isSelected: acct.id == model.activeAccount?.id,
                                        onTap: { model.select(acct.id) })
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            HStack {
                Text("点击卡片切换菜单栏账号 · " + (model.fetchedAt.map { "更新于 \(timeString($0))" } ?? (model.loading ? "读取中…" : "暂无数据")))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 8)
        }
        .frame(width: 380, height: 620)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}



// MARK: - App delegate

final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var statusItem: NSStatusItem!
    var panel: UsagePanel!
    var timer: Timer?
    var outsideMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = statusRingImage(percent: nil)
            button.imagePosition = .imageLeading
            button.title = " --"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let host = NSHostingController(rootView: DashboardView(model: model))
        let p = UsagePanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 620),
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        p.contentViewController = host
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isMovable = false
        p.acceptsMouseMovedEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel = p

        model.onUpdate = { [weak self] in self?.updateStatusItem() }

        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.model.refresh()
        }

        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.togglePopover(nil)
            }
        }
    }

    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let active = model.activeAccount
        let remaining = active?.remaining
        button.image = statusRingImage(percent: remaining)
        button.title = remaining.map { " \(Int($0.rounded()))%" } ?? " --"
        button.toolTip = model.ordered
            .map { acct in
                let mark = acct.id == active?.id ? "● " : "   "
                return "\(mark)\(acct.provider.rawValue) \(acct.name): \(acct.remaining.map { "\(Int($0.rounded()))%" } ?? "—")"
            }
            .joined(separator: "\n")
    }

    @objc func togglePopover(_ sender: Any?) {
        if panel.isVisible { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = statusItem.button, let win = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = win.convertToScreen(buttonRect)
        let size = panel.frame.size
        var x = screenRect.midX - size.width / 2
        var y = screenRect.minY - size.height - 6
        if let screen = win.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = max(vf.minX + 8, min(x, vf.maxX - size.width - 8))
            y = max(vf.minY + 8, min(y, vf.maxY - size.height - 8))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self = self else { return }
                if self.panel.frame.contains(NSEvent.mouseLocation) { return }
                self.closePopover()
            }
        }
        model.refresh()
    }

    func closePopover() {
        panel.orderOut(nil)
        if let monitor = outsideMonitor {
            NSEvent.removeMonitor(monitor)
            outsideMonitor = nil
        }
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--probe") {
    let codex = CodexClient.fetch()
    print("### Codex")
    print(" id=\(codex.id) plan=\(codex.plan) remaining=\(codex.remaining.map { "\(Int($0))%" } ?? "nil") reset=\(codex.weekly?.resetsAt.map { "\($0)" } ?? "nil") weekTokens=\(codex.weekTokens) cards=\(codex.resetCards) err=\(codex.error ?? "-")")
    print("### Grok")
    for g in GrokClient.fetchAll() {
        print(" id=\(g.id) name=\(g.name) remaining=\(g.remaining.map { "\(Int($0))%" } ?? "nil") reset=\(g.weekly?.resetsAt.map { "\($0)" } ?? "nil") prepaid=\(g.prepaid.map { String(format: "%.2f", $0) } ?? "-") products=\(g.productUsage.map { "\($0.name):\(Int($0.percent))%" }) err=\(g.error ?? "-")")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

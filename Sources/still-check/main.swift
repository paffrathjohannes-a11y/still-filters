import AppKit
import StillFilterKit
import WebKit

// still-check – Konvertieren und Prüfen von Safari-Content-Blockern mit echtem WebKit.
//
//   still-check convert --out ads.json [--max 150000] <Liste|URL> …
//       Filterlisten → Safari-JSON. Prüft das Ergebnis mit WebKit und entfernt Regeln, die WebKit ablehnt.
//
//   still-check verify [--report <Ordner>] [--no-sites] [--must-load host,host,…] <blocker.json> …
//       Testseite + echte Seiten mit und ohne Blocker. Exit-Code 1, wenn eine aussagekräftige Prüfung scheitert.
//       --must-load: diese Hosts dürfen als Hauptseite nicht geblockt werden (harte Prüfung).

let usage = """
Aufruf:
  still-check convert --out <datei.json> [--max N] <liste|url> ...
  still-check verify [--report <ordner>] [--no-sites] [--video-script <youtube-main.js>] [--must-load host,host] <blocker.json> ...
"""

@MainActor
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else { print(usage); return 2 }
        var rest = Array(args.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
            let value = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
            return value
        }
        func flag(_ name: String) -> Bool {
            guard let i = rest.firstIndex(of: name) else { return false }
            rest.remove(at: i)
            return true
        }

        switch command {
        case "convert":
            guard let out = option("--out") else { print(usage); return 2 }
            let max = option("--max").flatMap(Int.init) ?? SafariConverter.safariRuleLimit
            return await convert(inputs: rest, out: URL(fileURLWithPath: out), max: max)
        case "verify":
            let report = option("--report").map { URL(fileURLWithPath: $0) }
            let sites = !flag("--no-sites")
            let videoScript = option("--video-script").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            let mustLoad = option("--must-load").map { $0.split(separator: ",").map(String.init) } ?? []
            return await verify(files: rest.map { URL(fileURLWithPath: $0) }, report: report, sites: sites,
                                videoScript: videoScript, mustLoad: mustLoad)
        default:
            print(usage)
            return 2
        }
    }

    static func readLines(_ input: String) async throws -> [Substring] {
        let text: String
        if input.hasPrefix("http://") || input.hasPrefix("https://"), let url = URL(string: input) {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = try String(contentsOfFile: input, encoding: .utf8)
        }
        return text.split(whereSeparator: \.isNewline)
    }

    static func convert(inputs: [String], out: URL, max: Int) async -> Int32 {
        var lines: [Substring] = []
        for input in inputs {
            do {
                let read = try await readLines(input)
                print("gelesen: \(input) (\(read.count) Zeilen)")
                lines += read
            } catch {
                print("FEHLER beim Lesen von \(input): \(error.localizedDescription)")
                return 1
            }
        }
        let start = Date()
        let result = SafariConverter.convert(lines: lines, maxRules: max)
        let runner = WebKitRunner()
        let validated = await runner.validate(result.rules, id: "convert")
        var stats = result.stats
        stats.safariRules = validated.valid.count
        try? runner.encode(validated.valid).write(to: out, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(stats).write(to: out.deletingPathExtension().appendingPathExtension("stats.json"))

        if stats.discardedOverLimit > 0 {
            print("WARNUNG: \(stats.discardedOverLimit) Netzwerkregeln über dem Safari-Limit von \(max) verworfen – die Liste ist unvollständig!")
        }
        print("Safari-Regeln: \(validated.valid.count) (von WebKit abgelehnt und entfernt: \(validated.removed.count), über Limit: \(stats.discardedOverLimit))")
        print("Quellregeln: \(stats.networkRules) Netzwerk, \(stats.cosmeticRules) Ausblenden; nicht abbildbar: \(stats.unsupportedTotal)")
        for (reason, count) in stats.unsupported.sorted(by: { $0.value > $1.value }).prefix(8) {
            print("  \(reason): \(count)")
        }
        for rule in validated.removed.prefix(5) { print("  abgelehnt: \(rule.action.selector ?? rule.trigger.urlFilter)") }
        print(String(format: "Dauer: %.1f s", Date().timeIntervalSince(start)))
        return 0
    }

    static func verify(files: [URL], report: URL?, sites: Bool, videoScript: String?, mustLoad: [String] = []) async -> Int32 {
        let runner = WebKitRunner()
        var lists: [WKContentRuleList] = []
        var header: [String] = []
        var results: [CheckResult] = []
        for (index, file) in files.enumerated() {
            guard let json = try? String(contentsOf: file, encoding: .utf8) else {
                results.append(CheckResult(name: "Liste \(file.lastPathComponent)", passed: false, details: ["nicht lesbar"]))
                continue
            }
            let count = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])?.count ?? 0
            do {
                lists.append(try await runner.compile(json, id: "verify-\(index)"))
                results.append(CheckResult(name: "Liste \(file.lastPathComponent) kompiliert", passed: count <= SafariConverter.safariRuleLimit,
                                           details: ["\(count) Regeln (Safari-Limit 150.000)"]))
            } catch {
                results.append(CheckResult(name: "Liste \(file.lastPathComponent) kompiliert", passed: false, details: [error.localizedDescription]))
            }
            header.append("\(file.lastPathComponent): \(count) Regeln")
        }

        let verifier = Verifier(runner: runner, lists: lists)
        results += await verifier.testPage()
        if !mustLoad.isEmpty { results += await verifier.mainFrames(mustLoad) }
        if sites { results += await verifier.realSites() }
        if let videoScript { results += await VideoCheck(runner: runner, script: videoScript).run() }

        let failed = results.filter { $0.meaningful && !$0.passed }
        let markdown = Report.markdown(results: results, header: header)
        print(markdown)
        if let report {
            try? FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
            try? markdown.write(to: report.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try? encoder.encode(results).write(to: report.appendingPathComponent("report.json"))
        }
        return failed.isEmpty ? 0 : 1
    }
}

enum Report {
    static func markdown(results: [CheckResult], header: [String]) -> String {
        let failed = results.filter { $0.meaningful && !$0.passed }.count
        var lines = ["# Still – Blocker-Prüfung \(Date().formatted(date: .numeric, time: .shortened))", ""]
        lines.append(failed == 0 ? "**Ergebnis: alles greift.**" : "**Ergebnis: \(failed) Prüfung(en) fehlgeschlagen.**")
        lines.append("")
        lines += header.map { "- \($0)" }
        lines.append("")
        for result in results {
            let mark = !result.meaningful ? "➖" : (result.passed ? "✅" : "❌")
            lines.append("\(mark) **\(result.name)**\(result.meaningful ? "" : " (nicht aussagekräftig)")")
            lines += result.details.map { "   - \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

// Zeilenweise ausgeben, damit Protokolle auch bei einem Abbruch vollständig sind
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// Wachhund auf eigenem Thread: greift auch, wenn der Hauptthread blockiert ist (z. B. durch einen Systemdialog)
DispatchQueue.global().asyncAfter(deadline: .now() + 15 * 60) {
    print("ABBRUCH: still-check lief länger als 15 Minuten")
    exit(3)
}
Task { @MainActor in
    let code = await CLI.run(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
app.run()

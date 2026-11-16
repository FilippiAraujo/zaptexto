// ZapTexto — transcreve os áudios do WhatsApp da conversa que você abre.
// Lê o banco local do WhatsApp (somente leitura) e usa o reconhecimento de fala da Apple, no próprio Mac.

import AppKit
import SwiftUI
import SQLite3
import Speech
import AVFoundation
import ServiceManagement

let waContainer = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
let dbPath = waContainer.appendingPathComponent("ChatStorage.sqlite").path
let waBundleIDs: Set<String> = ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]

// MARK: - Banco do WhatsApp

struct AudioMsg {
    let id: Int64
    let chatId: Int64
    let chatName: String
    let sender: String?
    let date: Date
    let path: String?
    let fromMe: Bool
}

final class WADB {
    private var db: OpaquePointer?

    func open() -> Bool {
        if db != nil { return true }
        guard (try? FileManager.default.contentsOfDirectory(atPath: waContainer.path)) != nil else { return false }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { db = nil; return false }
        sqlite3_busy_timeout(db, 2000)
        return scalar("SELECT count(*) FROM ZWACHATSESSION") != nil
    }

    private func query(_ sql: String, _ args: [Int64] = [], _ row: (OpaquePointer) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { sqlite3_bind_int64(st, Int32(i + 1), a) }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }

    private func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        let s = String(cString: c)
        return s.isEmpty ? nil : s
    }

    func scalar(_ sql: String) -> Int64? {
        var v: Int64?
        query(sql) { v = sqlite3_column_int64($0, 0) }
        return v
    }

    /// Não lidas por conversa.
    func unreadCounts() -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        query("SELECT Z_PK, ZUNREADCOUNT FROM ZWACHATSESSION") { out[sqlite3_column_int64($0, 0)] = Int(sqlite3_column_int64($0, 1)) }
        return out
    }

    func maxMessageId() -> Int64 { scalar("SELECT max(Z_PK) FROM ZWAMESSAGE") ?? 0 }

    private let audioSelect = """
        SELECT m.Z_PK, m.ZCHATSESSION, c.ZPARTNERNAME,
               COALESCE(gm.ZCONTACTNAME, gm.ZFIRSTNAME, m.ZPUSHNAME),
               m.ZMESSAGEDATE, mi.ZMEDIALOCALPATH, m.ZISFROMME, c.ZSESSIONTYPE
        FROM ZWAMESSAGE m
        JOIN ZWACHATSESSION c ON c.Z_PK = m.ZCHATSESSION
        LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
        LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
        WHERE m.ZMESSAGETYPE = 3
        """

    private func audios(_ whereSQL: String, _ args: [Int64]) -> [AudioMsg] {
        var out: [AudioMsg] = []
        query(audioSelect + " " + whereSQL, args) { st in
            let isGroup = sqlite3_column_int64(st, 7) == 1
            out.append(AudioMsg(
                id: sqlite3_column_int64(st, 0),
                chatId: sqlite3_column_int64(st, 1),
                chatName: text(st, 2) ?? "Conversa",
                sender: isGroup ? text(st, 3) : nil,
                date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 4)),
                path: text(st, 5).map { waContainer.appendingPathComponent("Message").appendingPathComponent($0).path },
                fromMe: sqlite3_column_int64(st, 6) == 1))
        }
        return out
    }

    /// Áudios entre as últimas `k` mensagens recebidas da conversa (as que estavam não lidas).
    func unreadAudios(chat: Int64, k: Int) -> [AudioMsg] {
        audios("""
            AND m.Z_PK IN (SELECT Z_PK FROM ZWAMESSAGE WHERE ZCHATSESSION = ?1 AND ZISFROMME = 0
                           ORDER BY ZSORT DESC LIMIT ?2)
            ORDER BY m.ZSORT
            """, [chat, Int64(k)])
    }

    func lastAudios(chat: Int64, n: Int) -> [AudioMsg] {
        audios("AND m.ZCHATSESSION = ?1 ORDER BY m.ZSORT DESC LIMIT ?2", [chat, Int64(n)]).reversed()
    }

    func incomingAudios(after id: Int64) -> [AudioMsg] {
        audios("AND m.Z_PK > ?1 AND m.ZISFROMME = 0 ORDER BY m.Z_PK", [id])
    }

    func audio(id: Int64) -> AudioMsg? { audios("AND m.Z_PK = ?1", [id]).first }

    /// Conversas com áudio mais recentes, para o menu.
    func recentAudioChats(limit: Int) -> [(id: Int64, name: String)] {
        var out: [(Int64, String)] = []
        query("""
            SELECT c.Z_PK, c.ZPARTNERNAME, max(m.ZMESSAGEDATE) d
            FROM ZWAMESSAGE m JOIN ZWACHATSESSION c ON c.Z_PK = m.ZCHATSESSION
            WHERE m.ZMESSAGETYPE = 3 GROUP BY c.Z_PK ORDER BY d DESC LIMIT ?1
            """, [Int64(limit)]) { out.append((sqlite3_column_int64($0, 0), text($0, 1) ?? "Conversa")) }
        return out
    }
}

// MARK: - Transcrição (Apple Speech, no aparelho)

enum TranscribeError: LocalizedError {
    case noFFmpeg, convert, locale
    var errorDescription: String? {
        switch self {
        case .noFFmpeg: "ffmpeg não encontrado (brew install ffmpeg)"
        case .convert: "não consegui converter o áudio"
        case .locale: "português não disponível no reconhecimento de fala"
        }
    }
}

actor Transcriber {
    private let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func transcribe(path: String) async throws -> String {
        guard let ffmpeg else { throw TranscribeError.noFFmpeg }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: wav) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-loglevel", "error", "-y", "-i", path, "-ar", "16000", "-ac", "1", wav.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TranscribeError.convert }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "pt-BR"))
        else { throw TranscribeError.locale }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> String in
            var out = ""
            for try await r in transcriber.results where r.isFinal { out += String(r.text.characters) }
            return out
        }
        let file = try AVAudioFile(forReading: wav)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Estado

@MainActor
final class Store: ObservableObject {
    enum Status: Equatable { case waiting, working, done, failed(String) }

    struct Item: Identifiable {
        let id: Int64
        let chat: String
        let sender: String?
        let fromMe: Bool
        let date: Date
        var text: String = ""
        var status: Status = .waiting
    }

    @Published var items: [Item] = []
    var onNewItem: (() -> Void)?

    let db: WADB
    private let transcriber = Transcriber()
    private var chain: Task<Void, Never>?
    private var cache: [String: String] = [:]
    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZapTexto", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcricoes.json")
    }()

    init(db: WADB) {
        self.db = db
        if let d = try? Data(contentsOf: cacheURL),
           let c = try? JSONDecoder().decode([String: String].self, from: d) { cache = c }
    }

    func enqueue(_ audios: [AudioMsg]) {
        var added = false
        for a in audios where !items.contains(where: { $0.id == a.id }) {
            var item = Item(id: a.id, chat: a.chatName, sender: a.sender, fromMe: a.fromMe, date: a.date)
            if let t = cache[String(a.id)] {
                item.text = t
                item.status = .done
                items.insert(item, at: 0)
            } else {
                items.insert(item, at: 0)
                let prev = chain
                chain = Task { [weak self] in
                    await prev?.value
                    await self?.process(a)
                }
            }
            added = true
        }
        if items.count > 100 { items.removeLast(items.count - 100) }
        if added { onNewItem?() }
    }

    private func update(_ id: Int64, _ f: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { f(&items[i]) }
    }

    private func process(_ a: AudioMsg) async {
        // O áudio pode ainda estar baixando: espera até ~45 s.
        var path = a.path
        for _ in 0..<30 {
            if let p = path, FileManager.default.fileExists(atPath: p) { break }
            try? await Task.sleep(for: .seconds(1.5))
            path = db.audio(id: a.id)?.path
        }
        guard let path, FileManager.default.fileExists(atPath: path) else {
            update(a.id) { $0.status = .failed("áudio não baixado") }
            return
        }
        update(a.id) { $0.status = .working }
        do {
            let text = try await transcriber.transcribe(path: path)
            let final = text.isEmpty ? "(sem fala reconhecida)" : text
            update(a.id) { $0.text = final; $0.status = .done }
            cache[String(a.id)] = final
            if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
        } catch {
            update(a.id) { $0.status = .failed(error.localizedDescription) }
        }
    }
}

// MARK: - Detecção da conversa aberta

/// Sem Acessibilidade: quando o WhatsApp está em primeiro plano e uma conversa passa de
/// "N não lidas" para 0, foi você que abriu ela. Áudios que chegam depois nessa mesma
/// conversa (já aberta) também são transcritos.
@MainActor
final class Watcher {
    let store: Store
    var enabled = true
    private var prevUnread: [Int64: Int] = [:]
    private var lastMsgId: Int64 = 0
    private var openChat: Int64?
    private var timer: Timer?

    init(store: Store) { self.store = store }

    func start() {
        prevUnread = store.db.unreadCounts()
        lastMsgId = store.db.maxMessageId()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func setOpenChat(_ id: Int64) { openChat = id }

    private func tick() {
        let db = store.db
        let unread = db.unreadCounts()
        let maxId = db.maxMessageId()
        let waFront = waBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")

        if enabled && waFront {
            for (chat, now) in unread where now == 0 {
                if let before = prevUnread[chat], before > 0 {
                    openChat = chat
                    store.enqueue(db.unreadAudios(chat: chat, k: before))
                }
            }
            if maxId > lastMsgId, let open = openChat {
                let fresh = db.incomingAudios(after: lastMsgId).filter { $0.chatId == open && (unread[open] ?? 0) == 0 }
                store.enqueue(fresh)
            }
        }
        prevUnread = unread
        lastMsgId = maxId
    }
}

// MARK: - Interface

struct TranscriptsView: View {
    @ObservedObject var store: Store

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Abra uma conversa com áudios novos no WhatsApp")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.items) { item in card(item) }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    @ViewBuilder private func card(_ item: Store.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.chat).font(.headline).lineLimit(1)
                if item.fromMe {
                    Text("· você").font(.subheadline).foregroundStyle(.secondary)
                } else if let s = item.sender {
                    Text("· \(s)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Self.time.string(from: item.date)).font(.caption).foregroundStyle(.secondary)
            }
            switch item.status {
            case .waiting:
                Label("Na fila…", systemImage: "clock").font(.callout).foregroundStyle(.secondary)
            case .working:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Transcrevendo…").foregroundStyle(.secondary) }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            case .done:
                Text(item.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    } label: { Label("Copiar", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let db = WADB()
    lazy var store = Store(db: db)
    lazy var watcher = Watcher(store: store)
    var statusItem: NSStatusItem!
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "ZapTexto")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        makePanel()

        guard db.open() else { askForDiskAccess(); return }
        store.onNewItem = { [weak self] in self?.showPanel() }
        watcher.start()
    }

    private func makePanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Transcrições"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TranscriptsView(store: store))
        panel.setFrameAutosaveName("ZapTextoPanel")
        if !panel.setFrameUsingName("ZapTextoPanel"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.maxY - 480))
        }
    }

    func showPanel() { panel.orderFrontRegardless() }

    private func askForDiskAccess() {
        let a = NSAlert()
        a.messageText = "O ZapTexto precisa de Acesso Total ao Disco"
        a.informativeText = "É para ler os áudios do WhatsApp. Em Ajustes → Privacidade e Segurança → Acesso Total ao Disco, adicione o ZapTexto, ligue a chave e abra o app de novo."
        a.addButton(withTitle: "Abrir Ajustes")
        a.addButton(withTitle: "Sair")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    // Menu montado na hora em que abre, com as conversas recentes.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Mostrar transcrições", #selector(showPanelAction)))

        let auto = item("Transcrever automaticamente", #selector(toggleAuto))
        auto.state = watcher.enabled ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Transcrever últimos áudios de…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for chat in db.recentAudioChats(limit: 12) {
            let mi = item(chat.name, #selector(transcribeChat(_:)))
            mi.tag = Int(chat.id)
            mi.indentationLevel = 1
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        let login = item("Abrir ao iniciar o Mac", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Limpar lista", #selector(clearList)))
        menu.addItem(item("Sair", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    @objc func showPanelAction() { showPanel() }
    @objc func toggleAuto() { watcher.enabled.toggle() }
    @objc func clearList() { store.items.removeAll() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func transcribeChat(_ sender: NSMenuItem) {
        let chat = Int64(sender.tag)
        watcher.setOpenChat(chat)
        store.enqueue(db.lastAudios(chat: chat, n: 3))
        showPanel()
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        if s.status == .enabled { try? s.unregister() } else { try? s.register() }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

import SwiftUI

/* ============================================================
   聊天记录管理（微信「设置 → 通用 → 聊天记录」）
   · 按会话列出占用和条数，可以单独清空某个会话的聊天记录（只清自己这边）
   · 底部「清空全部聊天记录」：把你这边的记录全清掉（服务器上别人的记录不动）
   · 说明：备份与迁移（导出到电脑/新手机）还没做，页面上写清楚
   ============================================================ */
struct ChatHistoryView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var info: API.StorageInfo?
    @State private var loading = true
    @State private var busy = false
    @State private var confirmAll = false
    @State private var doneTip = ""
    /// 导出的文件（弹系统分享面板用）
    @State private var shareFile: ShareFile?
    @State private var showImport = false
    @State private var exportBusy = false
    @State private var importBusy = false
    @State private var importTip = ""

    private func mb(_ b: Int) -> String {
        let v = Double(b) / 1024 / 1024
        if v < 0.1 { return String(format: "%.0f KB", v * 1024) }
        if v < 1024 { return String(format: "%.1f MB", v) }
        return String(format: "%.2f GB", v / 1024)
    }

    private func title(_ c: API.StorageChat) -> String {
        let t = c.title
        return t.isEmpty ? Tr("聊天") : t
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("聊天记录管理"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Text(loading ? "…" : mb(info?.total ?? 0))
                            .font(pfMoney(32, .medium)).foregroundColor(C.label)
                        Text(Tr("你这边的聊天记录总共占用")).font(pf(12.5)).foregroundColor(C.subLabel)
                        if !doneTip.isEmpty {
                            Text(doneTip).font(pf(12.5)).foregroundColor(C.green)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(C.cardBg)

                    /* 备份与迁移（微信「聊天记录迁移与备份」那一块） */
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Tr("备份与迁移")).font(pf(13)).foregroundColor(C.subLabel)
                            .padding(.horizontal, 8).padding(.bottom, 6)
                        GroupCard {
                            backupRow(Tr("导出聊天记录（可再导入）"),
                                      detail: exportBusy ? Tr("导出中…") : Tr("JSON 备份文件，换手机后导入即可")) {
                                exportChats(json: true)
                            }
                            HairLine(inset: 16)
                            backupRow(Tr("导出为文本（给人看）"),
                                      detail: Tr("TXT，电脑上直接打开阅读")) {
                                exportChats(json: false)
                            }
                            HairLine(inset: 16)
                            backupRow(Tr("从文件导入聊天记录"),
                                      detail: importBusy ? Tr("导入中…") : (importTip.isEmpty ? Tr("选一个导出的 JSON 备份") : importTip)) {
                                showImport = true
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 12)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(Tr("按会话清空（只清你自己这边）")).font(pf(13)).foregroundColor(C.subLabel)
                            .padding(.horizontal, 8).padding(.bottom, 6)
                        GroupCard {
                            let list = (info?.chats ?? []).filter { $0.bytes > 1024 }
                            if list.isEmpty {
                                Text(Tr("没有可清理的会话")).font(pf(14)).foregroundColor(C.subLabel)
                                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                            } else {
                                ForEach(Array(list.enumerated()), id: \.offset) { idx, c in
                                    if idx > 0 { HairLine(inset: 16) }
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(title(c)).font(pf(15.5)).foregroundColor(C.label).lineLimit(1)
                                            Text(mb(c.bytes) + (c.messages > 0 ? (" · \(c.messages) 条") : ""))
                                                .font(pf(12)).foregroundColor(C.subLabel)
                                        }
                                        Spacer(minLength: 6)
                                        Button { clear(c.id) } label: {
                                            Text(Tr("清空")).font(pf(13.5)).foregroundColor(C.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 16).frame(height: 58)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 12)

                    Button { confirmAll = true } label: {
                        Text(busy ? Tr("清理中…") : Tr("清空全部聊天记录"))
                            .font(pf(16.5)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(C.cardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.top, 16)
                    .disabled(busy)

                    Text(Tr("清空只影响你自己：对方那边的记录还在。导出的 JSON 备份换手机后导入即可（重复导入不会产生重复消息）。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 14)
                    Color.clear.frame(height: 26)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(item: $shareFile) { f in ShareSheet(items: [f.url]) }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json, .item],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .confirmationDialog(Tr("清空全部聊天记录？"), isPresented: $confirmAll, titleVisibility: .visible) {
            Button(Tr("清空"), role: .destructive) { clearAll() }
            Button(Tr("取消"), role: .cancel) { }
        } message: {
            Text(Tr("只清你自己这边，对方那边的记录不受影响。清掉以后不能恢复。"))
        }
    }

    private func load() async {
        info = try? await API.shared.storage()
        loading = false
    }

    /* ---------------- 备份与迁移：导出一行一个操作 ---------------- */

    private func backupRow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(pf(15.5)).foregroundColor(C.label).lineLimit(1)
                    Text(detail).font(pf(12)).foregroundColor(C.subLabel).lineLimit(2)
                }
                Spacer(minLength: 6)
                Chevron(size: 9, line: 1.6)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exportBusy || importBusy)
    }

    /// 导出：JSON 是能再导入的备份，TXT 是给人看的
    private func exportChats(json: Bool) {
        guard !exportBusy else { return }
        exportBusy = true
        doneTip = ""
        Task {
            do {
                let dump = try await API.shared.exportChats(format: json ? "json" : "txt")
                let text: String
                if json {
                    let obj = dump.payload ?? [:]
                    let data = try JSONSerialization.data(withJSONObject: obj,
                                                          options: [.prettyPrinted, .sortedKeys])
                    text = String(data: data, encoding: .utf8) ?? "{}"
                } else {
                    text = dump.text
                }
                if let url = writeTempFile(name: dump.fileName, text: text) {
                    shareFile = ShareFile(url: url)
                    doneTip = Tr("已导出 ") + "\(dump.chats)" + Tr(" 个会话 / ") + "\(dump.total)" + Tr(" 条消息，选「存储到文件」保存")
                } else {
                    app.show(Tr("写文件失败"))
                }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? Tr("导出失败"))
            }
            exportBusy = false
        }
    }

    /// 导入：选一个导出的 JSON，服务器按消息 id 去重后合进来
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importTip = Tr("读不到这个文件")
            app.show(importTip)
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            importTip = Tr("这不是聊天记录备份文件")
            app.show(importTip)
            return
        }
        importBusy = true
        Task {
            do {
                let r = try await API.shared.importChats(payload: obj)
                importTip = Tr("导入完成：新增 ") + "\(r.imported)" + Tr(" 条，跳过（已存在）") + "\(r.skipped)" + Tr(" 条")
                doneTip = importTip
                await load()
                await app.loadChats()
            } catch {
                let msg = (error as? APIError)?.errorDescription ?? Tr("导入失败")
                importTip = msg
                app.show(msg)
            }
            importBusy = false
        }
    }

    private func clear(_ chatId: String) {
        busy = true
        Task {
            await API.shared.clearChat(chatId: chatId)
            doneTip = Tr("已清空一个会话")
            await load()
            await app.loadChats()
            busy = false
        }
    }

    private func clearAll() {
        busy = true
        Task {
            let ids = (info?.chats ?? []).map { $0.id }
            for id in ids { await API.shared.clearChat(chatId: id) }
            doneTip = Tr("已清空全部聊天记录（已清 ") + "\(ids.count)" + Tr(" 个会话）")
            await load()
            await app.loadChats()
            busy = false
        }
    }
}

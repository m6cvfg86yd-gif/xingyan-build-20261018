import SwiftUI
import Foundation

/* ============================================================
   小星（会话页顶栏那颗眼睛）的三档开关（2026-10-12 加）

     开启小星   ¥40 一次性买断（走零钱）—— 眼睛会动（眨眼 / 瞟 / 呼吸）
     静态小星   免费 —— 照样画出来，但两段无限循环动画不跑（省电、看着安静）
     关闭小星   免费 —— 顶栏不画；「我 → 服务」里补一个「AI 助手」入口

   档位存在服务端（GET / POST /api/me/eyes），换设备也跟着账号走；
   管理侧（/api/ops/eyes）能免费给某个用户开。
   入口：我 → 设置 → 通用 → 更多 → 显示小星。
   ============================================================ */

@MainActor
final class EyesStore: ObservableObject {
    static let shared = EyesStore()

    /* ⚠ 2026-10-16 用户：「进去会出现眼睛先出现后消失」。
       原因：`tier` 的默认值是 "on"，而真实档位是登录后**延后 2 秒**才去服务器拉的
       （那个 2 秒是当初为了躲"登录瞬间重画把顶栏搞崩"加的）。于是关了眼睛的人
       每次进来都会先看到那双眼睛、两秒后消失。
       现在：① 档位在本机按**账号**存一份 —— 冷启动第一帧就按上次那份画，不闪；
             ② 没存过（第一次装）时 `resolved == false`，顶栏**先不画**，
                等真档位回来再画 —— 宁可晚半秒，也不要"冒出来又没了"。 */
    private static var cacheKey: String {
        var uid = ""
        if let s = UserDefaults.standard.string(forKey: "chris.lastUserJSON"),
           let d = s.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let id = o["id"] as? String, !id.isEmpty {
            uid = id
        }
        return "chris.eyes.tier" + (uid.isEmpty ? "" : "." + uid)
    }

    /// on / static / off（认不出来按 on，和服务器默认一致）
    @Published var tier: String
    @Published var paid = false
    @Published var price: Double = 40
    @Published var balance: Double = 0
    @Published var loaded = false
    /// 档位"确定了"没：本机缓存里有，或者服务器已经回过一次
    @Published var resolved: Bool

    init() {
        let cached = UserDefaults.standard.string(forKey: Self.cacheKey)
        tier = cached ?? "on"
        resolved = (cached != nil)
    }

    /// 顶栏要不要画小星
    var eyesOn: Bool { tier != "off" }
    /// 会话页顶栏用这个：**档位确定了**、而且是开着的，才画（防"先出现后消失"）
    var navEyesOn: Bool { resolved && tier != "off" }
    /// 眼睛要不要动（只有「开启」那档才跑无限动画）
    var animated: Bool { tier == "on" }

    /// 登录之后、去服务器拉之前，先把本机存的档位铺上（同一台设备上次是什么就是什么）
    func primeFromCache() {
        guard let v = UserDefaults.standard.string(forKey: Self.cacheKey) else { return }
        if tier != v { tier = v }
        if !resolved { resolved = true }
    }

    func apply(_ info: API.EyesInfo) {
        /* ⚠ 只在**真的变了**的时候才赋值：@Published 每赋一次值都会让会话页整个重画一遍，
           而会话页顶栏在这台测试机上"多一次重画 / 结构一变"就可能被系统直接杀进程
           （B149/B166/B168/B172 都是无崩溃栈地死在顶栏上）。原来这里连着赋 5 个值
           = 一口气重画 5 次，登录后那两秒正好撞上"点聊天"就被杀了。 */
        let t = info.tier
        if tier != t {
            tier = t
            /* 记到本机（按账号存）：下次冷启动第一帧就是对的，不会闪 */
            UserDefaults.standard.set(t, forKey: Self.cacheKey)
        }
        let p = info.paid ?? false
        if paid != p { paid = p }
        let pr = info.price ?? 40
        if price != pr { price = pr }
        let b = info.balance ?? balance
        if balance != b { balance = b }
        if !loaded { loaded = true }
        if !resolved { resolved = true }
    }

    /// 拉一次当前档位（登录后 / 进前台时调，别频繁调）
    func refresh() async {
        do {
            apply(try await API.shared.eyesState())
        } catch {
            /* 拉不到（断网这些）：没缓存的话就按默认「开」画 —— 顶栏空着更奇怪 */
            if !resolved, API.shared.offline { resolved = true }
        }
    }

    /// 切档位。返回 nil = 成功；否则是给用户看的错误文字（比如零钱不够）
    func set(_ want: String) async -> String? {
        do {
            apply(try await API.shared.eyesSet(want))
            DiagLog.shared.note("小星档位改成 \(want)")
            return nil
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "设置失败，再试一次"
            DiagLog.shared.note("小星档位改 \(want) 失败：\(msg)")
            return msg
        }
    }
}

struct EyesSettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var eyes = EyesStore.shared
    /// 选「开启」但还没付费 → 先弹这个确认（¥40 一次性）
    @State private var confirmOn = false
    @State private var busy = false
    /// 点「进入 AI 助手」整页打开小星自己的对话页
    @State private var botChat: Chat? = nil

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("显示小星"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    GroupCard {
                        tierRow("on", Tr("开启小星"), priceText, Tr("会动"))
                        HairLine(inset: 16)
                        tierRow("static", Tr("静态小星"), Tr("免费"), Tr("不动"))
                        HairLine(inset: 16)
                        tierRow("off", Tr("关闭小星"), Tr("免费"), Tr("不显示"))
                    }
                    .padding(.top, 10)

                    Text(Tr("会话页顶栏那颗眼睛已经按你的要求去掉了（那台机器上顶栏会闪退）。\n现在这三档只管 AI 助手页里那颗眼睛：开启会眨眼会瞟、静态照样画但不跑动画、\n关闭就不画了。进 AI 助手：我 → 服务 → AI 助手。"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 4)

                    GroupCard {
                        HStack(spacing: 12) {
                            Text(Tr("零钱余额")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 0)
                            Text("¥" + moneyFmt(eyes.balance))
                                .font(pfMoney(16))
                                .foregroundColor(C.subLabel)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                    }
                    .padding(.top, 4)

                    /* 关了顶栏那颗眼睛以后，进 AI 助手的地方就在这儿（用户要求的那条） */
                    Button {
                        openAI()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16, weight: .medium))
                            Text(Tr("进入 AI 助手"))
                                .font(pf(16, .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                    Spacer().frame(height: 30)
                }
                .padding(.top, 6)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { if !eyes.loaded { await eyes.refresh() } }
        .confirmationDialog(Tr("开启小星（¥40，一次性，用零钱支付）"),
                            isPresented: $confirmOn, titleVisibility: .visible) {
            Button(Tr("确认支付 ¥") + moneyFmt(eyes.price)) { Task { await choose("on") } }
            Button(Tr("取消"), role: .cancel) { }
        } message: {
            Text(Tr("买断之后一直有效，不再重复收费。"))
        }
        .fullScreenCover(item: $botChat) { c in
            BotChatView(chat: c).environmentObject(app)
        }
    }

    /// 开启小星那档的价格文字：付过钱就写「已开启」
    private var priceText: String {
        if eyes.tier == "on" && eyes.paid { return Tr("已开启") }
        if eyes.tier == "on" && !eyes.paid { return "¥" + moneyFmt(eyes.price) + Tr(" 一次性（还没付费）") }
        return "¥" + moneyFmt(eyes.price) + Tr(" 一次性")
    }

    private func tierRow(_ id: String, _ title: String, _ value: String, _ tag: String) -> some View {
        Button {
            if id == "on" && !eyes.paid && eyes.tier != "on" {
                confirmOn = true              // 要花钱：先让用户确认
            } else if id != eyes.tier {
                Task { await choose(id) }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(pf(16.5)).foregroundColor(C.label)
                    Text(value + " · " + tag).font(pf(12.5)).foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                if eyes.tier == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.green)
                }
                if busy && eyes.tier != id {
                    ProgressView().scaleEffect(0.75)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
        .disabled(busy)
    }

    private func choose(_ want: String) async {
        busy = true
        let err = await eyes.set(want)
        busy = false
        if let err = err { app.show(err) }
        else {
            app.me = try? await API.shared.me()      // 付了钱余额会变，顺手刷新
            app.show(want == "on" ? Tr("小星已开启") : (want == "static" ? Tr("已切成静态小星") : Tr("已关闭小星")))
        }
    }

    /// 「进入 AI 助手」：整页打开小星自己的对话页（和顶栏那颗眼睛点开的是同一页）
    private func openAI() {
        if let bot = app.chats.first(where: { $0.botRank == 0 }) { botChat = bot; return }
        Task {
            await app.loadChats()
            if let b = app.chats.first(where: { $0.botRank == 0 }) { botChat = b }
            else { app.show(Tr("AI 助手还没准备好，稍后再试")) }
        }
    }
}

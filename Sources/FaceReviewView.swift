import SwiftUI

/* ============================================================
   人脸比对（后台）—— 2026-10-15 用户：「人脸给后台做个比对口」

   App 那边核身通过后会传一张**那一帧的照片** + 姓名 + 身份证号上来（存服务器
   data/faces.json），这一页就是**人工比对的口子**（只有 ops 账号看得到）：
     · 上面是照片（核身时抓的那一帧）
     · 下面是姓名 / 身份证（打码）/ 是哪个账号 / 什么时候传的
     · 「通过 ✅ / 驳回 ⛔」两个按钮 → 结论写回那个用户的账号上
       （对方在「我 → 设置 → 安全分」里能看到自己过没过）
   ============================================================ */

struct FaceReviewRow: Decodable, Identifiable, Hashable {
    var id: String
    var userId: String?
    var name: String?
    var idCard: String?
    var nickname: String?
    var image: String?
    var at: String?
    var status: String?
    var by: String?
    var note: String?
    /// 与账号头像的特征距离（App 上算的参考分，越小越像；0/缺省 = 没算出来）
    var avatarDist: Double?

    /// 参考分写成一句人话（我们自己判：<0.9 像同一个人、1.0 以上就不像了）
    var avatarText: String {
        guard let d = avatarDist, d > 0 else { return "与账号头像：没算出来" }
        if d < 0.9 { return String(format: "与账号头像：像同一个人（%.2f）", d) }
        if d < 1.05 { return String(format: "与账号头像：有点像（%.2f）", d) }
        return String(format: "与账号头像：不太像（%.2f）", d)
    }
    var avatarColor: Color {
        guard let d = avatarDist, d > 0 else { return C.subLabel }
        return d < 0.9 ? Color(hex: 0x1CA36B) : (d < 1.05 ? Color(hex: 0xFA9D3B) : Color(hex: 0xE24C3F))
    }

    var statusText: String {
        switch status ?? "pending" {
        case "passed":   return "已通过"
        case "rejected": return "已驳回"
        default:         return "待比对"
        }
    }
    var statusColor: Color {
        switch status ?? "pending" {
        case "passed":   return Color(hex: 0x1CA36B)
        case "rejected": return Color(hex: 0xE24C3F)
        default:         return C.subLabel
        }
    }
}

struct FaceReviewView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [FaceReviewRow] = []
    @State private var loading = true
    @State private var busy = ""
    @State private var zoom: String? = nil

    private var pending: [FaceReviewRow] { items.filter { ($0.status ?? "pending") == "pending" } }
    private var done: [FaceReviewRow] { items.filter { ($0.status ?? "pending") != "pending" } }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("人脸比对"), back: { dismiss() }) {
                Button { Task { await load() } } label: {
                    Text(Tr("刷新")).font(pf(15)).foregroundColor(C.green)
                        .frame(height: 40).padding(.horizontal, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if loading {
                HStack(spacing: 10) { ProgressView(); Text(Tr("正在拉列表…")).font(pf(14)).foregroundColor(C.subLabel) }
                    .frame(maxWidth: .infinity).frame(height: 90)
                Spacer(minLength: 0)
            } else if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 32)).foregroundColor(C.subLabel)
                    Text(Tr("还没有人传人脸比对")).font(pf(15)).foregroundColor(C.label)
                    Text(Tr("用户在实名认证 / 开小星的时候过了活体，照片会传到这里等你比对。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        if !pending.isEmpty {
                            head(Tr("待比对 ") + "\(pending.count)")
                            ForEach(pending) { r in card(r) }
                        }
                        if !done.isEmpty {
                            head(Tr("已比对 ") + "\(done.count)")
                            ForEach(done) { r in card(r) }
                        }
                        Spacer().frame(height: 20)
                    }
                    .padding(.vertical, 10)
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        /* 点照片放大看（比对了才敢点通过） */
        .overlay {
            if let z = zoom {
                ZStack {
                    Color.black.opacity(0.92).ignoresSafeArea()
                    RemoteImage(path: z, mode: .fit, maxSide: 1400)
                        .padding(20)
                    VStack { HStack { Spacer()
                        Button { zoom = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white).frame(width: 44, height: 44)
                        }.buttonStyle(.plain)
                    }; Spacer() }
                }
                .onTapGesture { zoom = nil }
            }
        }
    }

    private func head(_ t: String) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(DDColor.red).frame(width: 3.5, height: 14)
            Text(t).font(pf(15.5, .semibold)).foregroundColor(C.label)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private func card(_ r: FaceReviewRow) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button { if let img = r.image, !img.isEmpty { zoom = img } } label: {
                    RemoteImage(path: r.image ?? "", icon: "person.crop.square", mode: .fill, maxSide: 300)
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 5) {
                    Text(r.name?.isEmpty == false ? r.name! : Tr("（没填姓名）"))
                        .font(pf(16, .medium)).foregroundColor(C.label).lineLimit(1)
                    Text(Tr("身份证 ") + (r.idCard ?? ""))
                        .font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                    Text(Tr("账号 ") + (r.nickname ?? r.userId ?? ""))
                        .font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                    Text(r.at ?? "").font(pf(11.5)).foregroundColor(C.subLabel.opacity(0.8)).lineLimit(1)
                    Text(Tr(r.avatarText)).font(pf(11.5, .medium)).foregroundColor(r.avatarColor).lineLimit(1)
                    Text(Tr(r.statusText)).font(pf(12, .medium)).foregroundColor(r.statusColor)
                }
                Spacer(minLength: 0)
            }

            if (r.status ?? "pending") == "pending" {
                HStack(spacing: 10) {
                    Button { Task { await review(r, pass: false) } } label: {
                        Text(busy == r.id ? Tr("提交中…") : Tr("驳回"))
                            .font(pf(14.5, .medium)).foregroundColor(C.label)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.pageBg))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                    Button { Task { await review(r, pass: true) } } label: {
                        Text(busy == r.id ? Tr("提交中…") : Tr("通过"))
                            .font(pf(14.5, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                }
                .disabled(!busy.isEmpty)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: (r.status == "passed") ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.system(size: 13)).foregroundColor(r.statusColor)
                    Text(Tr(r.statusText) + (r.by?.isEmpty == false ? Tr(" · 由 ") + r.by! + Tr(" 比对") : ""))
                        .font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
    }

    private func load() async {
        items = await API.shared.opsFaces()
        loading = false
    }

    private func review(_ r: FaceReviewRow, pass: Bool) async {
        busy = r.id
        let ok = await API.shared.opsFaceReview(id: r.id, pass: pass)
        busy = ""
        if ok {
            app.show(pass ? Tr("已通过") : Tr("已驳回"))
            await load()
        } else {
            app.show(Tr("没提交上，再试一次"))
        }
    }
}

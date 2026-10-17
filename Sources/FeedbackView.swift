import SwiftUI

/* ============================================================
   意见反馈（照微信那套）：
   · 先选分类：功能异常 / 产品建议 / 界面样式 / 其他
   · 写描述，右下角 0/200 字数，超了截断
   · 可以贴截图，最多 3 张（相册或拍照），点图可删
   · 联系方式（选填）
   · 提交后整页「感谢你的反馈」，下面还有「我的反馈」能看到官方回复
   ============================================================ */

struct FeedbackView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var category = "功能异常"
    @State private var content = ""
    @State private var contact = ""
    @State private var picked: [UIImage] = []
    @State private var busy = false
    @State private var done = false
    @State private var showPhoto = false
    @State private var showCamera = false
    @State private var showMine = false

    private let cats = ["功能异常", "产品建议", "界面样式", "其他"]
    private let maxLen = 200

    var body: some View {
        if done {
            /* 提交成功：绿色渐变圆 + 白勾（带柔光），下面两个按钮 */
            VStack(spacing: 0) {
                Spacer(minLength: 70)
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [C.green.opacity(0.28), Color.clear],
                                             center: .center, startRadius: 2, endRadius: 76))
                        .frame(width: 152, height: 152)
                    Circle()
                        .fill(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 86, height: 86)
                        .shadow(color: C.green.opacity(0.35), radius: 14, y: 7)
                    Image(systemName: "checkmark")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(.white)
                }
                Text(Tr("感谢你的反馈"))
                    .font(pf(20, .semibold))
                    .foregroundColor(C.label)
                    .padding(.top, 22)
                Text(Tr("我们会尽快处理，处理结果可以在「我的反馈」里看。"))
                    .font(pf(13.5))
                    .foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 46)
                    .padding(.top, 8)

                VStack(spacing: 10) {
                    NavigationLink(value: "feedback.history") {
                        Text(Tr("查看我的反馈"))
                            .font(pf(16, .medium))
                            .foregroundColor(C.green)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(C.green.opacity(0.55), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)

                    Button { dismiss() } label: {
                        Text(Tr("返回"))
                            .font(pf(16, .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
                            .shadow(color: C.green.opacity(0.30), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
                .padding(.top, 26)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(C.pageBg.ignoresSafeArea())
        } else {
            VStack(spacing: 0) {
                NavBar(title: Tr("意见反馈"), back: { dismiss() }) {
                    Button {
                        send()
                    } label: {
                        Text(busy ? Tr("提交中…") : Tr("提交"))
                            .font(pf(14.5, .medium))
                            .foregroundColor(content.isEmpty || busy ? C.subLabel : .white)
                            .padding(.horizontal, 15)
                            .frame(height: 32)
                            .background(
                                Capsule().fill(content.isEmpty || busy
                                    ? AnyShapeStyle(Color.dyn(0xEDEDED, 0x2C2C2E))
                                    : AnyShapeStyle(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                                                   startPoint: .topLeading, endPoint: .bottomTrailing)))
                            )
                            .padding(.trailing, 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(content.isEmpty || busy)
                }

                ScrollView {
                    VStack(spacing: 0) {
                        /* ① 分类：四张卡片（图标 + 名称），选中的描绿边、浅绿底 */
                        VStack(alignment: .leading, spacing: 9) {
                            Text(Tr("问题类型"))
                                .font(pf(12.5))
                                .foregroundColor(C.subLabel)
                                .padding(.leading, 4)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                                      spacing: 10) {
                                ForEach(cats, id: \.self) { c in
                                    Button { category = c } label: {
                                        HStack(spacing: 10) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(LinearGradient(colors: catColors(c),
                                                                         startPoint: .topLeading,
                                                                         endPoint: .bottomTrailing))
                                                    .frame(width: 34, height: 34)
                                                Image(systemName: catIcon(c))
                                                    .font(.system(size: 15, weight: .semibold))
                                                    .foregroundColor(.white)
                                            }
                                            Text(Tr(c))
                                                .font(pf(14.5, category == c ? .medium : .regular))
                                                .foregroundColor(C.label)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                            if category == c {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 15))
                                                    .foregroundColor(C.green)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(height: 58)
                                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .fill(category == c ? C.green.opacity(0.07) : C.cardBg))
                                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .stroke(category == c ? C.green.opacity(0.6) : C.hairline,
                                                    lineWidth: category == c ? 1.2 : 0.6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.top, 10)

                        /* ② 描述 + 字数 + 截图 */
                        Text(Tr("问题描述"))
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        VStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                if content.isEmpty {
                                    Text(Tr("说说遇到的问题，或者你希望加什么功能…"))
                                        .font(pf(15)).foregroundColor(C.subLabel)
                                        .padding(.horizontal, 16).padding(.top, 14)
                                }
                                TextEditor(text: $content)
                                    .font(pf(15))
                                    .scrollContentBackground(.hidden)
                                    .frame(height: 150)
                                    .padding(.horizontal, 11)
                                    .padding(.top, 6)
                                    .onChange(of: content) { v in
                                        if v.count > maxLen { content = String(v.prefix(maxLen)) }
                                    }
                            }
                            HStack {
                                Spacer(minLength: 0)
                                Text("\(content.count)/\(maxLen)")
                                    .font(pf(12))
                                    .foregroundColor(content.count > maxLen - 20 ? Color(hex: 0xE08A0C) : C.subLabel)
                                    .padding(.trailing, 16).padding(.bottom, 8)
                            }
                            HairLine(inset: 16)
                            /* 截图：最多 3 张（+ 号加图，点图删） */
                            HStack(spacing: 10) {
                                ForEach(Array(picked.enumerated()), id: \.offset) { _, img in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: img)
                                            .resizable().scaledToFill()
                                            .frame(width: 74, height: 74)
                                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 18, height: 18)
                                            .background(Circle().fill(Color(hex: 0xFA5151)))
                                            .offset(x: 6, y: -6)
                                    }
                                    .onTapGesture {
                                        if let i = picked.firstIndex(where: { $0 === img }) { picked.remove(at: i) }
                                    }
                                }
                                if picked.count < 3 {
                                    Button { showPhoto = true } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "plus")
                                                .font(.system(size: 18, weight: .medium))
                                                .foregroundColor(C.green)
                                            Text(Tr("最多 3 张"))
                                                .font(pf(10.5))
                                                .foregroundColor(C.subLabel)
                                        }
                                        .frame(width: 74, height: 74)
                                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(C.green.opacity(0.06)))
                                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                            .foregroundColor(C.green.opacity(0.5)))
                                    }
                                    .buttonStyle(.plain)

                                    Button { showCamera = true } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "camera.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(C.subLabel)
                                            Text(Tr("拍照"))
                                                .font(pf(10.5))
                                                .foregroundColor(C.subLabel)
                                        }
                                        .frame(width: 74, height: 74)
                                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(C.fieldBg.opacity(0.65)))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        .background { CardGlassBox(radius: 13) }
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(C.hairline, lineWidth: 0.6))

                        /* ③ 联系方式 */
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 18))
                                .foregroundColor(C.green)
                            TextField(Tr("联系方式（选填，方便我们回你）"), text: $contact)
                                .font(pf(15))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 54)
                        .background { CardGlassBox(radius: 13) }
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(C.hairline, lineWidth: 0.6))
                        .padding(.top, 10)

                        /* ④ 我的反馈 */
                        NavigationLink(value: "feedback.history") {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(LinearGradient(colors: [Color(hex: 0x7FA6E8), Color(hex: 0x3F66B8)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: "tray.full.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Tr("我的反馈")).font(pf(15.5, .medium)).foregroundColor(C.label)
                                    Text(Tr("看处理进度和官方回复")).font(pf(12)).foregroundColor(C.subLabel)
                                }
                                Spacer(minLength: 0)
                                Chevron(size: 8, line: 1.5)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 62)
                            .background { CardGlassBox(radius: 13) }
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(C.hairline, lineWidth: 0.6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)

                        Text(Tr("截图可以帮我们更快定位问题；提交内容会存在你自己的服务器上。"))
                            .font(pf(12)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.top, 10)
                        Spacer().frame(height: 30)
                    }
                }
                .background(C.pageBg)
            }
            .background(C.pageBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .swipeBack { dismiss() }
            .hidesTabBar()
            .sheet(isPresented: $showPhoto) {
                PhotosPicker(limit: 3 - picked.count) { imgs in
                    picked.append(contentsOf: imgs.prefix(3 - picked.count))
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { img in
                    if picked.count < 3 { picked.append(img) }
                }
            }
        }
    }

    /// 分类卡片的图标
    private func catIcon(_ c: String) -> String {
        switch c {
        case "功能异常": return "wrench.and.screwdriver.fill"
        case "产品建议": return "lightbulb.fill"
        case "界面样式": return "paintbrush.fill"
        default:        return "ellipsis.bubble.fill"
        }
    }

    /// 分类卡片的配色（红=出问题、金=点子、紫=好看、灰=其他）
    private func catColors(_ c: String) -> [Color] {
        switch c {
        case "功能异常": return [Color(hex: 0xFF8A73), Color(hex: 0xE2432E)]
        case "产品建议": return [Color(hex: 0xFFD34B), Color(hex: 0xE09A10)]
        case "界面样式": return [Color(hex: 0x8A93FF), Color(hex: 0x4A55D6)]
        default:        return [Color(hex: 0xA0A4AE), Color(hex: 0x6E7280)]
        }
    }

    private func send() {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { app.show(Tr("先写点内容")); return }
        busy = true
        Task {
            /* 先把截图传上去（拿到的就是服务器路径），再提交反馈 */
            var urls: [String] = []
            for img in picked {
                if let u = try? await API.shared.upload(image: img) { urls.append(u) }
            }
            if let err = await API.shared.sendFeedback(content: text, contact: contact,
                                                       category: category, images: urls) {
                app.show(err)
            } else {
                content = ""
                contact = ""
                picked = []
                done = true
            }
            busy = false
        }
    }
}

/* 我的反馈：一条条列出来，处理中 / 已回复，回复内容直接显示在下面（和微信一样） */
struct FeedbackHistoryView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [API.MyFeedback] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的反馈"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    if loading {
                        ProgressView().padding(.top, 50)
                    } else if rows.isEmpty {
                        VStack(spacing: 8) {
                            SVGIcon(markup: I.service, size: 40, color: C.subLabel)
                            Text(Tr("还没有提交过反馈")).font(pf(14)).foregroundColor(C.subLabel)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ForEach(rows) { r in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(Tr(r.category ?? "功能异常"))
                                        .font(pf(13)).foregroundColor(.white)
                                        .padding(.horizontal, 8).frame(height: 22)
                                        .background(Capsule().fill(C.green.opacity(0.85)))
                                    Spacer(minLength: 0)
                                    Text((r.status ?? "pending") == "replied" ? Tr("已回复") : Tr("处理中"))
                                        .font(pf(13))
                                        .foregroundColor((r.status ?? "pending") == "replied" ? C.green : C.subLabel)
                                }
                                Text(r.content ?? "").font(pf(15)).foregroundColor(C.label)
                                if let imgs = r.images, !imgs.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(Array(imgs.prefix(3).enumerated()), id: \.offset) { _, s in
                                            RemoteImage(path: s, mode: .fill, maxSide: 400)
                                                .frame(width: 62, height: 62)
                                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                Text(fmt(r.createdAt)).font(pf(12)).foregroundColor(C.subLabel)
                                if let reply = r.reply, !reply.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(Tr("官方回复")).font(pf(12.5, .medium)).foregroundColor(C.green)
                                        Text(reply).font(pf(14)).foregroundColor(C.label)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(C.fieldBg))
                                }
                            }
                            .padding(14)
                            .background(C.cardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 12).padding(.top, 10)
                        }
                    }
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            rows = await API.shared.myFeedback()
            loading = false
        }
    }

    private func fmt(_ s: String?) -> String {
        guard let s = s, s.count >= 16 else { return "" }
        return String(s.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

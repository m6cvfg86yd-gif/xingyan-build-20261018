import SwiftUI
import UIKit

/* ============================================================
   新用户首次引导（iOS）
   · 只有注册接口明确返回 needsOnboarding=true 的新账号会出现
   · 不提供跳过：头像 + 至少两个兴趣分类完成后才进首页
   · 视觉参考小红书：大留白、柔和渐变、圆形头像、胶囊分类
   ============================================================ */

private struct OnboardingInterest: Identifiable {
    let id: String
    let symbol: String
    let colors: [Color]
    let hint: String

    static let all: [OnboardingInterest] = [
        .init(id: "穿搭", symbol: "sparkles", colors: [Color(hex: 0xFF6B81), Color(hex: 0xFF9E7A)], hint: "OOTD"),
        .init(id: "美食", symbol: "fork.knife", colors: [Color(hex: 0xFF9D39), Color(hex: 0xFFD166)], hint: "探店"),
        .init(id: "旅行", symbol: "airplane", colors: [Color(hex: 0x4B8DF8), Color(hex: 0x72D5FF)], hint: "出发"),
        .init(id: "摄影", symbol: "camera.fill", colors: [Color(hex: 0x6257E8), Color(hex: 0x9B8CFF)], hint: "记录"),
        .init(id: "运动", symbol: "figure.run", colors: [Color(hex: 0x18B57B), Color(hex: 0x6CE3AE)], hint: "动起来"),
        .init(id: "音乐", symbol: "music.note", colors: [Color(hex: 0xEC5E95), Color(hex: 0xFF9AC5)], hint: "循环中"),
        .init(id: "宠物", symbol: "pawprint.fill", colors: [Color(hex: 0xD9854A), Color(hex: 0xF3BE78)], hint: "毛孩子"),
        .init(id: "游戏", symbol: "gamecontroller.fill", colors: [Color(hex: 0x6C63E8), Color(hex: 0xA895FF)], hint: "开黑"),
        .init(id: "阅读", symbol: "book.fill", colors: [Color(hex: 0x3E9B84), Color(hex: 0x86D3B8)], hint: "书单"),
        .init(id: "数码", symbol: "iphone", colors: [Color(hex: 0x4E6D8F), Color(hex: 0x8DB4D9)], hint: "装备"),
        .init(id: "美妆", symbol: "paintbrush.pointed.fill", colors: [Color(hex: 0xE15E7E), Color(hex: 0xFFA6B9)], hint: "变美"),
        .init(id: "生活", symbol: "leaf.fill", colors: [Color(hex: 0x62A84E), Color(hex: 0xA8DD80)], hint: "日常")
    ]
}

struct NewUserOnboardingView: View {
    @EnvironmentObject private var app: AppState
    @State private var step = 0
    @State private var avatar: UIImage?
    @State private var avatarPath = ""
    @State private var selectedInterests: Set<String> = []
    @State private var showPicker = false
    @State private var uploading = false
    @State private var saving = false
    @State private var error = ""
    @State private var appeared = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ZStack {
            onboardingBackground

            VStack(spacing: 0) {
                heading

                Group {
                    if step == 0 {
                        avatarStep
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
                    } else {
                        interestStep
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomAction
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, max(16, L.safeBottom))
        }
        .sheet(isPresented: $showPicker) {
            PhotoPicker { image in
                avatar = image
                uploadAvatar(image)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
        }
    }

    private var onboardingBackground: some View {
        ZStack {
            Color.dyn(0xFFFBF8, 0x121214).ignoresSafeArea()
            Circle()
                .fill(Color(hex: 0xFF7A90).opacity(0.17))
                .frame(width: 310, height: 310)
                .blur(radius: 46)
                .offset(x: -155, y: -310)
            Circle()
                .fill(Color(hex: 0xFFB368).opacity(0.13))
                .frame(width: 280, height: 280)
                .blur(radius: 50)
                .offset(x: 165, y: 285)
            LinearGradient(
                colors: [Color.white.opacity(0.04), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    private var heading: some View {
        HStack {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(LinearGradient(
                        colors: [Color(hex: 0xFF6B81), Color(hex: 0xFF9A5C)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 28, height: 28)
                Text("星言")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(C.label)
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<2, id: \.self) { index in
                    Capsule()
                        .fill(index <= step
                              ? LinearGradient(colors: [Color(hex: 0xFF6B81), Color(hex: 0xFF9A5C)],
                                               startPoint: .leading, endPoint: .trailing)
                              : LinearGradient(colors: [C.subLabel.opacity(0.18), C.subLabel.opacity(0.18)],
                                               startPoint: .leading, endPoint: .trailing))
                        .frame(width: index == step ? 28 : 12, height: 5)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -10)
    }

    private var avatarStep: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Text("先让大家记住你")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundColor(C.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 44)
                Text("一张清晰、有辨识度的头像，是新朋友认识你的第一步。")
                    .font(.system(size: 14.5))
                    .foregroundColor(C.subLabel)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)

                Button { showPicker = true } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(hex: 0xFF6B81), Color(hex: 0xFF9F5A), Color(hex: 0xFFD36E)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 172, height: 172)
                            .shadow(color: Color(hex: 0xFF786F).opacity(0.25), radius: 25, y: 14)

                        if let avatar {
                            Image(uiImage: avatar)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 158, height: 158)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.dyn(0xFFFFFF, 0x232326))
                                .frame(width: 158, height: 158)
                            VStack(spacing: 10) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 48, weight: .light))
                                    .foregroundColor(C.subLabel.opacity(0.62))
                                if uploading {
                                    ProgressView().tint(Color(hex: 0xFF6B81))
                                } else {
                                    Label("选择头像", systemImage: "camera.fill")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Color(hex: 0xFF6B81))
                                }
                            }
                        }

                        if avatar != nil && !uploading {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(width: 38, height: 38)
                                        .background(Circle().fill(Color.black.opacity(0.58)))
                                        .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                                        .offset(x: -5, y: -5)
                                }
                            }
                            .frame(width: 172, height: 172)
                        }
                    }
                    .padding(.top, 48)
                }
                .buttonStyle(OnboardingPressStyle())
                .disabled(uploading)

                Text(avatar == nil ? "点击上传你的专属头像" : "头像已就绪，可以继续了")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(avatar == nil ? C.subLabel : Color(hex: 0x18A66A))
                    .padding(.top, 22)

                if !error.isEmpty {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(C.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }

                Text("建议使用本人照片或能代表你的头像\n之后可以在「我 → 个人资料」里更换")
                    .font(.system(size: 12.5))
                    .foregroundColor(C.subLabel.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 24)
            }
        }
    }

    private var interestStep: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("找到你的同频圈子")
                        .font(.system(size: 29, weight: .bold))
                        .foregroundColor(C.label)
                    Text("选择 2～5 个兴趣，我们会优先展示你更喜欢的内容。")
                        .font(.system(size: 14))
                        .foregroundColor(C.subLabel)
                        .lineSpacing(4)
                }
                Spacer(minLength: 8)
                Text("\(selectedInterests.count)/5")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(selectedInterests.count >= 2 ? Color(hex: 0xFF6B81) : C.subLabel)
                    .padding(.horizontal, 11)
                    .frame(height: 27)
                    .background(Capsule().fill(Color.dyn(0xFFFFFF, 0x222225)))
                    .overlay(Capsule().stroke(C.hairline, lineWidth: 0.6))
                    .padding(.top, 5)
            }
            .padding(.top, 34)
            .padding(.bottom, 22)

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(OnboardingInterest.all) { interest in
                        interestCard(interest)
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }

    private func interestCard(_ interest: OnboardingInterest) -> some View {
        let selected = selectedInterests.contains(interest.id)
        return Button {
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
            if selected {
                selectedInterests.remove(interest.id)
            } else if selectedInterests.count < 5 {
                selectedInterests.insert(interest.id)
            }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: interest.colors,
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: interest.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 39, height: 39)

                VStack(alignment: .leading, spacing: 2) {
                    Text(interest.id)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundColor(C.label)
                    Text(interest.hint)
                        .font(.system(size: 11.5))
                        .foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(selected ? Color(hex: 0xFF6B81) : C.subLabel.opacity(0.28))
            }
            .padding(.horizontal, 12)
            .frame(height: 67)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected
                          ? Color(hex: 0xFF6B81).opacity(0.09)
                          : Color.dyn(0xFFFFFF, 0x1D1D20).opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? Color(hex: 0xFF6B81).opacity(0.72) : C.hairline,
                            lineWidth: selected ? 1.25 : 0.55)
            )
            .scaleEffect(selected ? 1.015 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: selected)
        }
        .buttonStyle(OnboardingPressStyle())
    }

    private var bottomAction: some View {
        VStack(spacing: 13) {
            if !error.isEmpty && step == 1 {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(C.red)
            }

            Button {
                if step == 0 {
                    guard !avatarPath.isEmpty else {
                        error = uploading ? "头像正在上传，请稍候" : "请先选择一张头像"
                        return
                    }
                    error = ""
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = 1 }
                } else {
                    guard selectedInterests.count >= 2 else {
                        error = "请至少选择两个兴趣分类"
                        return
                    }
                    finish()
                }
            } label: {
                HStack(spacing: 8) {
                    if saving {
                        ProgressView().tint(.white)
                    }
                    Text(step == 0 ? "继续" : saving ? "正在创建你的主页…" : "完成，进入星言")
                        .font(.system(size: 16, weight: .semibold))
                    if step == 0 && !saving {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: canContinue
                              ? [Color(hex: 0xFF6B81), Color(hex: 0xFF955C)]
                              : [C.subLabel.opacity(0.28), C.subLabel.opacity(0.28)],
                        startPoint: .leading, endPoint: .trailing))
                )
                .shadow(color: canContinue ? Color(hex: 0xFF6B81).opacity(0.22) : .clear,
                        radius: 16, y: 8)
            }
            .buttonStyle(OnboardingPressStyle())
            .disabled(saving || uploading)

            if step == 1 {
                Button {
                    error = ""
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { step = 0 }
                } label: {
                    Text("返回上一步")
                        .font(.system(size: 13))
                        .foregroundColor(C.subLabel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
    }

    private var canContinue: Bool {
        if step == 0 { return !avatarPath.isEmpty && !uploading && !saving }
        return selectedInterests.count >= 2 && !saving
    }

    private func uploadAvatar(_ image: UIImage) {
        uploading = true
        error = ""
        Task {
            do {
                let path = try await API.shared.upload(image: image)
                await MainActor.run {
                    avatarPath = path
                    uploading = false
                }
            } catch {
                await MainActor.run {
                    avatar = nil
                    avatarPath = ""
                    uploading = false
                    self.error = (error as? APIError)?.errorDescription ?? "头像上传失败，请重试"
                }
            }
        }
    }

    private func finish() {
        guard !saving else { return }
        saving = true
        error = ""
        let interests = OnboardingInterest.all.map(\.id).filter { selectedInterests.contains($0) }
        Task {
            do {
                try await app.finishNewUserOnboarding(avatar: avatarPath, interests: interests)
                await MainActor.run {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                    saving = false
                }
            } catch {
                await MainActor.run {
                    saving = false
                    self.error = (error as? APIError)?.errorDescription ?? "保存失败，请重试"
                }
            }
        }
    }
}

private struct OnboardingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

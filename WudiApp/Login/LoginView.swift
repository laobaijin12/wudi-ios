//
//  LoginView.swift
//  WudiApp
//
//  登录页：验证码（与 H5 一致）、用户名/密码、调用真实登录接口
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var appState: AppState
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var captchaInput: String = ""
    @State private var errorMessage: String?
    @State private var isLoading: Bool = false
    @FocusState private var focusedField: Field?
    
    @State private var captchaId: String = ""
    @State private var captchaImageURL: String = ""  // base64 或 URL
    @State private var captchaLength: Int = 4
    @State private var openCaptcha: Bool = false
    @State private var captchaLoading: Bool = false
    
    private enum Field: Hashable {
        case username, password, captcha
    }
    
    private let primaryBlue = Color(red: 0.09, green: 0.47, blue: 1.0)
    private let primaryLight = Color(red: 0.25, green: 0.59, blue: 1.0)
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    Color(red: 0.92, green: 0.95, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 48)
                    Text("WudiChat")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(primaryBlue)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 18)
                    VStack(spacing: 24) {
                        inputSection
                        if openCaptcha { captchaSection }
                        if let msg = errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                Text(msg)
                                    .font(.caption)
                            }
                            .foregroundColor(Color(red: 0.9, green: 0.3, blue: 0.25))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        loginButton
                    }
                    .padding(28)
                    .background(Color.white)
                    .cornerRadius(24)
                    .shadow(color: Color.black.opacity(0.08), radius: 24, x: 0, y: 12)
                    .padding(.horizontal, 28)
                    
                    Spacer(minLength: 40)
                }
            }
        }
        .task {
            await loadCaptcha()
        }
    }
    
    private var inputSection: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("用户名")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(Color(white: 0.35))
                HStack(spacing: 12) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundColor(focusedField == .username ? primaryBlue : Color(white: 0.6))
                    TextField("请输入用户名", text: $username)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .font(.body)
                        .foregroundColor(.black)
                        .focused($focusedField, equals: .username)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(white: 0.97))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(focusedField == .username ? primaryBlue : Color.clear, lineWidth: 2)
                )
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("密码")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(Color(white: 0.35))
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16))
                        .foregroundColor(focusedField == .password ? primaryBlue : Color(white: 0.6))
                    SecureField("请输入密码", text: $password)
                        .textContentType(.password)
                        .font(.body)
                        .foregroundColor(.black)
                        .focused($focusedField, equals: .password)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(white: 0.97))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(focusedField == .password ? primaryBlue : Color.clear, lineWidth: 2)
                )
            }
        }
    }
    
    private var captchaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("验证码")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(Color(white: 0.35))
            HStack(spacing: 12) {
                TextField("请输入\(captchaLength)位验证码", text: $captchaInput)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.body)
                    .foregroundColor(.black)
                    .focused($focusedField, equals: .captcha)
                
                Button(action: { Task { await loadCaptcha() } }) {
                    if captchaLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 100, height: 36)
                    } else if !captchaImageURL.isEmpty {
                        captchaImageView
                    } else {
                        Text("点击获取")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 100, height: 36)
                            .background(Color(white: 0.9))
                            .cornerRadius(8)
                    }
                }
                .disabled(captchaLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(white: 0.97))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(focusedField == .captcha ? primaryBlue : Color.clear, lineWidth: 2)
            )
        }
    }
    
    @ViewBuilder
    private var captchaImageView: some View {
        if captchaImageURL.hasPrefix("data:") || captchaImageURL.hasPrefix("/9j/") || captchaImageURL.contains("base64") {
            let base64Part: String = {
                if let range = captchaImageURL.range(of: ",", range: captchaImageURL.startIndex..<captchaImageURL.endIndex) {
                    return String(captchaImageURL[range.upperBound...])
                }
                return captchaImageURL
            }()
            if let data = Data(base64Encoded: base64Part),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 36)
                    .clipped()
                    .cornerRadius(6)
            } else {
                placeholderCaptchaView
            }
        } else if let url = URL(string: captchaImageURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: placeholderCaptchaView
                }
            }
            .frame(height: 36)
            .clipped()
            .cornerRadius(6)
        } else {
            placeholderCaptchaView
        }
    }
    
    private var placeholderCaptchaView: some View {
        Rectangle()
            .fill(Color(white: 0.9))
            .frame(width: 100, height: 36)
            .overlay(Text("验证码").font(.caption).foregroundColor(.secondary))
            .cornerRadius(6)
    }
    
    private var loginButton: some View {
        Button(action: submitLogin) {
            Group {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.9)
                } else {
                    Text("登 录")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                LinearGradient(
                    colors: [primaryBlue, primaryLight],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(14)
            .shadow(color: primaryBlue.opacity(0.35), radius: 12, x: 0, y: 6)
        }
        .disabled(isLoading)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
    
    private func loadCaptcha(clearError: Bool = true) async {
        captchaLoading = true
        captchaInput = ""
        if clearError {
            errorMessage = nil
        }
        defer { captchaLoading = false }
        do {
            let data = try await AuthService.shared.fetchCaptcha()
            await MainActor.run {
                captchaId = data.captchaId
                captchaImageURL = data.picPath
                captchaLength = data.captchaLength
                openCaptcha = data.openCaptcha
            }
        } catch {
            await MainActor.run {
                openCaptcha = false
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func submitLogin() {
        errorMessage = nil
        if username.count < 5 {
            errorMessage = "请输入正确的用户名"
            return
        }
        if password.count < 6 {
            errorMessage = "请输入正确的密码"
            return
        }
        if openCaptcha && captchaInput.count != captchaLength {
            errorMessage = "请输入\(captchaLength)位验证码"
            return
        }
        isLoading = true
        Task {
            do {
                let res = try await AuthService.shared.login(
                    username: username,
                    password: password,
                    captcha: openCaptcha ? captchaInput : nil,
                    captchaId: openCaptcha ? captchaId : nil
                )
                guard let token = res.effectiveToken else {
                    await MainActor.run {
                        errorMessage = "登录失败，请稍后重试"
                        isLoading = false
                    }
                    return
                }
                await MainActor.run {
                    appState.didLogin(
                        token: token,
                        userName: res.user?.userName ?? res.user?.nickName ?? username,
                        userID: res.user?.ID,
                        headerImg: res.user?.headerImg,
                        imEnabled: res.user?.imEnabled,
                        imToken: res.imToken,
                        imUserID: res.imUserID,
                        imExpireAt: res.imExpireAt
                    )
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    if case let APIError.serverError(_, msg) = error, let msg, !msg.isEmpty {
                        errorMessage = msg
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    isLoading = false
                    let msg = (errorMessage ?? "")
                    if msg.contains("验证码错误") || msg.contains("验证码") {
                        Task { await loadCaptcha(clearError: false) }
                    }
                }
            }
        }
    }
}

#Preview {
    LoginView(appState: AppState())
}

import SwiftUI

struct LoginView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case login, register
        var id: String { rawValue }
        var title: String { self == .login ? "登录" : "注册" }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .login
    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var field: Field?

    enum Field { case user, pass, mail }

    private var valid: Bool {
        username.trimmingCharacters(in: .whitespaces).count >= 2 && password.count >= 6
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("方式", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                        .focused($field, equals: .user)
                        .submitLabel(.next)
                        .onSubmit { field = .pass }
                    SecureField("密码（至少 6 位）", text: $password)
                        .textContentType(mode == .login ? .password : .newPassword)
                        .focused($field, equals: .pass)
                        .submitLabel(mode == .login ? .go : .next)
                        .onSubmit { mode == .login ? submit() : (field = .mail) }
                    if mode == .register {
                        TextField("邮箱（选填）", text: $email)
                            .textContentType(.emailAddress)
                            .focused($field, equals: .mail)
                            .onSubmit(submit)
                    }
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    } else {
                        Text(mode == .login ? "账号与 huangguoai.com 通用" : "注册后自动登录")
                    }
                }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text(mode.title).fontWeight(.semibold) }
                            Spacer()
                        }
                        .frame(minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!valid || busy)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .formStyle(.grouped)
            .navigationTitle(mode == .login ? "登录 HGhub" : "注册账号")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
            }
            .onAppear { field = .user }
            .onChange(of: mode) { _, _ in error = nil }
        }
        #if os(macOS)
        // 关闭点放在 sheet 的左上角（标题栏那一行），不要压在表单上
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: { MacCloseDot() }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .padding(.leading, 14)
                .help("关闭")
                .accessibilityLabel("关闭")
        }
        #endif
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(width: 420, height: 440)
        #endif
    }

    private func submit() {
        guard valid, !busy else { return }
        busy = true
        error = nil
        let u = username.trimmingCharacters(in: .whitespaces), p = password, m = email
        Task {
            defer { busy = false }
            do {
                let user = mode == .login
                    ? try await API.login(username: u, password: p)
                    : try await API.register(username: u, password: p, email: m)
                app.didLogin(user)
                dismiss()
            } catch {
                self.error = Net.describe(error)
            }
        }
    }
}

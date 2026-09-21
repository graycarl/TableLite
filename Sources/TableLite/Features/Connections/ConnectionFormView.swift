import AppKit
import SwiftUI

// MARK: - ConnectionFormView

/// 连接配置表单。三块分组卡片：基本信息 / MySQL / SSH 隧道。
/// 见 `specs/01-connections.md` §2。
struct ConnectionFormView: View {
    @StateObject private var viewModel: ConnectionFormViewModel

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var sheets: ConnectionSheets

    @State private var isShowingTest = false

    init(env: AppEnvironment, target: ConnectionSheets.Target) {
        _viewModel = StateObject(wrappedValue: ConnectionFormViewModel(env: env, target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.isNewConnection ? "新建连接" : "编辑连接")
                    .font(.title2.bold())
                Text("基本信息 / MySQL / SSH 隧道")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                Form {
                    basicSection
                    mysqlSection
                    sshSection
                }
                .formStyle(.grouped)
            }
            Divider()
            footer
        }
        .frame(minWidth: 660, minHeight: 580)
        .alert("保存连接失败",
               isPresented: Binding(get: { viewModel.alertMessage != nil },
                                    set: { if !$0 { viewModel.alertMessage = nil } })) {
            Button("关闭", role: .cancel) { viewModel.alertMessage = nil }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .alert("连接失败",
               isPresented: Binding(get: { viewModel.connectFailure != nil },
                                    set: { if !$0 { viewModel.connectFailure = nil } }),
               presenting: viewModel.connectFailure) { info in
            Button("重试") {
                Task { await viewModel.retryConnect(info) }
            }
            Button("关闭", role: .cancel) { viewModel.connectFailure = nil }
        } message: { info in
            Text(info.message)
        }
        .sheet(isPresented: $isShowingTest) {
            TestConnectionSheet(env: env,
                                connection: viewModel.makeConnection(),
                                password: viewModel.resolvedPassword) {
                let ok = await viewModel.saveAndConnect()
                if ok { close() }
                return ok
            }
            .environmentObject(env)
            .environmentObject(toasts)
        }
    }

    // MARK: 分组

    private var basicSection: some View {
        Section("基本信息") {
            FormField(label: "名称", error: viewModel.nameError) {
                TextField("连接列表里显示的名字", text: $viewModel.name)
                    .frame(width: 280)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("颜色")
                    .frame(width: 90, alignment: .trailing)
                Picker("", selection: $viewModel.color) {
                    ForEach(ConnectionColor.allCases) { color in
                        Label {
                            Text(color.displayName)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(connectionDotColor(color))
                        }
                        .tag(color)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Toggle("只读", isOn: $viewModel.readOnly)
                Text("禁止一切写操作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mysqlSection: some View {
        Section("MySQL") {
            HStack(alignment: .top, spacing: 12) {
                FormField(label: "主机", error: viewModel.hostError) {
                    TextField("域名或 IP", text: $viewModel.host)
                        .frame(width: 240)
                }
                FormField(label: "端口", error: viewModel.portError) {
                    TextField("3306", text: $viewModel.port)
                        .frame(width: 90)
                }
                Spacer()
            }

            FormField(label: "用户", error: viewModel.userError) {
                TextField("root", text: $viewModel.user)
                    .frame(width: 240)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("密码")
                    .frame(width: 90, alignment: .trailing)
                SecureField("可以留空", text: $viewModel.password)
                    .frame(width: 240)
                Toggle("保存到钥匙串", isOn: $viewModel.savePasswordToKeychain)
                if viewModel.hasSavedPassword {
                    Button("清除已保存密码") { viewModel.clearSavedPassword() }
                        .buttonStyle(.link)
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("数据库")
                    .frame(width: 90, alignment: .trailing)
                TextField("可以留空", text: $viewModel.database)
                    .frame(width: 240)
                Text("留空时连接后默认选中第一个可访问的库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("字符集")
                    .frame(width: 90, alignment: .trailing)
                Picker("", selection: $viewModel.charset) {
                    ForEach(viewModel.charsetOptions, id: \.self) { charset in
                        Text(charset).tag(charset)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
            }

            HStack(spacing: 20) {
                Toggle("使用 SSL", isOn: $viewModel.useSSL)
                Toggle("跳过证书校验", isOn: $viewModel.skipCertificateVerification)
                    .disabled(!viewModel.useSSL)
                Text("服务器使用自签证书时才勾选")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .top, spacing: 12) {
                FormField(label: "连接超时", error: viewModel.connectTimeoutError) {
                    TextField("10", text: $viewModel.connectTimeout)
                        .frame(width: 70)
                    Text("秒").foregroundStyle(.secondary)
                }
                FormField(label: "查询超时", error: viewModel.queryTimeoutError) {
                    TextField("300", text: $viewModel.queryTimeout)
                        .frame(width: 70)
                    Text("秒").foregroundStyle(.secondary)
                }
                Spacer()
            }

            FormField(label: "保持连接活跃", error: viewModel.keepAliveIntervalError) {
                Toggle("", isOn: $viewModel.keepAlive)
                    .labelsHidden()
                Text("每")
                TextField("30", text: $viewModel.keepAliveInterval)
                    .frame(width: 60)
                    .disabled(!viewModel.keepAlive)
                Text("秒发送心跳")
            }
        }
    }

    private var sshSection: some View {
        Section("SSH 隧道") {
            HStack(spacing: 12) {
                Toggle("通过 SSH 连接", isOn: $viewModel.sshEnabled)
                Text("勾上以后下面这些字段才可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .top, spacing: 12) {
                FormField(label: "SSH 主机", error: nil) {
                    TextField("bastion.example.com", text: $viewModel.sshHost)
                        .frame(width: 260)
                }
                FormField(label: "端口", error: viewModel.sshPortError) {
                    TextField("22", text: $viewModel.sshPort)
                        .frame(width: 80)
                }
                Spacer()
            }
            .disabled(!viewModel.sshEnabled)

            FormField(label: "SSH 用户", error: nil) {
                TextField("deploy", text: $viewModel.sshUser)
                    .frame(width: 260)
            }
            .disabled(!viewModel.sshEnabled)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("认证方式")
                        .frame(width: 90, alignment: .trailing)
                    Picker("", selection: $viewModel.authMethod) {
                        ForEach(SSHAuthMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Spacer()
                }

                if viewModel.authMethod == .privateKey {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("")
                            .frame(width: 90, alignment: .trailing)
                        TextField("~/.ssh/id_ed25519", text: $viewModel.privateKeyPath)
                            .frame(width: 280)
                        Button("选择…") { choosePrivateKey() }
                        Spacer()
                    }
                    if let error = viewModel.privateKeyError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 102)
                    }
                }
            }
            .disabled(!viewModel.sshEnabled)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Toggle("使用 ssh config 别名", isOn: $viewModel.useSSHConfigAlias)
                Text("跳板机")
                    .frame(width: 60, alignment: .trailing)
                TextField("user@proxy:22", text: $viewModel.jumpHost)
                    .frame(width: 200)
                Spacer()
            }
            .disabled(!viewModel.sshEnabled)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("测试连接") { isShowingTest = true }
                .disabled(!viewModel.isValid)
            Spacer()
            Button("取消") { close() }
            Button("保存") {
                if viewModel.save() { close() }
            }
            .disabled(!viewModel.isValid)
            Button("保存并连接") {
                Task {
                    if await viewModel.saveAndConnect() { close() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.isValid)
        }
        .padding(16)
    }

    // MARK: 动作

    private func close() {
        sheets.target = nil
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择 SSH 私钥文件"
        let sshDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".ssh", isDirectory: true)
        panel.directoryURL = sshDirectory
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.privateKeyPath = url.path
        }
    }
}

// MARK: - 字段行

private struct FormField<Content: View>: View {
    let label: String
    var error: String?
    let content: Content

    init(label: String, error: String?, @ViewBuilder content: () -> Content) {
        self.label = label
        self.error = error
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .frame(width: 90, alignment: .trailing)
                content
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 102)
            }
        }
    }
}

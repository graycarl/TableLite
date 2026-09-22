import SwiftUI
import UniformTypeIdentifiers

/// 连接配置表单（新建 / 编辑共用，`specs/01-connections.md` §2）。
///
/// 三块卡片纵向排列：基本信息 → MySQL → SSH 隧道；底部是测试连接 / 取消 / 保存。
/// 校验一律走 `ConnectionFormState.issues(fileExists:)`，不通过时「保存」禁用并逐条标红。
struct ConnectionFormView: View {

    @Binding var form: ConnectionFormState
    @Bindable var viewModel: ConnectionListViewModel

    @State private var isPrivateKeyPickerPresented = false

    private let labelWidth: CGFloat = 76

    // MARK: - 校验

    private var issues: [ConnectionFormIssue] {
        form.issues(fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    private func error(_ field: ConnectionFormIssue.Field) -> String? {
        issues.first { $0.field == field }?.message
    }

    private var charsetOptions: [String] {
        var options = ConnectionFormState.commonCharsets
        if !options.contains(form.charset) {
            options.insert(form.charset, at: 0)
        }
        return options
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Text(form.isEditing ? "编辑连接" : "新建连接")
                .font(.headline)
                .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicsCard
                    mysqlCard
                    sshCard
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 720)
        .sheet(isPresented: $viewModel.isTestPresented) {
            ConnectionTestView(
                sshEnabled: form.sshEnabled,
                report: viewModel.testReport,
                isTesting: viewModel.isTesting,
                onCancel: { viewModel.cancelTest() },
                onSaveAndConnect: { Task { await viewModel.saveAndConnectCurrentForm() } }
            )
        }
        .fileImporter(
            isPresented: $isPrivateKeyPickerPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                form.sshPrivateKeyPath = url.path
            }
        }
    }

    // MARK: - 基本信息

    private var basicsCard: some View {
        FormCard(title: "基本信息") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("名称")
                TextField("本地开发", text: $form.name)
                    .frame(width: 360)
            }
            errorLine(.name)

            HStack(alignment: .center, spacing: 10) {
                fieldLabel("颜色")
                Picker("", selection: $form.color) {
                    ForEach(ConnectionColor.allCases, id: \.self) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Circle()
                    .fill(form.color.swatchColor)
                    .frame(width: 10, height: 10)
                Spacer()
                Toggle("只读", isOn: $form.isReadOnly)
                    .toggleStyle(.checkbox)
                Text("禁止一切写操作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - MySQL

    private var mysqlCard: some View {
        FormCard(title: "MySQL") {
            mysqlAccountFields
            mysqlConnectionFields
        }
    }

    private var mysqlAccountFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("主机")
                TextField("127.0.0.1", text: $form.host)
                    .frame(width: 240)
                Text("端口")
                TextField("3306", text: $form.portText)
                    .frame(width: 80)
            }
            errorLine(.host)
            errorLine(.mysqlPort)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("用户")
                TextField("root", text: $form.user)
                    .frame(width: 240)
            }
            errorLine(.user)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("密码")
                SecureField("（可留空）", text: $form.password)
                    .frame(width: 240)
                Toggle("保存到钥匙串", isOn: $form.savePasswordToKeychain)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            HStack(spacing: 10) {
                Spacer()
                    .frame(width: labelWidth + 10)
                if form.hasStoredPassword {
                    Button("清除已保存密码") {
                        form.clearStoredPasswordRequested = true
                        form.password = ""
                    }
                    .controlSize(.small)
                    if form.clearStoredPasswordRequested {
                        Text("保存时清除")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("数据库")
                TextField("", text: $form.database)
                    .frame(width: 240)
                Text("（可留空，连上后选中第一个可访问的库）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mysqlConnectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("字符集")
                Picker("", selection: $form.charset) {
                    ForEach(charsetOptions, id: \.self) { charset in
                        Text(charset).tag(charset)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("Socket")
                TextField("", text: $form.unixSocket)
                    .frame(width: 300)
                Text("（可留空；填了优先于主机端口）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Spacer()
                    .frame(width: labelWidth + 10)
                Toggle("使用 SSL", isOn: $form.useSSL)
                    .toggleStyle(.checkbox)
                Toggle("跳过证书校验", isOn: $form.skipCertificateVerification)
                    .toggleStyle(.checkbox)
                    .disabled(!form.useSSL)
                Text("服务器用自签证书时才勾")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("连接超时")
                TextField("10", text: $form.connectTimeoutText)
                    .frame(width: 70)
                Text("秒")
                Text("查询超时")
                    .padding(.leading, 20)
                TextField("300", text: $form.queryTimeoutText)
                    .frame(width: 70)
                Text("秒")
                Spacer()
            }
            errorLine(.connectTimeout)
            errorLine(.queryTimeout)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Spacer()
                    .frame(width: labelWidth + 10)
                Toggle("保持连接活跃（每", isOn: $form.keepAlive)
                    .toggleStyle(.checkbox)
                TextField("30", text: $form.keepAliveIntervalText)
                    .frame(width: 56)
                    .disabled(!form.keepAlive)
                Text("秒发送心跳）")
                Spacer()
            }
            errorLine(.keepAliveInterval)
        }
    }

    // MARK: - SSH

    private var sshFieldsDisabled: Bool {
        !form.sshEnabled || form.sshUseConfigAlias
    }

    private var sshCard: some View {
        FormCard(title: "SSH 隧道") {
            sshConnectionFields
            sshAuthenticationFields
            sshAliasFields
        }
    }

    private var sshConnectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("通过 SSH 连接", isOn: $form.sshEnabled)
                .toggleStyle(.checkbox)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("SSH 主机")
                TextField("bastion.example.com", text: $form.sshHost)
                    .frame(width: 280)
                    .disabled(!form.sshEnabled)
                Text("端口")
                TextField("22", text: $form.sshPortText)
                    .frame(width: 70)
                    .disabled(sshFieldsDisabled)
            }
            errorLine(.sshHost)
            errorLine(.sshPort)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("SSH 用户")
                TextField("deploy", text: $form.sshUser)
                    .frame(width: 280)
                    .disabled(sshFieldsDisabled)
            }
            errorLine(.sshUser)
        }
    }

    private var sshAuthenticationFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("认证方式")
                Picker("", selection: $form.sshAuthMethod) {
                    ForEach(SSHAuthMethod.allCases, id: \.self) { method in
                        HStack(spacing: 6) {
                            Text(method.displayName)
                            if let note = method.formNote {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(method)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(sshFieldsDisabled)
            }

            if form.sshAuthMethod == .privateKey, !form.sshUseConfigAlias {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    fieldLabel("私钥")
                    TextField("~/.ssh/id_ed25519", text: $form.sshPrivateKeyPath)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 300)
                        .disabled(!form.sshEnabled)
                    Button("选择…") { isPrivateKeyPickerPresented = true }
                        .disabled(!form.sshEnabled)
                }
                errorLine(.privateKeyPath)
            }

            if form.sshAuthMethod == .password, !form.sshUseConfigAlias {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    fieldLabel("密码")
                    SecureField("（SSH 账号密码）", text: $form.sshPassword)
                        .frame(width: 300)
                        .disabled(!form.sshEnabled)
                }
            }
        }
    }

    private var sshAliasFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Spacer()
                    .frame(width: labelWidth + 10)
                Toggle("使用 ssh config 别名", isOn: $form.sshUseConfigAlias)
                    .toggleStyle(.checkbox)
                    .disabled(!form.sshEnabled)
                Spacer()
            }
            if form.sshUseConfigAlias {
                Text("别名模式下主机、端口、用户与密钥由 ~/.ssh/config 决定，界面里不再单独填写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, labelWidth + 10)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("跳板机")
                TextField("user@proxy:22", text: $form.sshJumpHost)
                    .frame(width: 220)
                    .disabled(!form.sshEnabled)
                Text("（可留空）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 底部按钮

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(issues) { issue in
                        Text("· \(issue.message)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            HStack {
                Button("测试连接") { viewModel.testCurrentForm() }
                Spacer()
                Button("取消") { viewModel.cancelForm() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    Task { await viewModel.saveCurrentForm() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!issues.isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - 小部件

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .frame(width: labelWidth, alignment: .leading)
    }

    @ViewBuilder
    private func errorLine(_ field: ConnectionFormIssue.Field) -> some View {
        if let message = error(field) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.leading, labelWidth + 10)
        }
    }
}

// MARK: - 卡片

private struct FormCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Divider()
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

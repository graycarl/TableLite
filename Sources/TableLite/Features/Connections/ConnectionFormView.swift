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
    /// 校验红字的揭示时机（`specs/01-connections.md` §2）：
    /// 用户编辑过表单（或点过「测试连接」/「保存」）之后才列出来，
    /// 避免新建连接时一打开就满屏报错。
    @State private var validationRevealed = false
    @State private var showAdvanced = false

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
            HStack(spacing: 8) {
                Text(form.isEditing ? "编辑连接" : "新建连接")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.cancelForm()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("关闭")
                .accessibilityIdentifier("sheet.connection.close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    connectionCard
                    if form.sshEnabled {
                        sshCard
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 580)
        .onChange(of: form) { _, _ in
            validationRevealed = true
            if hasAdvancedIssue { showAdvanced = true }
            viewModel.invalidateTestResult()
        }
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

    private var connectionModeBinding: Binding<Bool> {
        Binding(
            get: { form.sshEnabled },
            set: { form.sshEnabled = $0 }
        )
    }

    // MARK: - 连接

    private var connectionCard: some View {
        FormCard(title: "连接") {
            Picker("连接方式", selection: connectionModeBinding) {
                Text("直连").tag(false)
                Text("SSH 隧道").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .accessibilityIdentifier("sheet.connection.mode")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("名称")
                TextField("本地开发", text: $form.name)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sheet.connection.name")
            }
            errorLine(.name)

            HStack(alignment: .center, spacing: 10) {
                fieldLabel("颜色")
                colorSwatches
                Spacer()
                Toggle("只读", isOn: $form.isReadOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("禁止一切写操作")
                    .accessibilityIdentifier("sheet.connection.readonly")
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("主机")
                TextField("127.0.0.1", text: $form.host)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sheet.connection.host")
                Text("端口")
                    .foregroundStyle(.secondary)
                TextField("3306", text: $form.portText)
                    .frame(width: 80)
                    .accessibilityIdentifier("sheet.connection.port")
            }
            errorLine(.host)
            errorLine(.mysqlPort)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("用户")
                TextField("root", text: $form.user)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sheet.connection.user")
            }
            errorLine(.user)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("密码")
                SecureField("（可留空）", text: $form.password)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sheet.connection.password")
                Toggle("保存密码", isOn: $form.savePassword)
                    .toggleStyle(.checkbox)
            }

            if form.hasStoredPassword {
                HStack(spacing: 10) {
                    Spacer().frame(width: labelWidth + 10)
                    Button("清除已保存密码") {
                        form.clearStoredPasswordRequested = true
                        form.password = ""
                    }
                    .buttonStyle(.subtle)
                    .controlSize(.small)
                    if form.clearStoredPasswordRequested {
                        Text("保存时清除")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel("数据库")
                TextField("", text: $form.database)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sheet.connection.database")
                Text("（可留空）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                mysqlConnectionFields
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text("高级选项")
                    if hasAdvancedIssue {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(AppFont.body)
            .accessibilityIdentifier("sheet.connection.advanced")
        }
    }

    private var hasAdvancedIssue: Bool {
        issues.contains { issue in
            switch issue.field {
            case .connectTimeout, .queryTimeout, .keepAliveInterval: return true
            default: return false
            }
        }
    }

    private var colorSwatches: some View {
        HStack(spacing: 7) {
            ForEach(ConnectionColor.allCases, id: \.self) { color in
                Button {
                    form.color = color
                } label: {
                    Circle()
                        .fill(color.swatchColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(
                                    form.color == color ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: form.color == color ? 2 : 1
                                )
                        )
                        .overlay {
                            if color == .none {
                                Image(systemName: "slash")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
                .accessibilityIdentifier("sheet.connection.color.\(color.rawValue)")
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
        HStack(spacing: 8) {
            Button {
                validationRevealed = true
                viewModel.testCurrentForm()
            } label: {
                Label("测试连接", systemImage: "bolt.horizontal")
            }
            .buttonStyle(.subtle)
            .accessibilityIdentifier("sheet.connection.test")
            .disabled(viewModel.isTesting)

            if viewModel.isTesting {
                ProgressView()
                    .controlSize(.small)
                Text("正在测试…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("取消测试") { viewModel.cancelTest() }
                    .buttonStyle(.subtle)
                    .controlSize(.small)
                    .accessibilityIdentifier("sheet.connection.test-cancel")
            } else if let report = viewModel.testReport {
                if report.succeeded {
                    Label("连接成功", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("连接失败", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("详情") { viewModel.isTestPresented = true }
                    .buttonStyle(.subtle)
                    .controlSize(.small)
                    .accessibilityIdentifier("sheet.connection.test-details")
            }

            Spacer()

            Button("取消") { viewModel.cancelForm() }
                .accessibilityIdentifier("sheet.connection.cancel")
                .keyboardShortcut(.cancelAction)
            Button("保存") {
                Task { await viewModel.saveCurrentForm() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sheet.connection.save")
            .keyboardShortcut(.defaultAction)
            .disabled(!issues.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 小部件

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .frame(width: labelWidth, alignment: .leading)
    }

    @ViewBuilder
    private func errorLine(_ field: ConnectionFormIssue.Field) -> some View {
        if validationRevealed, let message = error(field) {
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
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AppRadius.l))
    }
}

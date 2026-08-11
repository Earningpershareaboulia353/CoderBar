import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 176)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(selection.title, systemImage: selection.symbol)
                        .font(.system(size: 17, weight: .semibold))
                    selectedContent
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 680, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.primary) { sidebarButton($0) }
            Text("CoderBar")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.horizontal, 12)
            ForEach(SettingsSection.secondary) { sidebarButton($0) }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.7))
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button { selection = section } label: {
            Label(section.title, systemImage: section.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selection == section ? Color.primary.opacity(0.10) : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .general: generalContent
        case .integrations: integrationsContent
        case .notifications: notificationsContent
        case .display: displayContent
        case .sound: soundContent
        case .usage: usageContent
        case .shortcuts: shortcutsContent
        case .labs: labsContent
        case .about: aboutContent
        }
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("系统") {
                Toggle("登录时打开", isOn: $model.launchAtLogin)
            }
            settingsGroup("展开") {
                Toggle("悬停时展开面板", isOn: $model.hoverToExpand)
                valueSlider(
                    title: "悬停延迟",
                    value: $model.hoverDelaySeconds,
                    range: 0...0.8,
                    step: 0.05,
                    suffix: "秒"
                )
            }
            settingsGroup("收起") {
                Toggle("鼠标离开时自动收起", isOn: $model.autoCollapseOnMouseLeave)
                valueSlider(
                    title: "提醒停留时间",
                    value: $model.alertDwellSeconds,
                    range: 2...15,
                    step: 1,
                    suffix: "秒"
                )
                Text("点击面板外区域仍会立即收起。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var integrationsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("Agent 会话") {
                Text("已发现 \(model.desktopSessionCount) 个 Codex App / Claude App 会话")
                Text("桌面会话负责会话列表；Hooks 补充实时工具、审批和提问状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            settingsGroup("Hooks") {
                Label(
                    model.hooksConfigured ? "Hooks 已安装" : "Hooks 尚未安装",
                    systemImage: model.hooksConfigured ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .foregroundStyle(model.hooksConfigured ? .green : .orange)
                HStack {
                    if model.hooksConfigured {
                        Button("重新安装", action: model.configureHooks)
                        Button("移除", action: model.deconfigureHooks).tint(.red)
                    } else {
                        Button("安装 Hooks", action: model.configureHooks)
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("打开数据目录", action: model.openDataFolder)
                }
                Text("升级后请点“重新安装”，让 Agent 使用包含审批回复通道的新 Hook。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning = model.desktopDiscoveryWarning {
                settingsGroup("诊断") {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var notificationsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("提醒") {
                Toggle("Agent 需要处理时发送系统通知", isOn: $model.notificationsEnabled)
                Toggle("审批或提问时自动展开", isOn: $model.autoExpandOnAlert)
                Picker("完成提醒", selection: $model.completionPresentation) {
                    Text("轻瞥（保持收起）").tag("glance")
                    Text("展开面板").tag("expand")
                }
                .pickerStyle(.radioGroup)
                Button("发送测试通知", action: model.testNotification)
            }
            settingsGroup("Codex 审批提醒") {
                Picker("处理方式", selection: $model.codexApprovalMode) {
                    Text("跟随焦点并展开").tag("followFocus")
                    Text("只提醒我").tag("notify")
                    Text("保持安静").tag("silent")
                }
                .pickerStyle(.radioGroup)
                Text("保持安静只隐藏 Clone 的提醒，不会自动批准请求。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("屏幕") {
                Picker("显示器", selection: $model.displayTargetID) {
                    ForEach(model.displayTargetOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                Text("“主显示器”固定到硬件主屏，不会跟随当前 App 跳动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            settingsGroup("尺寸与字体") {
                valueSlider(title: "面板宽度", value: $model.panelWidth, range: 440...800, step: 10, suffix: "pt")
                valueSlider(title: "最大高度", value: $model.maxPanelHeight, range: 280...720, step: 10, suffix: "pt")
                valueSlider(title: "内容字体", value: $model.contentFontSize, range: 10...16, step: 0.5, suffix: "pt")
            }
            settingsGroup("会话卡片") {
                Toggle("显示项目", isOn: $model.showProjectName)
                Toggle("显示模型", isOn: $model.showModel)
                Toggle("显示推理强度", isOn: $model.showReasoningEffort)
                Toggle("显示任务", isOn: $model.showTasks)
                Toggle("显示 Sub Agent", isOn: $model.showSubagents)
                Toggle("显示当前活动", isOn: $model.showActivity)
            }
        }
    }

    private var soundContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("声音") {
                Toggle("启用声音", isOn: $model.soundsEnabled)
                valueSlider(title: "音量", value: $model.soundVolume, range: 0...1, step: 0.05, suffix: "")
                    .disabled(!model.soundsEnabled)
            }
            settingsGroup("事件") {
                Toggle("会话开始", isOn: $model.soundOnStart)
                Toggle("会话完成", isOn: $model.soundOnCompletion)
                Toggle("审批、提问与计划确认", isOn: $model.soundOnApproval)
            }
        }
    }

    private var usageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("用量卡片") {
                Toggle("在顶部显示 Codex 用量", isOn: $model.showUsage)
                Picker("百分比", selection: $model.usageShowsRemaining) {
                    Text("已使用").tag(false)
                    Text("剩余").tag(true)
                }
                .pickerStyle(.segmented)
                Text("数据直接读取 Codex 会话里的 5h/7d rate limit 窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("面板快捷键") {
                Toggle("启用面板键盘操作", isOn: $model.panelShortcutsEnabled)
                shortcutRow("收起面板", key: "Esc")
                shortcutRow("允许当前审批 / 批准计划", key: "Y")
                shortcutRow("拒绝当前审批 / 返回修改", key: "N")
                shortcutRow("选择并提交单题选项", key: "⌘1…⌘9")
                shortcutRow("跳转当前会话", key: "T")
                Text("多题和多选仍需在卡片中确认后提交，避免误答。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var labsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("更新") {
                Toggle("接收 Beta 更新", isOn: $model.betaUpdates)
            }
            settingsGroup("Agent App") {
                Toggle("在岛内处理 Claude 审批与提问", isOn: $model.claudeNativeApprovals)
                Toggle("优先在 Codex App 打开 app-server 会话", isOn: $model.openAppServerSessionsInCodex)
                Text("关闭 Claude 处理后，Hook 会立即交还给 Claude 自己的界面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            settingsGroup("协议能力") {
                Label("Claude/Codex Hook：支持审批允许与拒绝", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Claude AskUserQuestion：支持选项、自定义答案和多题", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Codex App request_user_input：当前为只读并跳回 Codex", systemImage: "info.circle.fill")
                    .foregroundStyle(.orange)
                Text("Clone 不会把协议不支持的动作伪装成成功。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aboutContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.purple)
            Text("CoderBar").font(.title3.weight(.semibold))
            Text("v\(model.appVersion)").font(.caption).foregroundStyle(.secondary)
            Text("SwiftUI 顶部 Agent 会话面板").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("打开数据目录", action: model.openDataFolder)
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 92, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(formatted(value.wrappedValue, step: step) + suffix)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func formatted(_ value: Double, step: Double) -> String {
        step < 1 ? String(format: "%.2g", value) : String(Int(value.rounded()))
    }

    private func shortcutRow(_ title: String, key: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 11) { content() }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, integrations, notifications, display, sound, usage, shortcuts, labs, about

    var id: String { rawValue }
    static let primary: [SettingsSection] = [
        .general, .integrations, .notifications, .display, .sound, .usage, .shortcuts
    ]
    static let secondary: [SettingsSection] = [.labs, .about]

    var title: String {
        switch self {
        case .general: return "通用"
        case .integrations: return "集成"
        case .notifications: return "通知"
        case .display: return "显示"
        case .sound: return "声音"
        case .usage: return "用量"
        case .shortcuts: return "快捷键"
        case .labs: return "实验室"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        case .notifications: return "bell.fill"
        case .display: return "textformat.size"
        case .sound: return "speaker.wave.2.fill"
        case .usage: return "chart.bar.fill"
        case .shortcuts: return "keyboard.fill"
        case .labs: return "flask.fill"
        case .about: return "info.circle.fill"
        }
    }
}

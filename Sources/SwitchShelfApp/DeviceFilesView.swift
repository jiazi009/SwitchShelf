import SwiftUI
import SwitchShelfDevice

/// Native MTP file browser. Transfers are explicit single-file actions; ordinary
/// uploads use the writable microSD projection rather than installation storages.
struct DeviceFilesView: View {
    @Bindable var model: DeviceFileManagerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                storageSidebar.frame(width: 172)
                Divider()
                folderPane.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(Theme.canvas)
        .accessibilityIdentifier("device-file-manager")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PageHeading(title: "文件管理", subtitle: "浏览 Switch 存储，上传与下载单个文件")
            Spacer(minLength: 8)
            Label("USB", systemImage: "cable.connector")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Button { model.refreshStorages() } label: {
                Label("读取存储", systemImage: "externaldrive.badge.checkmark")
            }
            .buttonStyle(.glass)
            .disabled(model.isBusy || model.blocker != nil)
            .help("重新读取设备报告的存储入口。")
            .accessibilityIdentifier("read-device-file-storages")
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private var storageSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设备存储")
                .font(.system(.caption, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(model.storages.enumerated()), id: \.offset) { _, storage in storageButton(storage) }
                }
                .padding(.horizontal, 8)
            }
            if model.storages.isEmpty {
                Text(model.isBusy ? "正在读取…" : "尚未读取存储")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.bottom, 18)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Label("普通文件传输", systemImage: "doc.on.doc")
                    .font(.system(.caption, weight: .medium))
                Text("上传到可写 microSD 目录。单个文件需小于 4 GiB；安装包请从游戏库发送。")
                    .font(.system(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .background(Theme.surfaceMuted)
    }

    private func storageButton(_ storage: MTPFileStorage) -> some View {
        let selected = model.location?.storageName == storage.name
        let ambiguous = model.storages.filter { $0.name == storage.name }.count != 1
        return Button { model.openStorage(storage) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: storage.canUpload ? "sdcard" : "externaldrive")
                        .font(.system(size: 13)).foregroundStyle(selected ? Theme.accent : .secondary)
                    Text(storage.name).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                Text(storage.role).font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(2)
                if let capacity = storage.capacityBytes, capacity > 0, let free = storage.freeBytes {
                    ProgressView(value: Double(capacity - min(capacity, free)), total: Double(capacity))
                        .tint(selected ? Theme.accent : .secondary)
                        .accessibilityLabel("已使用容量")
                    Text("可用 \(fileByteText(free)) / \(fileByteText(capacity))")
                        .font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || model.blocker != nil || ambiguous)
        .help(ambiguous ? "设备报告了重复存储名称，无法确定入口。" : storage.role)
        .accessibilityLabel("浏览 \(storage.name)，\(storage.role)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var folderPane: some View {
        VStack(spacing: 0) {
            pathBar
            controls
            if let message = model.message {
                messageBanner(message, error: model.messageIsError)
            }
            if model.isBusy { operationProgress }
            fileContent
            footer
        }
    }

    private var pathBar: some View {
        HStack(spacing: 7) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bordered)
                .disabled(!model.canGoBack)
                .help("返回上一个文件夹")
                .accessibilityLabel("返回上一个文件夹")
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.location?.components.isEmpty != false || model.blocker != nil)
                .help("上一级文件夹")
                .accessibilityLabel("上一级文件夹")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let location = model.location {
                        breadcrumb(location.storageName, location: MTPFileLocation(storageName: location.storageName))
                        ForEach(Array(location.components.enumerated()), id: \.offset) { index, name in
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                            breadcrumb(name, location: MTPFileLocation(storageName: location.storageName,
                                                                      components: Array(location.components.prefix(index + 1))))
                        }
                    } else {
                        Label("选择设备存储", systemImage: "externaldrive")
                            .foregroundStyle(.secondary).font(.system(size: 11.5))
                    }
                }
            }
            Spacer(minLength: 0)
            Button { model.refreshCurrentFolder() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.blocker != nil)
                .help("刷新当前文件夹")
                .accessibilityLabel("刷新当前文件夹")
                .accessibilityIdentifier("refresh-device-files")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private func breadcrumb(_ title: String, location: MTPFileLocation) -> some View {
        Button(title) { model.navigate(to: location) }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .disabled(model.isBusy || model.blocker != nil)
            .help(location.displayPath)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { searchField; transferButtons }
            VStack(spacing: 8) {
                searchField
                HStack { Spacer(minLength: 0); transferButtons }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索当前文件夹", text: $model.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索当前文件夹")
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("清除文件搜索")
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10).frame(minWidth: 120, maxWidth: .infinity, minHeight: 30)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline) }
    }

    private var transferButtons: some View {
        HStack(spacing: 7) {
            Picker("排序", selection: $model.sortOrder) {
                ForEach(DeviceFileManagerModel.SortOrder.allCases) { order in Text(order.label).tag(order) }
            }
            .labelsHidden().frame(width: 82).controlSize(.small).help("文件夹优先，按所选方式排序")
            Button { model.openSelected() } label: { Image(systemName: "folder") }
                .disabled(!model.canOpenSelection).help("打开选中的文件夹")
                .accessibilityLabel("打开选中的文件夹")
                .keyboardShortcut(.return, modifiers: [])
            Button { model.chooseDownload() } label: { Label("下载", systemImage: "arrow.down.to.line") }
                .disabled(!model.canDownload).help(model.downloadIssue ?? "将选中的文件下载到本机，不覆盖已有文件")
                .accessibilityIdentifier("download-device-file")
            Button { model.chooseUpload() } label: { Label("上传", systemImage: "arrow.up.to.line") }
                .disabled(!model.canUpload).help("上传单个普通文件到当前 microSD 文件夹，不覆盖已有文件")
                .accessibilityIdentifier("upload-device-file")
        }
        .font(.system(size: 11.5))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var fileContent: some View {
        if model.listing == nil {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(Theme.accent.opacity(0.7))
                Text(model.blocker == nil ? "选择一个存储入口" : "等待设备连接")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.blocker ?? "从左侧选择 microSD card 等入口，浏览设备实际提供的文件与文件夹。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.visibleRows, selection: $model.selectedEntryID) {
                TableColumn("名称") { row in
                    let entry = row.entry
                    HStack(spacing: 7) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : fileSymbol(entry.name))
                            .foregroundStyle(entry.isDirectory ? Theme.accent : .secondary)
                            .frame(width: 16)
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11.5))
                    .help(entry.name)
                    .onTapGesture(count: 2) { model.open(entry) }
                }
                .width(min: 140, ideal: 250)
                TableColumn("大小") { row in
                    let entry = row.entry
                    Text(entry.isDirectory ? "—" : fileByteText(entry.byteCount))
                        .font(.system(.caption)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 64, ideal: 76, max: 92)
                TableColumn("种类") { row in
                    let entry = row.entry
                    Text(fileType(entry)).font(.system(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 58, ideal: 70, max: 90)
                TableColumn("修改时间") { row in
                    let entry = row.entry
                    Text(fileDateText(entry.modifiedDate)).font(.system(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        .help(entry.modifiedDate ?? "设备未提供修改时间")
                }
                .width(min: 100, ideal: 120, max: 140)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .disabled(model.isBusy)
            .overlay {
                if model.visibleEntries.isEmpty, !model.isBusy {
                    Text(model.searchText.isEmpty ? "这个文件夹是空的" : "没有匹配的文件")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("device-file-table")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let selected = model.selectedEntry {
                HStack(spacing: 7) {
                    Image(systemName: selected.isDirectory ? "folder" : "doc")
                    Text(selected.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(selected.isDirectory ? "文件夹" : fileByteText(selected.byteCount)).foregroundStyle(.secondary)
                }
                .font(.system(.caption))
                if let issue = model.downloadIssue {
                    Text(issue).font(.system(.caption)).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Text(model.searchText.isEmpty ? "\(model.listing?.entries.count ?? 0) 项" : "\(model.visibleEntries.count) / \(model.listing?.entries.count ?? 0) 项")
                Spacer(minLength: 8)
                if let storage = model.currentStorage {
                    Text(storage.canUpload ? "可上传普通文件" : "只读浏览")
                    if let free = storage.freeBytes { Text("可用 \(fileByteText(free))") }
                }
            }
            .font(.system(.caption)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private func messageBanner(_ message: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(error ? Theme.warning : Theme.installed)
            Text(message).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.dismissMessage() } label: { Image(systemName: "xmark").font(.system(.caption2, weight: .semibold)) }
                .buttonStyle(.plain).accessibilityLabel("关闭文件操作提示")
        }
        .padding(10).background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var operationProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.operationTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Button("停止") { model.cancel() }.font(.system(.caption)).buttonStyle(.plain)
                    .accessibilityLabel("停止当前文件操作")
            }
            if let progress = model.progress, let total = progress.totalBytes, total > 0 {
                ProgressView(value: Double(min(progress.bytesTransferred, total)), total: Double(total))
                HStack {
                    Text(progress.phase)
                    Spacer()
                    Text("\(fileByteText(progress.bytesTransferred)) / \(fileByteText(total))").monospacedDigit()
                }
                .font(.system(.caption2)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12).background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

private func fileByteText(_ value: UInt64?) -> String {
    guard let value else { return "未知" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

private func fileType(_ entry: MTPFileEntry) -> String {
    if entry.isDirectory { return "文件夹" }
    let ext = (entry.name as NSString).pathExtension.uppercased()
    return ext.isEmpty ? "文件" : "\(ext) 文件"
}

private func fileSymbol(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "webp", "bmp": "photo"
    case "mp4", "mov", "mkv": "film"
    case "mp3", "wav", "flac": "waveform"
    case "zip", "7z", "rar": "doc.zipper"
    case "nsp", "nsz", "xci", "xcz", "nro": "gamecontroller"
    case "txt", "ini", "json", "log", "cfg": "doc.text"
    default: "doc"
    }
}

private func fileDateText(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "未知" }
    // Display the device's timestamp text. This does not invent a timezone or a
    // missing date; common MTP YYYYMMDDTHHMMSS strings become easier to scan.
    let characters = Array(value)
    if characters.count >= 15, characters[8] == "T",
       characters.prefix(8).allSatisfy(\.isNumber), characters[9..<15].allSatisfy(\.isNumber) {
        return "\(String(characters[0..<4]))-\(String(characters[4..<6]))-\(String(characters[6..<8])) \(String(characters[9..<11])):\(String(characters[11..<13]))"
    }
    return value
}

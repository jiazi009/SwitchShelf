import SwiftUI
import SwitchShelfDevice

/// Album screenshots from recognized MTP roots, with preview and local download.
struct AlbumScreenshotsView: View {
    @Bindable var model: AlbumScreenshotModel
    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = model.message { messageBanner(message, error: model.messageIsError) }
            if model.isBusy { operationProgress }
            HStack(spacing: 0) {
                gallery.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                Divider()
                preview.frame(width: 300)
            }
            footer
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(Theme.canvas)
        .accessibilityIdentifier("album-screenshots")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                PageHeading(title: "相册截图", subtitle: "查看并下载 Switch 相册里的 jpg、jpeg、png")
                Spacer(minLength: 8)
                Button { model.reload() } label: { Label("读取相册", systemImage: "photo.badge.arrow.down") }
                    .buttonStyle(.glass)
                    .disabled(!model.canRead)
                    .accessibilityIdentifier("read-album-screenshots")
                Button { model.downloadSelected() } label: { Label("下载", systemImage: "arrow.down.to.line") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.canDownloadSelection)
                    .accessibilityIdentifier("download-album-screenshot")
                Button { model.downloadVisible() } label: { Label("全部下载", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.canDownloadVisible)
                    .accessibilityIdentifier("download-all-album-screenshots")
            }
            Text("来自 Album、Album (Image SD)、相册工具，以及 SD 卡的 Nintendo/Album。下载到本机时不覆盖已有文件，也不删除设备上的截图。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            searchField
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索截图名称或路径", text: $model.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索相册截图")
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("清除截图搜索")
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10).frame(maxWidth: 420, minHeight: 30, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline) }
    }

    @ViewBuilder
    private var gallery: some View {
        if model.screenshots.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(Theme.accent.opacity(0.7))
                Text(model.isBusy ? "正在读取相册" : (model.blocker == nil ? "尚未读取相册" : "等待设备连接"))
                    .font(.system(size: 15, weight: .semibold))
                Text(model.blocker ?? "连接 Switch 并打开 sphaira / DBI 的 MTP，然后读取相册。点一张截图可预览，下载会保存到你选择的位置。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleShots.isEmpty {
            Text("没有匹配的截图")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.visibleShots) { entry in shotCard(entry) }
                }
                .padding(16)
            }
        }
    }

    private func shotCard(_ entry: MTPFileEntry) -> some View {
        let selected = model.selectedEntryID == entry.id
        return Button { model.select(entry) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceAlt)
                    if selected, let image = model.previewImage, model.previewEntryID == entry.id {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(entry.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(albumDateText(entry.modifiedDate)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Text(albumByteText(entry.byteCount)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.10) : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent.opacity(0.45) : Theme.hairline) }
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .help(entry.location.displayPath + "/" + entry.name)
        .accessibilityLabel("\(entry.name)，\(albumByteText(entry.byteCount))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            if let entry = model.selectedEntry, let image = model.previewImage, model.previewEntryID == entry.id {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(entry.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(entry.location.displayPath).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
                Text("\(albumByteText(entry.byteCount)) · \(albumDateText(entry.modifiedDate))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.selectedEntry == nil ? "选择一张截图" : "点选后从设备下载这一张作为预览")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: 220)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surfaceMuted)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.searchText.isEmpty ? "\(model.screenshots.count) 张" : "\(model.visibleShots.count) / \(model.screenshots.count) 张")
            if model.truncated { Text("列表不完整").foregroundStyle(Theme.warning) }
            Spacer(minLength: 8)
            Text("只下载，不修改设备")
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private func messageBanner(_ message: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(error ? Theme.warning : Theme.installed)
            Text(message).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.dismissMessage() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).accessibilityLabel("关闭相册提示")
        }
        .padding(10).background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private var operationProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.operationTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Button("停止") { model.cancel() }.font(.system(size: 10.5)).buttonStyle(.plain)
                    .accessibilityLabel("停止相册下载")
            }
            if let progress = model.progress, let total = progress.totalBytes, total > 0 {
                ProgressView(value: Double(min(progress.bytesTransferred, total)), total: Double(total))
                HStack {
                    Text(progress.phase)
                    Spacer()
                    Text("\(albumByteText(progress.bytesTransferred)) / \(albumByteText(total))").monospacedDigit()
                }
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12).background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 16).padding(.top, 10)
    }
}

private func albumByteText(_ value: UInt64?) -> String {
    guard let value else { return "未知" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

private func albumDateText(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "时间未知" }
    let characters = Array(value)
    if characters.count >= 15, characters[8] == "T",
       characters.prefix(8).allSatisfy(\.isNumber), characters[9..<15].allSatisfy(\.isNumber) {
        return "\(String(characters[0..<4]))-\(String(characters[4..<6]))-\(String(characters[6..<8])) \(String(characters[9..<11])):\(String(characters[11..<13]))"
    }
    return value
}

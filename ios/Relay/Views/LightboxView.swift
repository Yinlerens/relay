import SwiftUI
import UIKit

/// Full-screen zoomable lightbox for authenticated image attachments.
struct LightboxView: View {
    let attachment: Attachment

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var dismissDrag: CGFloat = 0
    @State private var chromeVisible = true

    private var backdropOpacity: Double {
        1 - min(Double(abs(dismissDrag)) / 500, 0.7)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dismissDrag)
                    .gesture(magnify.simultaneously(with: drag))
                    .onTapGesture(count: 2) {
                        Haptics.tap(.soft)
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            if scale > 1.01 {
                                resetZoom()
                            } else {
                                scale = 2.5
                                baseScale = 2.5
                            }
                        }
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
        }
        .overlay(alignment: .topTrailing) {
            if chromeVisible {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .glassCircle()
                }
                .buttonStyle(.pressable)
                .padding(.trailing, 18)
                .padding(.top, 8)
                .transition(.opacity)
                .accessibilityLabel("关闭")
            }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible {
                HStack(spacing: 12) {
                    Text(attachment.filename)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let image {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview(attachment.filename, image: Image(uiImage: image))
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                .glassCapsule()
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!chromeVisible)
        .task(id: attachment.id) {
            if let cached = AttachmentImageCache.shared.cached(attachment.id) {
                image = cached
                return
            }
            guard let api = store.api else { return }
            let loaded = await AttachmentImageCache.shared.image(for: attachment.id, api: api)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { resetZoom() }
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.01 {
                    offset = CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    )
                } else {
                    dismissDrag = value.translation.height
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    baseOffset = offset
                } else if abs(value.translation.height) > 140 || abs(value.predictedEndTranslation.height) > 420 {
                    Haptics.tap(.soft)
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { dismissDrag = 0 }
                }
            }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

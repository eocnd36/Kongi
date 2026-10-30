import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 안드로이드 앱 연결: 켜기, QR 코드, 연결된 휴대폰, 다시 연결
struct PhoneSection: View {
    @ObservedObject var mobile: MobileBridge
    @AppStorage(AppSettings.mobileEnabled) private var enabled = false
    @AppStorage(AppSettings.mobileNotifications) private var notifications = true

    var body: some View {
        Group { content }
            .onChange(of: enabled) { _ in mobile.applySettings() }
            .onAppear { mobile.refreshAddresses() }
    }

    @ViewBuilder
    private var content: some View {
        KCard {
            KToggleRow(
                title: String(localized: "Use Kongi on your Android phone"),
                detail: String(localized: "See sessions, approve requests and send prompts from the Kongi app while your phone is on the same Wi-Fi as this Mac. Everything is encrypted with a key only your phone and Mac know."),
                isOn: $enabled
            )
        }
        if enabled {
            KCard {
                if !mobile.running {
                    Label("Kongi couldn't open its connection. Another app may be using port 47815.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(KongiTheme.orange)
                } else if let url = mobile.pairingURL {
                    HStack(alignment: .top, spacing: 18) {
                        if let qr = Self.qrCode(url.absoluteString) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 150, height: 150)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            step(1, String(localized: "Install the Kongi app (APK) on your Android phone."))
                            step(2, String(localized: "Connect the phone to the same Wi-Fi as this Mac."))
                            step(3, String(localized: "Scan this code with the phone's camera, or with “Scan QR code” in the app."))
                            Text(verbatim: mobile.addresses.joined(separator: " · "))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(KongiTheme.muted)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    HStack {
                        Label("This Mac isn't on a Wi-Fi or wired network.", systemImage: "wifi.slash")
                            .font(.system(size: 12.5))
                            .foregroundStyle(KongiTheme.orange)
                        Spacer()
                        KButton(title: String(localized: "Check again")) { mobile.refreshAddresses() }
                    }
                }
            }
            KCard {
                KRow(title: String(localized: "Connected phones"), detail: String(localized: "The phone stays connected while the Kongi app is open, or in the background if you allow it in the app.")) {
                    Text(verbatim: "\(mobile.connectedPhones)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(mobile.connectedPhones > 0 ? KongiTheme.green : KongiTheme.muted)
                }
                KDivider()
                KToggleRow(title: String(localized: "Send notifications to the phone too"), isOn: $notifications)
                KDivider()
                KRow(title: String(localized: "Reset phone access"), detail: String(localized: "Makes a new code. Phones that were connected need to scan again.")) {
                    KButton(title: String(localized: "Reset"), style: .destructive) { mobile.resetPairing() }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(KongiTheme.onAccent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(KongiTheme.accent))
            Text(verbatim: text)
                .font(.system(size: 12.5))
                .foregroundStyle(KongiTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

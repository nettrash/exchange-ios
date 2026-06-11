//
//  DocumentPicker.swift
//  Exchange
//
//  Imperative system document picker.
//
//  Why not SwiftUI's `.fileImporter` or a `UIViewControllerRepresentable`
//  in a sheet? Both misbehave on Mac Catalyst: `.fileImporter`'s
//  completion never fires after the open panel closes, and an embedded
//  `UIDocumentPickerViewController` (which expects to be *presented*
//  modally, not hosted as a sheet's content) doesn't function. Presenting
//  it modally from the top view controller is reliable on both iOS and
//  macOS. `asCopy: true` returns a readable copy in the app container, so
//  callers don't manage security-scoped access.
//

import UIKit
import UniformTypeIdentifiers

enum DocumentPicker {
    /// Present the system document picker and call `onPick` with a
    /// readable copy of the chosen file. No-op if no presenter is found.
    static func pick(contentTypes: [UTType], onPick: @escaping (URL) -> Void) {
        guard let top = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = Delegate(onPick: onPick)
        retained = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    /// Keeps the one-shot delegate alive while the picker is on screen.
    private static var retained: Delegate?

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            defer { DocumentPicker.retained = nil }
            if let url = urls.first { onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DocumentPicker.retained = nil
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

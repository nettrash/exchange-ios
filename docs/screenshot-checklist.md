# Screenshot Capture Checklist

App Store Connect requires at least three screenshots per supported device class, up to ten. The bare minimum is **6.7-inch iPhone** — App Store Connect downscales it for smaller devices. Adding **12.9-inch iPad** is optional but lifts conversion if you're targeting iPad too.

## Required resolutions

| Device class                | Resolution        | Notes                                   |
|-----------------------------|-------------------|-----------------------------------------|
| 6.7" iPhone (iPhone 15 Pro Max etc.) | **1290×2796 px** or **1320×2868 px** | The required class for first submission |
| 6.5" iPhone (iPhone 11 Pro Max etc.) | 1242×2688 px      | Optional; auto-derived if absent        |
| 5.5" iPhone (older)         | 1242×2208 px      | Optional                                |
| 12.9" iPad Pro              | 2048×2732 px      | Required only if app supports iPad      |

In Xcode's iOS Simulator, choose **iPhone 16 Pro Max** to get the 6.7" 1320×2868 capture. Press **⌘S** or **Device → Screenshot** to save to Desktop.

## Pre-capture state

Before screenshots, set up the app's data so it looks plausible:

1. Generate a fresh identity (delete the app first to wipe).
2. Add three recipients with realistic names — e.g. "Alice", "Bob", "Carol". Use throwaway public keys generated in a test playground or just other simulator instances.
3. For the Compose result screenshot, encrypt a sample message ("Coffee at 4? — Ivan") to Alice and capture the screen with the EXC2 envelope visible.
4. For the Decrypt result screenshot, paste an envelope you've previously generated and capture the post-decrypt state showing the verified-from message.

## Required screenshots (capture these for 6.7" iPhone)

The order matters — App Store Connect uses the first screenshot as the primary tile in search results, and the next two often show as previews on iPhone search.

### 1. Home screen — identity row + recipients

**State:** Main app, no sheets open. Identity loaded, three recipients in the list.

**Why first:** establishes the app's purpose at a glance — your key + people you talk to.

**Capture tips:** scroll so the identity row is fully visible at top. Recipient names should be readable but not too compressed.

### 2. Encrypted result with Share button

**State:** ComposeView's result step. EXC2 envelope visible in the monospaced text. Copy/Share buttons clearly tappable.

**Why second:** this is the moment that demonstrates the app actually does something — text in becomes ciphertext out, ready to send anywhere.

**Capture tips:** make sure the envelope text fills several rows so it's clearly an encrypted blob, not a 5-character placeholder.

### 3. iMessage extension bubble in a conversation

**State:** Real iMessage thread (use the simulator's Messages buddy mode, or capture from your real device). The 🔒 Encrypted message bubble has been received, ready to tap.

**Why third:** shows the seamless iMessage integration that's the differentiating UX.

### 4. Decrypt result with verified sender

**State:** DecryptView's result step. Plaintext visible, footer showing "Signature verified — from Alice".

**Why fourth:** demonstrates sender authentication — the trust story behind the encryption.

### 5. My Identity QR sheet

**State:** MyIdentityQRView open. QR visible, fingerprint underneath.

**Why fifth:** shows the in-person key exchange flow, the most distinctive onboarding moment.

### 6. Add Recipient with Scan QR option

**State:** AddRecipientView with a public key being entered (either typed or just-scanned). Scan QR button visible.

**Why sixth:** completes the onboarding story — you can scan the other person's QR to add them in seconds.

### 7. (Optional) Decrypt sheet with paste-from-clipboard

**State:** DecryptView's input step with the envelope text editor and Paste from clipboard button.

### 8. (Optional) Settings screen

**State:** SettingsView showing version, privacy policy / support links.

### 9. (Optional) iMessage extension compose strip

**State:** iMessage extension in compact mode showing the recipient picker and message field.

### 10. (Optional) Splash screen with animated indicator

**State:** ContentView splash with the rotating arc + pulsing icon. Capture via screen recording, take a frame.

## Captions / overlays

App Store Connect supports plain screenshots. Most apps add caption text overlays via design tools (Figma, Sketch, ScreenshotMaker, Fastlane snapshot). For first submission, plain screenshots are fine — the listing description carries the messaging.

If you do add captions, keep them very short — 5-7 words each. Examples:

- Screenshot 1: "Your keys, your contacts."
- Screenshot 2: "Encrypt anything, share anywhere."
- Screenshot 3: "Native iMessage integration."
- Screenshot 4: "Verified senders, every time."
- Screenshot 5: "Trade keys in person."

## Workflow

1. Build the app from Xcode targeting the iPhone 16 Pro Max simulator.
2. Set up the data state (three recipients, etc.).
3. Take screenshot of home → save to Desktop.
4. Open Compose, set up encrypted state, screenshot.
5. Continue through the list.
6. In App Store Connect → My Apps → Exchange → App Store tab → Localization → English → Screenshots → drag in.
7. Repeat for any other device class you're targeting (or rely on auto-derivation).

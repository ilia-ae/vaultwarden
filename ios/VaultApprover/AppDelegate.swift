import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// In-app privacy channel (see `PrivacyChannel`) of the current implicit
  /// engine. The engine's own channel handlers keep it alive; this reference
  /// is only here so it can be detached when a newer engine replaces it.
  private var privacyChannel: PrivacyChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Called once per implicit engine (the storyboard's FlutterViewController
  /// creates it when the scene connects). App-level channels must be set up
  /// here rather than in `didFinishLaunching`: with UIScene there is no root
  /// FlutterViewController yet at launch.
  ///
  /// The app has a single scene (`UIApplicationSupportsMultipleScenes` is
  /// false), so a new engine means the scene was disconnected and reconnected
  /// and the previous engine is gone. Its Dart side never sends `cancel`, so
  /// the old channel is detached here to stop its observers.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    privacyChannel?.detach()
    privacyChannel = PrivacyChannel(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

// MARK: - Privacy channel

/// Native side of `lib/services/privacy_service.dart`.
///
/// Registered directly on the engine's messenger, not as a plugin, so it
/// needs no GeneratedPluginRegistrant sync.
///
/// Method channel `com.vaultapprover.app/privacy`:
/// - `copySensitive {text, ttlSeconds}`: writes to the general pasteboard with
///   `localOnly` (no Universal Clipboard) and a system `expirationDate`.
/// - `clearClipboardIfOurs` → Bool: empties the pasteboard if nothing was
///   copied since our last `copySensitive`, judged by `changeCount`. Reading
///   the contents would show the iOS paste prompt, so we never do.
/// - `clearClipboard` → Bool: empties the pasteboard unconditionally.
/// - `setSecureScreen {enabled}` → false: iOS cannot block screenshots.
/// - `isScreenCaptured` → Bool: recording, AirPlay or mirroring is active.
///
/// Event channel `com.vaultapprover.app/privacy/captured`: the capture state as
/// a Bool (the current state first, then changes) and the string `"screenshot"`
/// after the user takes a screenshot.
///
/// Main-actor isolated like the UIKit it drives. Flutter invokes channel
/// handlers on the main thread and every observer here uses the main queue;
/// `onMain` bridges those nonisolated callbacks without trapping if that ever
/// changes.
@MainActor
final class PrivacyChannel: NSObject, FlutterStreamHandler {
  static let methodChannelName = "com.vaultapprover.app/privacy"
  static let eventChannelName = "com.vaultapprover.app/privacy/captured"

  /// `UIPasteboard.general.changeCount` right after our last sensitive copy.
  /// Process-wide, like the pasteboard itself.
  private static var ownChangeCount: Int?

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel

  private var eventSink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  /// `UITraitChangeRegistration` for `sceneCaptureState` (iOS 17+).
  private var traitRegistration: AnyObject?
  private weak var traitScene: UIWindowScene?
  /// Last capture state sent, so repeated signals are not re-sent.
  private var lastCaptured: Bool?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: PrivacyChannel.methodChannelName, binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(
      name: PrivacyChannel.eventChannelName, binaryMessenger: messenger)
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      PrivacyChannel.onMain {
        guard let self else {
          result(FlutterMethodNotImplemented)
          return
        }
        self.handle(call, result: result)
      }
    }
    eventChannel.setStreamHandler(self)
  }

  /// Runs `body` on the main actor: inline on the main thread (the normal
  /// case), otherwise hops there instead of trapping in `assumeIsolated`.
  nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated(body)
    } else {
      // Handed to the main queue and never touched here again: a transfer,
      // not shared state. Swift 5 mode with strict concurrency needs this;
      // Swift 6 mode treats `@MainActor` closures as Sendable and flags it as
      // unnecessary, so drop it when migrating. Marking `body` @Sendable
      // instead adds warnings to every caller, even in the default build.
      nonisolated(unsafe) let body = body
      DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
  }

  /// Stops observing because the engine this channel belongs to is gone,
  /// together with the Dart side that would have sent `cancel`.
  func detach() {
    stopObserving()
  }

  // MARK: Methods

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "copySensitive":
      guard let text = args?["text"] as? String else {
        result(FlutterError(code: "bad_args", message: "text is required", details: nil))
        return
      }
      let ttl = (args?["ttlSeconds"] as? NSNumber)?.doubleValue ?? 60
      copySensitive(text, ttl: max(ttl, 1))
      result(true)
    case "clearClipboardIfOurs":
      result(clearClipboardIfOurs())
    case "clearClipboard":
      UIPasteboard.general.items = []
      PrivacyChannel.ownChangeCount = nil
      result(true)
    case "setSecureScreen":
      result(false)
    case "isScreenCaptured":
      result(currentCaptured())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func copySensitive(_ text: String, ttl: TimeInterval) {
    let pasteboard = UIPasteboard.general
    // utf8PlainText is what `UIPasteboard.string` (and Flutter's
    // Clipboard.setData) writes, so every paste target reads it.
    pasteboard.setItems(
      [[UTType.utf8PlainText.identifier: text]],
      options: [
        .localOnly: true,
        .expirationDate: Date().addingTimeInterval(ttl),
      ])
    PrivacyChannel.ownChangeCount = pasteboard.changeCount
  }

  private func clearClipboardIfOurs() -> Bool {
    let pasteboard = UIPasteboard.general
    guard let own = PrivacyChannel.ownChangeCount else { return false }
    PrivacyChannel.ownChangeCount = nil
    // Anything copied since (or the expiry itself) bumps changeCount.
    guard pasteboard.changeCount == own else { return false }
    pasteboard.items = []
    return true
  }

  // MARK: Capture state

  /// The scene showing Flutter; the app has a single window scene.
  private func windowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive }
      ?? scenes.first { $0.activationState == .foregroundInactive }
      ?? scenes.first
  }

  /// True while the screen is recorded, mirrored or AirPlayed. On iOS 17+ the
  /// scene's `sceneCaptureState` trait is also consulted (Apple's successor to
  /// `UIScreen.isCaptured`); either one reporting capture wins.
  private func currentCaptured() -> Bool {
    // No window scene means no Flutter UI on screen to capture.
    guard let scene = windowScene() else { return false }
    if #available(iOS 17.0, *), scene.traitCollection.sceneCaptureState == .active {
      return true
    }
    return scene.screen.isCaptured
  }

  private func emitCaptured(_ captured: Bool) {
    guard let sink = eventSink, captured != lastCaptured else { return }
    lastCaptured = captured
    sink(captured)
  }

  /// Re-reads the state; used by every trigger so they cannot disagree.
  private func refreshCaptured() {
    emitCaptured(currentCaptured())
  }

  private func observeSceneCaptureState() {
    guard #available(iOS 17.0, *), let scene = windowScene() else { return }
    if traitRegistration != nil, traitScene === scene { return }
    stopObservingSceneCaptureState()
    traitScene = scene
    traitRegistration = scene.registerForTraitChanges(
      [UITraitSceneCaptureState.self]
    ) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
      self?.refreshCaptured()
    }
  }

  private func stopObservingSceneCaptureState() {
    if #available(iOS 17.0, *),
      let scene = traitScene,
      let registration = traitRegistration as? UITraitChangeRegistration
    {
      scene.unregisterForTraitChanges(registration)
    }
    traitRegistration = nil
    traitScene = nil
  }

  // MARK: FlutterStreamHandler

  nonisolated func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    PrivacyChannel.onMain { self.startObserving(events) }
    return nil
  }

  nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
    PrivacyChannel.onMain { self.stopObserving() }
    return nil
  }

  private func startObserving(_ events: @escaping FlutterEventSink) {
    stopObserving()
    eventSink = events
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        PrivacyChannel.onMain { self?.refreshCaptured() }
      },
      center.addObserver(
        forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main
      ) { [weak self] _ in
        PrivacyChannel.onMain { self?.eventSink?("screenshot") }
      },
      // Capture may have started or stopped while inactive (e.g. from Control
      // Centre), and the scene object may be new: re-check and re-attach.
      center.addObserver(
        forName: UIScene.didActivateNotification, object: nil, queue: .main
      ) { [weak self] _ in
        PrivacyChannel.onMain {
          self?.observeSceneCaptureState()
          self?.refreshCaptured()
        }
      },
    ]
    observeSceneCaptureState()
    refreshCaptured()
  }

  private func stopObserving() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers = []
    stopObservingSceneCaptureState()
    eventSink = nil
    lastCaptured = nil
  }
}

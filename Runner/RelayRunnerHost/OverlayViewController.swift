import AuthenticationServices
import CoreLocation
import PhotosUI
import SafariServices
import UIKit
import UserNotifications

/// Screen for checking how relay behaves while another process draws over the app: permission alerts
/// (SpringBoard), the share sheet and the photo picker (out-of-process view services), notification
/// banners, and an in-app alert to compare with. `relay.overlay` on the input screen opens it.
///
/// Accessibility identifiers:
/// - `relay.overlay.close`: back to the input screen
/// - `relay.askLocation` / `relay.askNotifications`: ask for that permission 2 seconds after the tap,
///   so a relay command can be sent before the alert appears
/// - `relay.notifyLater`: schedules a local notification 3 seconds after the tap, shown as a banner
///   even while this app is in front
/// - `relay.share` (UIActivityViewController), `relay.photos` (PHPickerViewController),
///   `relay.inAppAlert` (UIAlertController, drawn by this app)
/// - `relay.safari` / `relay.safariSheet`: `SFSafariViewController` on https://example.com, full screen (its
///   default) or as a page sheet with this screen visible behind it; `relay.webAuth`: an
///   `ASWebAuthenticationSession` on the same page, ephemeral (no sign-in prompt); `relay.webAuthShared`: the
///   same with the shared browser session, which first asks to use the site to sign in
/// - `relay.overlay.status`: permission results and the latest events
/// - `relay.shiftRows`: moves the `relay.behind*` rows down by half a row, or back, so that a row's
///   center can be put on a given alert button
/// - `relay.behind1` … `relay.behind8`: full-width buttons filling the middle and bottom of the screen,
///   where alerts appear, each showing how many times it was tapped (`behind3: 2`), so a tap that
///   reached the app behind an alert is visible afterwards. Their value is empty, and becomes `late`
///   3 seconds after `relay.askLocation` or `relay.askNotifications` (1 second after the alert is
///   asked for): `relay tap --id relay.behind3 --value late --timeout 5` sent right after the ask
///   picks its app before the alert and finds the element only after it
final class OverlayViewController: UIViewController, CLLocationManagerDelegate, PHPickerViewControllerDelegate,
  UNUserNotificationCenterDelegate, SFSafariViewControllerDelegate, ASWebAuthenticationPresentationContextProviding {
  private static let webURL = URL(string: "https://example.com")!

  private static let rowCount = 8

  private let locationManager = CLLocationManager()
  private var webAuthSession: ASWebAuthenticationSession?
  private let statusLabel = UILabel()
  private var behindButtons: [UIButton] = []
  private let grid = UIStackView()
  private var behindCounts: [Int]
  private var events: [String] = []

  init() {
    behindCounts = Array(repeating: 0, count: Self.rowCount)
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    locationManager.delegate = self
    UNUserNotificationCenter.current().delegate = self

    let actions = UIStackView(arrangedSubviews: [
      row(button("relay.overlay.close", "Close", #selector(close)),
          button("relay.inAppAlert", "In-app alert", #selector(showInAppAlert)),
          button("relay.shiftRows", "Shift rows", #selector(shiftRows))),
      row(button("relay.askLocation", "Location in 2s", #selector(askLocation)),
          button("relay.askNotifications", "Notify perm in 2s", #selector(askNotifications)),
          button("relay.webAuthShared", "Web auth shared", #selector(startSharedWebAuth))),
      row(button("relay.share", "Share", #selector(share)),
          button("relay.photos", "Photos", #selector(pickPhotos)),
          button("relay.notifyLater", "Banner in 3s", #selector(notifyLater))),
      row(button("relay.safari", "Safari", #selector(showSafari)),
          button("relay.safariSheet", "Safari sheet", #selector(showSafariSheet)),
          button("relay.webAuth", "Web auth", #selector(startWebAuth)))
    ])
    actions.axis = .vertical
    actions.spacing = 6

    statusLabel.accessibilityIdentifier = "relay.overlay.status"
    statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    statusLabel.numberOfLines = 4
    statusLabel.adjustsFontSizeToFitWidth = true
    statusLabel.minimumScaleFactor = 0.7

    for index in 0 ..< Self.rowCount {
      let behind = UIButton(type: .system)
      behind.accessibilityIdentifier = "relay.behind\(index + 1)"
      behind.backgroundColor = index.isMultiple(of: 2) ? .systemGray5 : .systemGray4
      behind.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
      behind.tag = index
      behind.addTarget(self, action: #selector(behindTapped(_:)), for: .touchUpInside)
      behindButtons.append(behind)
    }
    behindButtons.forEach(grid.addArrangedSubview)
    grid.axis = .vertical
    grid.distribution = .fillEqually
    grid.spacing = 2

    let stack = UIStackView(arrangedSubviews: [actions, statusLabel, grid])
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4)
    ])
    updateTitles()
    record("ready")
  }

  private func button(_ identifier: String, _ title: String, _ action: Selector) -> UIButton {
    let button = UIButton(configuration: .bordered())
    button.configuration?.title = title
    button.configuration?.buttonSize = .small
    button.accessibilityIdentifier = identifier
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func row(_ buttons: UIButton...) -> UIStackView {
    let row = UIStackView(arrangedSubviews: buttons)
    row.distribution = .fillEqually
    row.spacing = 6
    return row
  }

  private func updateTitles() {
    for (index, button) in behindButtons.enumerated() {
      button.setTitle("behind\(index + 1): \(behindCounts[index])", for: .normal)
    }
  }

  /// Keeps the newest events first, with the permission states on the first line.
  private func record(_ event: String) {
    events.insert(event, at: 0)
    events = Array(events.prefix(3))
    let location = Self.name(of: locationManager.authorizationStatus)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let notifications = Self.name(of: settings.authorizationStatus)
      DispatchQueue.main.async {
        self.statusLabel.text = "location: \(location), notifications: \(notifications)\n"
          + self.events.joined(separator: "\n")
      }
    }
  }

  @objc private func behindTapped(_ sender: UIButton) {
    behindCounts[sender.tag] += 1
    updateTitles()
    record("behind\(sender.tag + 1) #\(behindCounts[sender.tag])")
  }

  @objc private func shiftRows() {
    let offset = grid.transform.isIdentity ? grid.bounds.height / CGFloat(Self.rowCount) / 2 : 0
    grid.transform = CGAffineTransform(translationX: 0, y: offset)
    record("rows shifted by \(Int(offset.rounded()))")
  }

  @objc private func close() {
    dismiss(animated: false)
  }

  @objc private func askLocation() {
    record("location asked; alert in 2s")
    markBehindButtonsLate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      self.locationManager.requestWhenInUseAuthorization()
    }
  }

  @objc private func askNotifications() {
    record("notifications asked; alert in 2s")
    markBehindButtonsLate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        DispatchQueue.main.async { self.record("notifications granted: \(granted)") }
      }
    }
  }

  /// Clears the value of the buttons behind the alert, and sets it to `late` 3 seconds later.
  private func markBehindButtonsLate() {
    behindButtons.forEach { $0.accessibilityValue = nil }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      self.behindButtons.forEach { $0.accessibilityValue = "late" }
    }
  }

  @objc private func notifyLater() {
    let content = UNMutableNotificationContent()
    content.title = "relay banner"
    content.body = "Local notification for relay"
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
    let request = UNNotificationRequest(identifier: "relay.banner", content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async { self.record(error.map { "banner failed: \($0.localizedDescription)" } ?? "banner in 3s") }
    }
  }

  @objc private func share(_ sender: UIButton) {
    let controller = UIActivityViewController(activityItems: ["relay share"], applicationActivities: nil)
    controller.popoverPresentationController?.sourceView = sender
    controller.completionWithItemsHandler = { activity, completed, _, _ in
      self.record("share done: \(activity?.rawValue ?? "none") \(completed)")
    }
    present(controller, animated: true)
    record("share shown")
  }

  @objc private func pickPhotos() {
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    present(picker, animated: true)
    record("photos shown")
  }

  @objc private func showSafari() {
    presentSafari(style: .fullScreen)
  }

  @objc private func showSafariSheet() {
    presentSafari(style: .pageSheet)
  }

  private func presentSafari(style: UIModalPresentationStyle) {
    let safari = SFSafariViewController(url: Self.webURL)
    safari.modalPresentationStyle = style
    safari.delegate = self
    present(safari, animated: true)
    record(style == .pageSheet ? "safari sheet shown" : "safari shown")
  }

  func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    record("safari done")
  }

  @objc private func startWebAuth() {
    beginWebAuth(ephemeral: true)
  }

  @objc private func startSharedWebAuth() {
    beginWebAuth(ephemeral: false)
  }

  private func beginWebAuth(ephemeral: Bool) {
    let session = ASWebAuthenticationSession(url: Self.webURL, callbackURLScheme: "relayrunner") { callbackURL, error in
      DispatchQueue.main.async {
        self.record(callbackURL.map { "web auth callback \($0)" } ?? "web auth ended: \(error.map { ($0 as NSError).code } ?? 0)")
        self.webAuthSession = nil
      }
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = ephemeral
    webAuthSession = session
    record(session.start() ? "web auth started" : "web auth failed to start")
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    view.window ?? ASPresentationAnchor()
  }

  @objc private func showInAppAlert() {
    let alert = UIAlertController(title: "relay in-app alert", message: "Drawn by this app", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.record("in-app alert OK") })
    present(alert, animated: true)
    record("in-app alert shown")
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    record("location changed")
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    record("photos picked: \(results.count)")
  }

  /// Shows the banner even while this app is in front, so it covers the app.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
    DispatchQueue.main.async { self.record("banner presented") }
  }

  private static func name(of status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "whenInUse"
    @unknown default: return "unknown"
    }
  }

  private static func name(of status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    @unknown default: return "unknown"
    }
  }
}

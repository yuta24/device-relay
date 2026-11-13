import UIKit

/// Host app required by the UI test bundle. The runner never launches it, but `/launch` can bring it
/// to the front: it shows text fields to try `/type` and `/key` on a device without touching other apps.
///
/// It uses the scene lifecycle: on iOS 27 an app without it traps at launch.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = InputViewController()
    window.makeKeyAndVisible()
    self.window = window
  }
}

/// Text fields and labels that echo what reached them.
///
/// Accessibility identifiers: `relay.input` and `relay.input2` (the fields; the second one has no Select
/// All), `relay.password` (a
/// secure field), `relay.text` (the current text of `relay.input`), `relay.passwordLength` (only the
/// number of characters in `relay.password`, never the text), `relay.submitted` (the text when Return
/// was pressed, with a count), and `relay.events` (the latest edits and hardware key presses, newest
/// first; edits to the password field show only their length). `relay.overlay` opens
/// `OverlayViewController`, the screen for checking alerts and sheets drawn by other processes.
/// `relay.notes` is a multi-line text view, to try `relay type --clear` on more than one line.
/// `relay.showToast` shows the label `relay.toast` and takes it out of the view hierarchy 1.5 seconds later,
/// something to wait for to go (`relay find --gone`).
final class InputViewController: UIViewController, UITextFieldDelegate {
  private let input = KeyRecordingTextField()
  private let secondInput = NoSelectAllTextField()
  private let passwordInput = KeyRecordingTextField()
  private let notes = UITextView()
  private let textLabel = UILabel()
  private let passwordLengthLabel = UILabel()
  private let submittedLabel = UILabel()
  private let eventsLabel = UILabel()
  private var submitCount = 0
  private var events: [String] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    configure(input, identifier: "relay.input", placeholder: "Type here")
    configure(secondInput, identifier: "relay.input2", placeholder: "Second field")
    configure(passwordInput, identifier: "relay.password", placeholder: "Password")
    passwordInput.isSecureTextEntry = true
    configure(textLabel, identifier: "relay.text", text: "text: ")
    configure(passwordLengthLabel, identifier: "relay.passwordLength", text: "password: 0 chars")
    configure(submittedLabel, identifier: "relay.submitted", text: "submitted: (none)")
    configure(eventsLabel, identifier: "relay.events", text: "events: ")
    eventsLabel.numberOfLines = 0
    input.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    passwordInput.addTarget(self, action: #selector(passwordChanged), for: .editingChanged)
    notes.accessibilityIdentifier = "relay.notes"
    notes.font = .preferredFont(forTextStyle: .body)
    notes.autocorrectionType = .no
    notes.autocapitalizationType = .none
    notes.spellCheckingType = .no
    notes.layer.borderColor = UIColor.separator.cgColor
    notes.layer.borderWidth = 1
    notes.layer.cornerRadius = 5
    notes.heightAnchor.constraint(equalToConstant: 72).isActive = true

    let overlayButton = UIButton(configuration: .bordered())
    overlayButton.configuration?.title = "Overlay checks"
    overlayButton.accessibilityIdentifier = "relay.overlay"
    overlayButton.addTarget(self, action: #selector(openOverlay), for: .touchUpInside)

    let toastButton = UIButton(configuration: .bordered())
    toastButton.configuration?.title = "Show toast"
    toastButton.accessibilityIdentifier = "relay.showToast"
    toastButton.addTarget(self, action: #selector(showToast), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [
      input, secondInput, passwordInput, notes, textLabel, passwordLengthLabel, submittedLabel, eventsLabel, overlayButton, toastButton
    ])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
    ])
  }

  private func configure(_ field: KeyRecordingTextField, identifier: String, placeholder: String) {
    field.accessibilityIdentifier = identifier
    field.placeholder = placeholder
    field.borderStyle = .roundedRect
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.returnKeyType = .done
    field.delegate = self
    // A secure field's key presses are logged without the key, so the label never shows the password.
    field.onKeyPress = { [weak self, weak field] name in
      self?.record(field?.isSecureTextEntry == true ? "\(identifier) press" : "\(identifier) press \(name)")
    }
  }

  private func configure(_ label: UILabel, identifier: String, text: String) {
    label.accessibilityIdentifier = identifier
    label.text = text
    label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
  }

  @objc private func openOverlay() {
    present(OverlayViewController(), animated: false)
  }

  /// A label at the bottom of the screen, removed from the view hierarchy (not hidden) after `toastDuration`.
  @objc private func showToast() {
    let toast = UILabel()
    toast.text = "toast"
    toast.accessibilityIdentifier = "relay.toast"
    toast.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(toast)
    NSLayoutConstraint.activate([
      toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
    ])
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration) { toast.removeFromSuperview() }
  }

  private static let toastDuration: TimeInterval = 1.5

  @objc private func textChanged() {
    textLabel.text = "text: \(input.text ?? "")"
  }

  @objc private func passwordChanged() {
    passwordLengthLabel.text = "password: \(passwordInput.text?.count ?? 0) chars"
  }

  private func record(_ event: String) {
    events.insert(event, at: 0)
    events = Array(events.prefix(6))
    eventsLabel.text = "events: " + events.joined(separator: "\n")
  }

  func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
    let name = textField.accessibilityIdentifier ?? "field"
    if string.isEmpty {
      record("\(name) delete \(range.length)")
    } else if textField.isSecureTextEntry {
      record("\(name) insert \(string.count) chars")
    } else {
      record("\(name) insert \(string.debugDescription)")
    }
    return true
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === input {
      submitCount += 1
      submittedLabel.text = "submitted #\(submitCount): \(input.text ?? "")"
    }
    record("\(textField.accessibilityIdentifier ?? "field") return")
    return false
  }
}

/// Reports hardware key presses (`UIPress`), so keys sent as key events can be told apart from text.
class KeyRecordingTextField: UITextField {
  var onKeyPress: ((String) -> Void)?

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses {
      guard let key = press.key else { continue }
      onKeyPress?(Self.name(of: key))
    }
    super.pressesBegan(presses, with: event)
  }

  private static func name(of key: UIKey) -> String {
    switch key.keyCode {
    case .keyboardReturnOrEnter: return "Return"
    case .keyboardDeleteOrBackspace: return "Backspace"
    case .keyboardTab: return "Tab"
    case .keyboardEscape: return "Escape"
    case .keyboardSpacebar: return "Space"
    default: return key.characters.isEmpty ? "keyCode \(key.keyCode.rawValue)" : key.characters.debugDescription
    }
  }
}

/// A field without Select All (command-A does nothing), as some apps make theirs: `relay type --clear` falls
/// back to deletes from the end there.
final class NoSelectAllTextField: KeyRecordingTextField {
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    action == #selector(selectAll(_:)) ? false : super.canPerformAction(action, withSender: sender)
  }
}

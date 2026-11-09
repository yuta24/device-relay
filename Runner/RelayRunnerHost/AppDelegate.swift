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
/// Accessibility identifiers: `relay.input` and `relay.input2` (the fields), `relay.password` (a
/// secure field), `relay.text` (the current text of `relay.input`), `relay.passwordLength` (only the
/// number of characters in `relay.password`, never the text), `relay.submitted` (the text when Return
/// was pressed, with a count), and `relay.events` (the latest edits and hardware key presses, newest
/// first; edits to the password field show only their length). `relay.overlay` opens
/// `OverlayViewController`, the screen for checking alerts and sheets drawn by other processes.
final class InputViewController: UIViewController, UITextFieldDelegate {
  private let input = KeyRecordingTextField()
  private let secondInput = KeyRecordingTextField()
  private let passwordInput = KeyRecordingTextField()
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

    let overlayButton = UIButton(configuration: .bordered())
    overlayButton.configuration?.title = "Overlay checks"
    overlayButton.accessibilityIdentifier = "relay.overlay"
    overlayButton.addTarget(self, action: #selector(openOverlay), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [
      input, secondInput, passwordInput, textLabel, passwordLengthLabel, submittedLabel, eventsLabel, overlayButton
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
final class KeyRecordingTextField: UITextField {
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

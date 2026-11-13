import UIKit

/// Screen for checking gestures beyond a single tap. `relay.gestures` on the input screen opens it.
///
/// Accessibility identifiers:
/// - `relay.gestures.close`: back to the input screen
/// - `relay.tapTarget`: a view with a single-tap and a double-tap recognizer (`numberOfTapsRequired` 1 and 2;
///   the single one waits for the double one to fail), so a double tap is told apart from two taps
/// - `relay.tapCounts`: how many times each recognizer fired (`single: 2, double: 1`)
/// - `relay.tapReset`: sets both counts back to 0
final class GestureViewController: UIViewController {
  private let tapCountsLabel = UILabel()
  private var singleTaps = 0
  private var doubleTaps = 0

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let tapTarget = UILabel()
    tapTarget.text = "Tap or double-tap"
    tapTarget.textAlignment = .center
    tapTarget.backgroundColor = .secondarySystemBackground
    tapTarget.isUserInteractionEnabled = true
    tapTarget.isAccessibilityElement = true
    tapTarget.accessibilityIdentifier = "relay.tapTarget"
    tapTarget.accessibilityTraits = .button
    tapTarget.heightAnchor.constraint(equalToConstant: 120).isActive = true
    let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
    double.numberOfTapsRequired = 2
    let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
    single.require(toFail: double)
    tapTarget.addGestureRecognizer(double)
    tapTarget.addGestureRecognizer(single)

    tapCountsLabel.accessibilityIdentifier = "relay.tapCounts"
    tapCountsLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    updateTapCounts()

    let stack = UIStackView(arrangedSubviews: [
      row(button("relay.gestures.close", "Close", #selector(close)), button("relay.tapReset", "Reset taps", #selector(resetTaps))),
      tapTarget,
      tapCountsLabel
    ])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
    ])
  }

  private func button(_ identifier: String, _ title: String, _ action: Selector) -> UIButton {
    let button = UIButton(configuration: .bordered())
    button.configuration?.title = title
    button.accessibilityIdentifier = identifier
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func row(_ views: UIView...) -> UIStackView {
    let row = UIStackView(arrangedSubviews: views)
    row.axis = .horizontal
    row.spacing = 8
    row.distribution = .fillEqually
    return row
  }

  @objc private func close() {
    dismiss(animated: false)
  }

  @objc private func singleTapped() {
    singleTaps += 1
    updateTapCounts()
  }

  @objc private func doubleTapped() {
    doubleTaps += 1
    updateTapCounts()
  }

  @objc private func resetTaps() {
    singleTaps = 0
    doubleTaps = 0
    updateTapCounts()
  }

  private func updateTapCounts() {
    tapCountsLabel.text = "single: \(singleTaps), double: \(doubleTaps)"
  }
}

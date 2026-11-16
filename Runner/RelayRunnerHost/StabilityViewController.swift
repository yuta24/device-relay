import UIKit

/// Deterministic screen changes for `wait --stable`; no network, permissions, or personal data.
final class StabilityViewController: UIViewController {
  private let square = UIView()
  private let status = UILabel()
  private let spinner = UIActivityIndicatorView(style: .large)

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Stability"
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Close", style: .plain, target: self, action: #selector(close))
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
    ])
    for (name, selector) in [("animate", #selector(animate)), ("load", #selector(load)), ("spin", #selector(spin)),
                             ("stop", #selector(stop)), ("push", #selector(push)), ("modal", #selector(modal))] {
      let button = UIButton(type: .system)
      button.setTitle(name, for: .normal)
      button.accessibilityIdentifier = "relay.stable.\(name)"
      button.addTarget(self, action: selector, for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    status.text = "Ready"
    status.accessibilityIdentifier = "relay.stable.status"
    stack.addArrangedSubview(status)
    stack.addArrangedSubview(spinner)
    square.backgroundColor = .systemOrange
    square.frame = CGRect(x: 30, y: 620, width: 60, height: 60)
    // Drawing changes without an accessibility element: tree-only comparison cannot see this.
    square.isAccessibilityElement = false
    square.accessibilityElementsHidden = true
    view.addSubview(square)
  }

  @objc private func animate() {
    square.layer.removeAllAnimations()
    square.transform = .identity
    UIView.animate(withDuration: 1.8, delay: 0, options: [.curveLinear]) {
      self.square.transform = CGAffineTransform(translationX: 220, y: 0)
    }
  }

  @objc private func load() {
    status.text = "Loading"
    spinner.startAnimating()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.spinner.stopAnimating()
      self?.status.text = "Loaded"
    }
  }

  @objc private func spin() { spinner.startAnimating() }
  @objc private func stop() { spinner.stopAnimating() }
  @objc private func push() { navigationController?.pushViewController(StabilityViewController(), animated: true) }
  @objc private func modal() { present(UINavigationController(rootViewController: StabilityViewController()), animated: true) }
  @objc private func close() { dismiss(animated: true) }
}

import UIKit

/// Two-contact pinch readback, opened by relay.pinch on the gesture checks screen.
final class PinchViewController: UIViewController {
  private let status = UILabel()
  private let canvas = UIView()
  private var count = 0
  private var maxTouches = 0
  private var beginDistance: CGFloat = 0
  private var lastDistance: CGFloat = 0
  private var beginCenter = CGPoint.zero
  private var lastScale: CGFloat = 1

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError("unused") }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.accessibilityIdentifier = "relay.pinch.status"
    status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    status.numberOfLines = 0
    status.text = "pinch: none"
    canvas.backgroundColor = .secondarySystemBackground
    canvas.isAccessibilityElement = true
    canvas.accessibilityIdentifier = "relay.pinch.canvas"
    canvas.accessibilityLabel = "Pinch canvas"
    canvas.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    let close = UIButton(configuration: .bordered())
    close.configuration?.title = "Close"
    close.accessibilityIdentifier = "relay.pinch.close"
    close.addTarget(self, action: #selector(closeProbe), for: .touchUpInside)
    for child in [status, canvas, close] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      status.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 4),
      status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      status.heightAnchor.constraint(equalToConstant: 70),
      canvas.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
      canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      canvas.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
    ])
  }
  @objc private func closeProbe() { dismiss(animated: false) }
  @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
    if gesture.state == .began {
      count += 1
      maxTouches = 0
      beginDistance = 0
      lastDistance = 0
      beginCenter = gesture.location(in: view)
    }
    maxTouches = max(maxTouches, gesture.numberOfTouches)
    if gesture.numberOfTouches == 2 {
      let a = gesture.location(ofTouch: 0, in: view), b = gesture.location(ofTouch: 1, in: view)
      lastDistance = hypot(a.x - b.x, a.y - b.y)
      if beginDistance == 0 { beginDistance = lastDistance }
    }
    lastScale = gesture.scale
    status.text = String(format: "count:%d state:%d scale:%.4f touches:%d\nbegin:%.2f last:%.2f center:%.1f,%.1f",
                         count, gesture.state.rawValue, lastScale, maxTouches, beginDistance, lastDistance, beginCenter.x, beginCenter.y)
  }
}

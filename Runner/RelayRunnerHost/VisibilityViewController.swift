import UIKit

/// Screen for checking which elements are on the screen and which a touch reaches (`relay find --onscreen` and
/// `--hittable`). `relay.visibility` on the input screen opens it.
///
/// Accessibility identifiers:
/// - `relay.visibility.close`: back to the input screen
/// - `relay.openPlayer`: shows `PlayerViewController` over this screen as a child view controller whose view covers
///   it, as players that aren't presented do, so this screen stays in the element tree under the player
/// - `relay.presentPlayer`: presents the same player (`.overFullScreen`). UIKit then leaves this screen out of the
///   element tree, so nothing under the player matches
/// - `relay.play` (a button labeled `Play`) and `relay.nowPlaying` (a text labeled `Now playing`): the labels the player
///   also has
/// - `relay.playCount`: how many times each `Play` was tapped (`play: 1, player: 2`)
/// - `relay.pages`: a paging scroll view of three pages, each with the text `Page title` (`relay.page1.title`, ...) and
///   a button labeled `Select` (`relay.page1.select`, ...); only the first page is on the screen at first
/// - `relay.pageStatus`: the page whose `Select` was tapped last (`selected: page 1`)
/// - `relay.item1` ... `relay.item100`: a grid of texts labeled `Item`, many elements for timing a hit test of each
final class VisibilityViewController: UIViewController {
  private let playCountLabel = UILabel()
  private let pageStatusLabel = UILabel()
  private var plays = 0
  private var playerPlays = 0

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let nowPlaying = UILabel()
    nowPlaying.text = "Now playing"
    nowPlaying.accessibilityIdentifier = "relay.nowPlaying"
    configure(playCountLabel, identifier: "relay.playCount")
    updatePlayCount()
    configure(pageStatusLabel, identifier: "relay.pageStatus")
    pageStatusLabel.text = "selected: (none)"

    let stack = UIStackView(arrangedSubviews: [
      row(button("relay.visibility.close", "Close", #selector(close)), button("relay.openPlayer", "Open player", #selector(openPlayer)),
          button("relay.presentPlayer", "Present", #selector(presentPlayer))),
      nowPlaying,
      button("relay.play", "Play", #selector(play)),
      playCountLabel,
      pages(),
      pageStatusLabel,
      grid()
    ])
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
    ])
  }

  /// Three pages as wide as the scroll view, side by side; the scroll view shows one at a time.
  private func pages() -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.accessibilityIdentifier = "relay.pages"
    scrollView.isPagingEnabled = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.backgroundColor = .secondarySystemBackground
    scrollView.heightAnchor.constraint(equalToConstant: 100).isActive = true
    let content = UIStackView()
    content.axis = .horizontal
    content.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      content.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
    ])
    for number in 1 ... 3 {
      let title = UILabel()
      title.text = "Page title"
      title.accessibilityIdentifier = "relay.page\(number).title"
      let select = button("relay.page\(number).select", "Select", #selector(selectPage(_:)))
      select.tag = number
      let page = UIStackView(arrangedSubviews: [title, select])
      page.axis = .vertical
      page.alignment = .center
      page.spacing = 8
      page.isLayoutMarginsRelativeArrangement = true
      page.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
      content.addArrangedSubview(page)
      page.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
    }
    return scrollView
  }

  /// Ten rows of ten texts labeled `Item`.
  private func grid() -> UIStackView {
    let rows = (0 ..< 10).map { row -> UIView in
      let labels = (1 ... 10).map { column -> UILabel in
        let label = UILabel()
        label.text = "Item"
        label.font = .systemFont(ofSize: 11)
        label.textAlignment = .center
        label.accessibilityIdentifier = "relay.item\(row * 10 + column)"
        return label
      }
      let stack = UIStackView(arrangedSubviews: labels)
      stack.distribution = .fillEqually
      return stack
    }
    let grid = UIStackView(arrangedSubviews: rows)
    grid.axis = .vertical
    grid.spacing = 4
    return grid
  }

  @objc private func close() {
    dismiss(animated: false)
  }

  @objc private func openPlayer() {
    let player = makePlayer()
    addChild(player)
    player.view.frame = view.bounds
    player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(player.view)
    player.didMove(toParent: self)
  }

  @objc private func presentPlayer() {
    present(makePlayer(), animated: false)
  }

  private func makePlayer() -> PlayerViewController {
    let player = PlayerViewController()
    player.onPlay = { [weak self] in
      self?.playerPlays += 1
      self?.updatePlayCount()
      return self?.playCountLabel.text ?? ""
    }
    player.playCount = playCountLabel.text ?? ""
    return player
  }

  @objc private func play() {
    plays += 1
    updatePlayCount()
  }

  @objc private func selectPage(_ sender: UIButton) {
    pageStatusLabel.text = "selected: page \(sender.tag)"
  }

  private func updatePlayCount() {
    playCountLabel.text = "play: \(plays), player: \(playerPlays)"
  }

  private func configure(_ label: UILabel, identifier: String) {
    label.accessibilityIdentifier = identifier
    label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
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
    return row
  }
}

/// An opaque player over `VisibilityViewController`, with the same labels as that screen: the button `Play`
/// (`relay.player.play`), first, so it covers the screen's `Now playing`, and the text `Now playing`
/// (`relay.player.nowPlaying`) below it. `relay.player.close` closes it, and `relay.player.playCount` shows the
/// count of both `Play` buttons.
final class PlayerViewController: UIViewController {
  /// Counts a tap of the player's `Play` and returns the new count text.
  var onPlay: (() -> String)?
  var playCount = ""
  private let playCountLabel = UILabel()

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let close = UIButton(configuration: .bordered())
    close.configuration?.title = "Close"
    close.accessibilityIdentifier = "relay.player.close"
    close.addTarget(self, action: #selector(closePlayer), for: .touchUpInside)
    let play = UIButton(configuration: .filled())
    play.configuration?.title = "Play"
    play.accessibilityIdentifier = "relay.player.play"
    play.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
    let nowPlaying = UILabel()
    nowPlaying.text = "Now playing"
    nowPlaying.accessibilityIdentifier = "relay.player.nowPlaying"
    playCountLabel.accessibilityIdentifier = "relay.player.playCount"
    playCountLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    playCountLabel.text = playCount

    let row = UIStackView(arrangedSubviews: [close])
    row.axis = .horizontal
    let stack = UIStackView(arrangedSubviews: [row, play, nowPlaying, playCountLabel])
    stack.axis = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
    ])
  }

  @objc private func closePlayer() {
    guard parent != nil else { return dismiss(animated: false) }
    willMove(toParent: nil)
    view.removeFromSuperview()
    removeFromParent()
  }

  @objc private func playTapped() {
    playCountLabel.text = onPlay?() ?? playCountLabel.text
  }
}

import UIKit

/// Virtualized vertical and horizontal lists for --scroll, with separate container identifiers.
final class ScrollViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
  UICollectionViewDataSource, UICollectionViewDelegate {
  private let table = UITableView()
  private let status = UILabel()
  private let horizontal: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.itemSize = CGSize(width: 120, height: 80)
    layout.minimumLineSpacing = 8
    return UICollectionView(frame: .zero, collectionViewLayout: layout)
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let close = UIButton(type: .system)
    close.setTitle("Close scroll checks", for: .normal)
    close.accessibilityIdentifier = "relay.scroll.close"
    close.addTarget(self, action: #selector(dismissChecks), for: .touchUpInside)
    status.text = "selected: none"
    status.accessibilityIdentifier = "relay.scroll.status"
    table.accessibilityIdentifier = "relay.scroll.vertical"
    table.rowHeight = 44
    table.dataSource = self
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    horizontal.accessibilityIdentifier = "relay.scroll.horizontal"
    horizontal.dataSource = self
    horizontal.delegate = self
    horizontal.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "tile")
    for item in [close, status, table, horizontal] {
      item.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(item)
    }
    NSLayoutConstraint.activate([
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      close.heightAnchor.constraint(equalToConstant: 36),
      status.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 8),
      status.leadingAnchor.constraint(equalTo: close.leadingAnchor),
      status.heightAnchor.constraint(equalToConstant: 22),
      table.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      table.bottomAnchor.constraint(equalTo: horizontal.topAnchor, constant: -12),
      horizontal.leadingAnchor.constraint(equalTo: table.leadingAnchor),
      horizontal.trailingAnchor.constraint(equalTo: table.trailingAnchor),
      horizontal.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
      horizontal.heightAnchor.constraint(equalToConstant: 100)
    ])
  }

  @objc private func dismissChecks() { dismiss(animated: false) }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 100 }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.textLabel?.text = "Row \(indexPath.row + 1)"
    cell.accessibilityIdentifier = "relay.scroll.row\(indexPath.row + 1)"
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    status.text = "selected: row \(indexPath.row + 1)"
  }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 40 }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tile", for: indexPath)
    cell.backgroundColor = .systemTeal
    cell.isAccessibilityElement = true
    cell.accessibilityIdentifier = "relay.scroll.tile\(indexPath.item + 1)"
    cell.accessibilityLabel = "Tile \(indexPath.item + 1)"
    return cell
  }
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    status.text = "selected: tile \(indexPath.item + 1)"
  }
}

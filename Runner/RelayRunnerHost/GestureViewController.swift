import UIKit

/// Screen for checking gestures beyond a single tap. `relay.gestures` on the input screen opens it.
///
/// Accessibility identifiers:
/// - `relay.gestures.close`: back to the input screen
/// - `relay.tapTarget`: a view with a single-tap and a double-tap recognizer (`numberOfTapsRequired` 1 and 2;
///   the single one waits for the double one to fail), so a double tap is told apart from two taps
/// - `relay.tapCounts`: how many times each recognizer fired (`single: 2, double: 1`)
/// - `relay.tapReset`: sets both counts back to 0
/// - `relay.animate`: starts or stops fading this button in and out without end (a repeating UIView animation), so
///   the app is never idle for XCUI while it runs; its label says which (`Animate: on`)
/// - `relay.slider` (continuous, 0...1, starts at 0.3) and `relay.steppedSlider` (snaps to 0, 0.25, 0.5, 0.75,
///   1), with their values in `relay.sliderValue` (`slider: 0.30, stepped: 0.50`)
/// - `relay.datePicker`: a date picker in wheels style (en_US, UTC, starts at 2026-06-15), with its date in
///   `relay.dateValue` (`date: 2026-06-15`)
/// - `relay.picker`: a picker view with two wheels, fruits and the numbers 1 to 20, with its rows in
///   `relay.pickerValue` (`picker: Banana, 3`)
final class GestureViewController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {
  private static let fruits = ["Apple", "Banana", "Cherry", "Durian", "Elderberry", "Fig", "Grape", "Honeydew"]
  private static let numbers = (1 ... 20).map(String.init)

  private let tapCountsLabel = UILabel()
  private var singleTaps = 0
  private var doubleTaps = 0
  private let slider = UISlider()
  private let steppedSlider = UISlider()
  private let sliderValueLabel = UILabel()
  private let datePicker = UIDatePicker()
  private let dateValueLabel = UILabel()
  private let picker = UIPickerView()
  private let pickerValueLabel = UILabel()
  private let animateButton = UIButton(configuration: .bordered())

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
    tapTarget.heightAnchor.constraint(equalToConstant: 64).isActive = true
    let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
    double.numberOfTapsRequired = 2
    let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
    single.require(toFail: double)
    tapTarget.addGestureRecognizer(double)
    tapTarget.addGestureRecognizer(single)

    configure(tapCountsLabel, identifier: "relay.tapCounts")
    updateTapCounts()

    slider.accessibilityIdentifier = "relay.slider"
    slider.value = 0.3
    slider.addTarget(self, action: #selector(slidersChanged), for: .valueChanged)
    steppedSlider.accessibilityIdentifier = "relay.steppedSlider"
    steppedSlider.value = 0.5
    steppedSlider.addTarget(self, action: #selector(slidersChanged), for: .valueChanged)
    configure(sliderValueLabel, identifier: "relay.sliderValue")
    updateSliderValue()

    datePicker.accessibilityIdentifier = "relay.datePicker"
    datePicker.datePickerMode = .date
    datePicker.preferredDatePickerStyle = .wheels
    datePicker.locale = Locale(identifier: "en_US")
    datePicker.timeZone = Self.utc
    datePicker.calendar = Self.calendar
    datePicker.date = Self.calendar.date(from: DateComponents(year: 2026, month: 6, day: 15)) ?? Date()
    datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
    datePicker.heightAnchor.constraint(equalToConstant: 160).isActive = true
    configure(dateValueLabel, identifier: "relay.dateValue")
    updateDateValue()

    picker.accessibilityIdentifier = "relay.picker"
    picker.dataSource = self
    picker.delegate = self
    picker.selectRow(1, inComponent: 0, animated: false)
    picker.selectRow(2, inComponent: 1, animated: false)
    picker.heightAnchor.constraint(equalToConstant: 140).isActive = true
    configure(pickerValueLabel, identifier: "relay.pickerValue")
    updatePickerValue()

    animateButton.configuration?.title = "Animate: off"
    animateButton.accessibilityIdentifier = "relay.animate"
    animateButton.addTarget(self, action: #selector(toggleAnimation), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [
      row(button("relay.gestures.close", "Close", #selector(close)), button("relay.tapReset", "Reset taps", #selector(resetTaps)),
          animateButton),
      tapTarget,
      tapCountsLabel,
      slider,
      steppedSlider,
      sliderValueLabel,
      datePicker,
      dateValueLabel,
      picker,
      pickerValueLabel
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
    row.distribution = .fillEqually
    return row
  }

  @objc private func close() {
    dismiss(animated: false)
  }

  /// A repeating animation keeps the app from being idle, which XCUI waits for before and after what it does.
  @objc private func toggleAnimation() {
    if animateButton.layer.animationKeys()?.isEmpty == false {
      animateButton.layer.removeAllAnimations()
      animateButton.alpha = 1
      animateButton.configuration?.title = "Animate: off"
    } else {
      UIView.animate(withDuration: 0.5, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]) {
        self.animateButton.alpha = 0.3
      }
      animateButton.configuration?.title = "Animate: on"
    }
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

  /// The stepped slider snaps to quarters when it moves, as an app with discrete values does.
  @objc private func slidersChanged() {
    steppedSlider.value = (steppedSlider.value * 4).rounded() / 4
    updateSliderValue()
  }

  private func updateSliderValue() {
    sliderValueLabel.text = String(format: "slider: %.2f, stepped: %.2f", slider.value, steppedSlider.value)
  }

  private static let utc = TimeZone(identifier: "UTC") ?? .current
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar
  }()

  @objc private func dateChanged() {
    updateDateValue()
  }

  private func updateDateValue() {
    let parts = Self.calendar.dateComponents([.year, .month, .day], from: datePicker.date)
    dateValueLabel.text = String(format: "date: %04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  private func updatePickerValue() {
    let fruit = Self.fruits[picker.selectedRow(inComponent: 0)]
    let number = Self.numbers[picker.selectedRow(inComponent: 1)]
    pickerValueLabel.text = "picker: \(fruit), \(number)"
  }

  func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }

  func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
    component == 0 ? Self.fruits.count : Self.numbers.count
  }

  func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
    component == 0 ? Self.fruits[row] : Self.numbers[row]
  }

  func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
    updatePickerValue()
  }
}

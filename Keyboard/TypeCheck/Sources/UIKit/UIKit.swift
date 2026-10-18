// Minimal UIKit/QuartzCore stand-in for type-checking the keyboard sources on Linux.
// Signatures (labels, optionality, mutability) mirror the iOS 17 SDK for the members the keyboard uses.
@_exported import Foundation

public struct Selector { public init(_ s: String) {} }
/// Stand-in for `#selector(...)` (the harness rewrites `#selector(x)` to `sel(x)`).
public func sel(_ f: Any) -> Selector { Selector("") }

public final class CGColor {}
public final class CGPath {}

// MARK: QuartzCore
open class CALayer: NSObject {
    public override init() { super.init() }
    open var backgroundColor: CGColor?
    open var cornerRadius: CGFloat = 0
    open var isHidden: Bool = false
    open var frame: CGRect = .zero
    open var bounds: CGRect = .zero
    open var masksToBounds: Bool = false
    open var shadowOpacity: Float = 0
    open var shadowRadius: CGFloat = 0
    open var shadowOffset: CGSize = .zero
    open var shadowColor: CGColor?
    open func addSublayer(_ layer: CALayer) {}
    open func removeFromSuperlayer() {}
}
open class CAShapeLayer: CALayer {
    open var path: CGPath?
    open var fillColor: CGColor?
}
open class CATransaction: NSObject {
    open class func begin() {}
    open class func commit() {}
    open class func setDisableActions(_ flag: Bool) {}
}

// MARK: Basic types
public struct UIEdgeInsets: Equatable {
    public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) { self.top = top; self.left = left; self.bottom = bottom; self.right = right }
    public static let zero = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
}
public enum NSTextAlignment: Int { case left, center, right, justified, natural }
public enum NSLineBreakMode: Int { case byWordWrapping, byCharWrapping, byClipping, byTruncatingHead, byTruncatingTail, byTruncatingMiddle }
public enum UIUserInterfaceSizeClass: Int { case unspecified, compact, regular }
public enum UIUserInterfaceStyle: Int { case unspecified, light, dark }

open class UIColor: NSObject {
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { super.init() }
    public init(white: CGFloat, alpha: CGFloat) { super.init() }
    open func withAlphaComponent(_ alpha: CGFloat) -> UIColor { self }
    open var cgColor: CGColor { CGColor() }
    open func getRed(_ red: UnsafeMutablePointer<CGFloat>?, green: UnsafeMutablePointer<CGFloat>?, blue: UnsafeMutablePointer<CGFloat>?, alpha: UnsafeMutablePointer<CGFloat>?) -> Bool { true }
    open class var clear: UIColor { UIColor(white: 0, alpha: 0) }
    open class var white: UIColor { UIColor(white: 1, alpha: 1) }
    open class var black: UIColor { UIColor(white: 0, alpha: 1) }
    open class var systemRed: UIColor { UIColor(white: 0, alpha: 1) }
    open class var label: UIColor { UIColor(white: 0, alpha: 1) }
}

open class UIFont: NSObject {
    public struct Weight: Hashable, RawRepresentable {
        public var rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public init(_ rawValue: CGFloat) { self.rawValue = rawValue }
        public static let ultraLight = Weight(-0.8), thin = Weight(-0.6), light = Weight(-0.4), regular = Weight(0)
        public static let medium = Weight(0.23), semibold = Weight(0.3), bold = Weight(0.4), heavy = Weight(0.56), black = Weight(0.62)
    }
    open class func systemFont(ofSize fontSize: CGFloat, weight: UIFont.Weight) -> UIFont { UIFont() }
    open class func systemFont(ofSize fontSize: CGFloat) -> UIFont { UIFont() }
    open class func boldSystemFont(ofSize fontSize: CGFloat) -> UIFont { UIFont() }
}

open class UIImage: NSObject {
    open class Configuration: NSObject {}
    open class SymbolConfiguration: Configuration {
        public convenience init(pointSize: CGFloat, weight: UIImage.SymbolWeight) { self.init() }
        public convenience init(pointSize: CGFloat) { self.init() }
    }
    public enum SymbolWeight: Int { case unspecified, ultraLight, thin, light, regular, medium, semibold, bold, heavy, black }
    public init?(systemName name: String) { super.init() }
    public init?(systemName name: String, withConfiguration configuration: UIImage.Configuration?) { super.init() }
}

open class UIBezierPath: NSObject {
    public override init() { super.init() }
    open func move(to point: CGPoint) {}
    open func addLine(to point: CGPoint) {}
    open func addQuadCurve(to endPoint: CGPoint, controlPoint: CGPoint) {}
    open func addCurve(to endPoint: CGPoint, controlPoint1: CGPoint, controlPoint2: CGPoint) {}
    open func close() {}
    open var cgPath: CGPath { CGPath() }
}

// MARK: Traits & text input
open class UITraitCollection: NSObject {
    open var verticalSizeClass: UIUserInterfaceSizeClass { .regular }
    open var horizontalSizeClass: UIUserInterfaceSizeClass { .compact }
    open var userInterfaceStyle: UIUserInterfaceStyle { .light }
    open var displayScale: CGFloat { 3 }
}

public enum UIKeyboardType: Int {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}
public enum UIKeyboardAppearance: Int {
    case `default`, dark, light
    public static var alert: UIKeyboardAppearance { .dark }
}
public enum UIReturnKeyType: Int {
    case `default`, go, google, join, next, route, search, send, yahoo, done, emergencyCall, `continue`
}
public enum UITextAutocapitalizationType: Int { case none, words, sentences, allCharacters }
public enum UITextAutocorrectionType: Int { case `default`, no, yes }
public enum UITextSmartQuotesType: Int { case `default`, no, yes }
public struct UITextContentType: Hashable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let name = UITextContentType(rawValue: "name"), namePrefix = UITextContentType(rawValue: "namePrefix")
    public static let givenName = UITextContentType(rawValue: "givenName"), middleName = UITextContentType(rawValue: "middleName")
    public static let familyName = UITextContentType(rawValue: "familyName"), nameSuffix = UITextContentType(rawValue: "nameSuffix")
    public static let nickname = UITextContentType(rawValue: "nickname"), jobTitle = UITextContentType(rawValue: "jobTitle")
    public static let organizationName = UITextContentType(rawValue: "organizationName"), location = UITextContentType(rawValue: "location")
    public static let fullStreetAddress = UITextContentType(rawValue: "fullStreetAddress"), streetAddressLine1 = UITextContentType(rawValue: "streetAddressLine1")
    public static let streetAddressLine2 = UITextContentType(rawValue: "streetAddressLine2"), addressCity = UITextContentType(rawValue: "addressCity")
    public static let addressState = UITextContentType(rawValue: "addressState"), addressCityAndState = UITextContentType(rawValue: "addressCityAndState")
    public static let sublocality = UITextContentType(rawValue: "sublocality"), countryName = UITextContentType(rawValue: "countryName")
    public static let postalCode = UITextContentType(rawValue: "postalCode"), telephoneNumber = UITextContentType(rawValue: "telephoneNumber")
    public static let emailAddress = UITextContentType(rawValue: "emailAddress"), URL = UITextContentType(rawValue: "URL")
    public static let creditCardNumber = UITextContentType(rawValue: "creditCardNumber"), username = UITextContentType(rawValue: "username")
    public static let password = UITextContentType(rawValue: "password"), newPassword = UITextContentType(rawValue: "newPassword")
    public static let oneTimeCode = UITextContentType(rawValue: "oneTimeCode")
    public static let creditCardExpiration = UITextContentType(rawValue: "creditCardExpiration"), creditCardExpirationMonth = UITextContentType(rawValue: "creditCardExpirationMonth")
    public static let creditCardExpirationYear = UITextContentType(rawValue: "creditCardExpirationYear"), creditCardSecurityCode = UITextContentType(rawValue: "creditCardSecurityCode")
    public static let creditCardType = UITextContentType(rawValue: "creditCardType"), creditCardName = UITextContentType(rawValue: "creditCardName")
    public static let creditCardGivenName = UITextContentType(rawValue: "creditCardGivenName"), creditCardMiddleName = UITextContentType(rawValue: "creditCardMiddleName")
    public static let creditCardFamilyName = UITextContentType(rawValue: "creditCardFamilyName")
    public static let birthdate = UITextContentType(rawValue: "birthdate")
}

public protocol UITextInput: AnyObject {}

/// Traits are optional ObjC requirements in UIKit, so reading them through the proxy yields Optionals.
public protocol UITextDocumentProxy: AnyObject {
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    var selectedText: String? { get }
    var documentIdentifier: UUID { get }
    var hasText: Bool { get }
    func adjustTextPosition(byCharacterOffset offset: Int)
    func insertText(_ text: String)
    func deleteBackward()
    var keyboardType: UIKeyboardType? { get }
    var keyboardAppearance: UIKeyboardAppearance? { get }
    var returnKeyType: UIReturnKeyType? { get }
    var autocapitalizationType: UITextAutocapitalizationType? { get }
    var autocorrectionType: UITextAutocorrectionType? { get }
    var smartQuotesType: UITextSmartQuotesType? { get }
    var enablesReturnKeyAutomatically: Bool? { get }
    var isSecureTextEntry: Bool? { get }
    var textContentType: UITextContentType?? { get }
}

open class UILexiconEntry: NSObject {
    open var documentText: String { "" }
    open var userInput: String { "" }
}
open class UILexicon: NSObject {
    open var entries: [UILexiconEntry] { [] }
}

// MARK: Events & gestures
open class UIEvent: NSObject {}
open class UITouch: NSObject {
    /// Test-only: where the finger is, in root (window) coordinates.
    public var testLocation: CGPoint = .zero
    public override init() { super.init() }
    open func location(in view: UIView?) -> CGPoint { view?.convert(testLocation, from: nil) ?? testLocation }
    open var timestamp: TimeInterval { 0 }
}

open class UIGestureRecognizer: NSObject {
    public enum State: Int { case possible, began, changed, ended, cancelled, failed }
    public init(target: Any?, action: Selector?) { super.init() }
    open var state: UIGestureRecognizer.State { .possible }
    open var delaysTouchesBegan: Bool = false
    open var delaysTouchesEnded: Bool = true
    open var cancelsTouchesInView: Bool = true
    open func location(in view: UIView?) -> CGPoint { .zero }
}
open class UILongPressGestureRecognizer: UIGestureRecognizer {
    open var minimumPressDuration: TimeInterval = 0.5
}

// MARK: Views
open class UIResponder: NSObject {
    public override init() { super.init() }
    open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}

public enum UILayoutPriorityRaw {}
public struct UILayoutPriority: Hashable, RawRepresentable {
    public var rawValue: Float
    public init(rawValue: Float) { self.rawValue = rawValue }
    public init(_ rawValue: Float) { self.rawValue = rawValue }
    public static let required = UILayoutPriority(1000), defaultHigh = UILayoutPriority(750), defaultLow = UILayoutPriority(250)
}
open class NSLayoutConstraint: NSObject {
    public enum Axis: Int { case horizontal, vertical }
    open var constant: CGFloat = 0
    open var priority: UILayoutPriority = .required
    open var isActive: Bool = false
}
open class NSLayoutDimension: NSObject {
    open func constraint(equalToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
}

/// A minimal working view tree: frames, bounds (origin always zero), superview/subviews, point conversion
/// and the setNeedsLayout/layoutIfNeeded cycle, enough to drive the keyboard's touch logic in tests.
open class UIView: UIResponder {
    public enum ContentMode: Int { case scaleToFill, scaleAspectFit, scaleAspectFill, redraw, center, top, bottom, left, right }
    public init(frame: CGRect) {
        self.frame = frame
        self.bounds = CGRect(origin: .zero, size: frame.size)
        super.init()
    }
    public required init?(coder: NSCoder) { super.init() }
    public convenience override init() { self.init(frame: .zero) }
    private var needsLayout = true
    private weak var parent: UIView?
    private var children: [UIView] = []
    private let backingLayer = CALayer()
    open var frame: CGRect = .zero {
        didSet {
            if frame.size != oldValue.size {
                bounds = CGRect(origin: .zero, size: frame.size)
                setNeedsLayout()
            }
        }
    }
    open var bounds: CGRect = .zero
    open var center: CGPoint = .zero
    open var superview: UIView? { parent }
    open var subviews: [UIView] { children }
    open var window: UIWindow? { nil }
    open var layer: CALayer { backingLayer }
    open var backgroundColor: UIColor?
    open var isHidden: Bool = false
    open var alpha: CGFloat = 1
    open var tag: Int = 0
    open var isUserInteractionEnabled: Bool = true
    open var isMultipleTouchEnabled: Bool = false
    open var isExclusiveTouch: Bool = false
    open var clipsToBounds: Bool = false
    open var tintColor: UIColor!
    open var contentMode: UIView.ContentMode = .scaleToFill
    open var traitCollection: UITraitCollection { UITraitCollection() }
    open var heightAnchor: NSLayoutDimension { NSLayoutDimension() }
    open var gestureRecognizers: [UIGestureRecognizer]?
    open func addSubview(_ view: UIView) {
        view.removeFromSuperview()
        view.parent = self
        children.append(view)
    }
    open func removeFromSuperview() {
        parent?.children.removeAll { $0 === self }
        parent = nil
    }
    open func bringSubviewToFront(_ view: UIView) {
        guard children.contains(where: { $0 === view }) else { return }
        children.removeAll { $0 === view }
        children.append(view)
    }
    open func insertSubview(_ view: UIView, belowSubview siblingSubview: UIView) {
        view.removeFromSuperview()
        view.parent = self
        let i = children.firstIndex { $0 === siblingSubview } ?? children.count
        children.insert(view, at: i)
    }
    open func insertSubview(_ view: UIView, at index: Int) {
        view.removeFromSuperview()
        view.parent = self
        children.insert(view, at: min(max(index, 0), children.count))
    }
    open func setNeedsLayout() { needsLayout = true }
    open func layoutIfNeeded() {
        guard needsLayout else { return }
        needsLayout = false
        layoutSubviews()
    }
    open func layoutSubviews() {}
    /// Origin in the root view's coordinates.
    private var rootOrigin: CGPoint {
        var p = frame.origin
        var v = parent
        while let s = v {
            p.x += s.frame.origin.x
            p.y += s.frame.origin.y
            v = s.parent
        }
        return p
    }
    open func convert(_ point: CGPoint, to view: UIView?) -> CGPoint {
        let a = rootOrigin, b = view?.rootOrigin ?? .zero
        return CGPoint(x: point.x + a.x - b.x, y: point.y + a.y - b.y)
    }
    open func convert(_ point: CGPoint, from view: UIView?) -> CGPoint {
        let a = view?.rootOrigin ?? .zero, b = rootOrigin
        return CGPoint(x: point.x + a.x - b.x, y: point.y + a.y - b.y)
    }
    open func convert(_ rect: CGRect, to view: UIView?) -> CGRect { CGRect(origin: convert(rect.origin, to: view), size: rect.size) }
    open func convert(_ rect: CGRect, from view: UIView?) -> CGRect { CGRect(origin: convert(rect.origin, from: view), size: rect.size) }
    open func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {}
    open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {}
    open func willMove(toWindow newWindow: UIWindow?) {}
    open func didMoveToWindow() {}
    open class func performWithoutAnimation(_ actionsWithoutAnimation: () -> Void) { actionsWithoutAnimation() }
}
open class UIWindow: UIView {}
open class UIInputView: UIView {}

open class UILabel: UIView {
    open var text: String?
    open var textColor: UIColor!
    open var font: UIFont!
    open var textAlignment: NSTextAlignment = .natural
    open var adjustsFontSizeToFitWidth: Bool = false
    open var minimumScaleFactor: CGFloat = 0
    open var lineBreakMode: NSLineBreakMode = .byTruncatingTail
    open var numberOfLines: Int = 1
}
open class UIImageView: UIView {
    open var image: UIImage?
}

open class UIControl: UIView {
    public struct Event: OptionSet {
        public var rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let touchDown = Event(rawValue: 1), touchDownRepeat = Event(rawValue: 2), touchDragInside = Event(rawValue: 4)
        public static let touchDragOutside = Event(rawValue: 8), touchDragEnter = Event(rawValue: 16), touchDragExit = Event(rawValue: 32)
        public static let touchUpInside = Event(rawValue: 64), touchUpOutside = Event(rawValue: 128), touchCancel = Event(rawValue: 256)
        public static let valueChanged = Event(rawValue: 4096), primaryActionTriggered = Event(rawValue: 8192)
        public static let allTouchEvents = Event(rawValue: 4095)
    }
    public struct State: OptionSet {
        public var rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let normal = State([]), highlighted = State(rawValue: 1), disabled = State(rawValue: 2), selected = State(rawValue: 4)
    }
    public enum ContentHorizontalAlignment: Int { case center, left, right, fill, leading, trailing }
    open var contentHorizontalAlignment: UIControl.ContentHorizontalAlignment = .center
    open var isEnabled: Bool = true
    open var isHighlighted: Bool = false
    open func addTarget(_ target: Any?, action: Selector, for controlEvents: UIControl.Event) {}
    open func removeTarget(_ target: Any?, action: Selector?, for controlEvents: UIControl.Event) {}
}

open class UIButton: UIControl {
    public enum ButtonType: Int { case custom, system, detailDisclosure, infoLight, infoDark, contactAdd, close }
    public convenience init(type buttonType: UIButton.ButtonType) { self.init(frame: .zero) }
    open func setTitle(_ title: String?, for state: UIControl.State) {}
    open func setTitleColor(_ color: UIColor?, for state: UIControl.State) {}
    open func setImage(_ image: UIImage?, for state: UIControl.State) {}
    open func title(for state: UIControl.State) -> String? { nil }
    open var titleLabel: UILabel? { nil }
}

open class UIStackView: UIView {
    public enum Distribution: Int { case fill, fillEqually, fillProportionally, equalSpacing, equalCentering }
    open var axis: NSLayoutConstraint.Axis = .horizontal
    open var distribution: UIStackView.Distribution = .fill
    open var spacing: CGFloat = 0
    open var arrangedSubviews: [UIView] { [] }
    open func addArrangedSubview(_ view: UIView) {}
}

public protocol UIScrollViewDelegate: AnyObject {
    func scrollViewDidScroll(_ scrollView: UIScrollView)
}
public extension UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {}
}
open class UIScrollView: UIView {
    open var showsHorizontalScrollIndicator: Bool = true
    open var showsVerticalScrollIndicator: Bool = true
    open var contentSize: CGSize = .zero
    open var contentOffset: CGPoint = .zero
}

open class UICollectionViewLayout: NSObject {
    public override init() { super.init() }
}
open class UICollectionViewLayoutAttributes: NSObject {
    open var frame: CGRect = .zero
}
public enum UICollectionViewScrollDirection: Int { case vertical, horizontal }
extension UICollectionView {
    public typealias ScrollDirection = UICollectionViewScrollDirection
}
open class UICollectionViewFlowLayout: UICollectionViewLayout {
    open var scrollDirection: UICollectionView.ScrollDirection = .vertical
    open var itemSize: CGSize = .zero
    open var minimumInteritemSpacing: CGFloat = 0
    open var minimumLineSpacing: CGFloat = 0
    open var sectionInset: UIEdgeInsets = .zero
}
open class UICollectionReusableView: UIView {}
open class UICollectionViewCell: UICollectionReusableView {
    open var contentView: UIView { UIView() }
}
public protocol UICollectionViewDataSource: AnyObject {
    func numberOfSections(in collectionView: UICollectionView) -> Int
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell
}
public extension UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }
}
public protocol UICollectionViewDelegate: UIScrollViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
}
public extension UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {}
}
open class UICollectionView: UIScrollView {
    public struct ScrollPosition: OptionSet {
        public var rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let top = ScrollPosition(rawValue: 1), centeredVertically = ScrollPosition(rawValue: 2), bottom = ScrollPosition(rawValue: 4)
        public static let left = ScrollPosition(rawValue: 8), centeredHorizontally = ScrollPosition(rawValue: 16), right = ScrollPosition(rawValue: 32)
    }
    public init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) { super.init(frame: frame) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }
    open var collectionViewLayout: UICollectionViewLayout { UICollectionViewLayout() }
    open weak var dataSource: UICollectionViewDataSource?
    open weak var delegate: UICollectionViewDelegate?
    open func register(_ cellClass: AnyClass?, forCellWithReuseIdentifier identifier: String) {}
    open func dequeueReusableCell(withReuseIdentifier identifier: String, for indexPath: IndexPath) -> UICollectionViewCell { UICollectionViewCell() }
    open func reloadData() {}
    open func cellForItem(at indexPath: IndexPath) -> UICollectionViewCell? { nil }
    open func indexPathForItem(at point: CGPoint) -> IndexPath? { nil }
    open func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? { nil }
    open func scrollToItem(at indexPath: IndexPath, at scrollPosition: UICollectionView.ScrollPosition, animated: Bool) {}
}

// MARK: View controllers
public protocol UIViewControllerTransitionCoordinatorContext: AnyObject {}
public protocol UIViewControllerTransitionCoordinator: UIViewControllerTransitionCoordinatorContext {
    @discardableResult
    func animate(alongsideTransition animation: ((UIViewControllerTransitionCoordinatorContext) -> Void)?, completion: ((UIViewControllerTransitionCoordinatorContext) -> Void)?) -> Bool
}

open class UIViewController: UIResponder {
    open var view: UIView!
    open var traitCollection: UITraitCollection { UITraitCollection() }
    open func viewDidLoad() {}
    open func viewWillAppear(_ animated: Bool) {}
    open func viewDidAppear(_ animated: Bool) {}
    open func viewWillDisappear(_ animated: Bool) {}
    open func viewDidDisappear(_ animated: Bool) {}
    open func viewWillLayoutSubviews() {}
    open func viewDidLayoutSubviews() {}
    open func didReceiveMemoryWarning() {}
    open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {}
    open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {}
}

open class UIInputViewController: UIViewController {
    open var inputView: UIInputView?
    open var textDocumentProxy: UITextDocumentProxy { fatalError() }
    open var hasFullAccess: Bool { false }
    open var needsInputModeSwitchKey: Bool { true }
    open func advanceToNextInputMode() {}
    open func handleInputModeList(from view: UIView, with event: UIEvent) {}
    open func requestSupplementaryLexicon(completion completionHandler: @escaping (UILexicon) -> Void) {}
    open func textWillChange(_ textInput: UITextInput?) {}
    open func textDidChange(_ textInput: UITextInput?) {}
    open func selectionWillChange(_ textInput: UITextInput?) {}
    open func selectionDidChange(_ textInput: UITextInput?) {}
}

extension IndexPath {
    public init(item: Int, section: Int) { self.init(indexes: [section, item]) }
    public var item: Int { self[1] }
    public var section: Int { self[0] }
}

// MARK: Feedback
open class UIFeedbackGenerator: NSObject {
    open func prepare() {}
}
open class UIImpactFeedbackGenerator: UIFeedbackGenerator {
    public enum FeedbackStyle: Int { case light, medium, heavy, soft, rigid }
    public init(style: UIImpactFeedbackGenerator.FeedbackStyle) { super.init() }
    open func impactOccurred() {}
    open func impactOccurred(intensity: CGFloat) {}
}

import SwiftUI

@objc(TVZQuickPathViewController)
open class QuickPathEffectRootViewController : UIViewController {
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let controller = QuickPathEffectViewController()
        addChild(controller)

        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.backgroundColor = .clear
        view.addSubview(controller.view)

        controller.didMove(toParent: self)
    }

    open override var shouldAutorotate: Bool {
        return false
    }

    @objc(_canShowWhileLocked)
    open func _canShowWhileLocked() -> Bool {
        true
    }
}

fileprivate final class QuickPathEffectViewController : UIHostingController<QuickPathEffectView> {
    init() {
        super.init(rootView: QuickPathEffectView())
    }

    @objc required dynamic public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc(_canShowWhileLocked)
    public func _canShowWhileLocked() -> Bool {
        true
    }
}

fileprivate struct QuickPathEffectView: View {
    @ObservedObject var vm = QuickPathEffect.shared

    var body: some View {
        ZStack {
            ForEach(Array(vm.touches.values)) {
                TouchCursor(
                    touch: $0,
                    maximumWidth: vm.fillWidth,
                    animationDuration: vm.animationDuration
                )
                .id($0.id)
                .foregroundColor(vm.fillColor)
            }
        }.edgesIgnoringSafeArea(.all)
    }
}

fileprivate struct TouchCursor: View {
    @ObservedObject var touch: QuickPathEffect.Touch

    let maximumWidth: CGFloat
    let animationDuration: TimeInterval

    var body: some View {
        ZStack(alignment: .center) {
            DragShape(
                points: touch.points,
                maximumWidth: maximumWidth
            )
            .fill()
            .opacity(touch.ended ? 0 : 1.0)
            .animation(.easeIn(duration: animationDuration), value: touch.ended)
        }
    }
}

fileprivate final class QuickPathEffect: ObservableObject {
    static var shared = QuickPathEffect()
    private init() {}

    class Touch: ObservableObject, Identifiable {
        @Published var points: [CGPoint]
        @Published var ended = false
        let id: Int

        init(from uiTouch: UITouch, in window: UIWindow) {
            let location = Self.location(from: uiTouch, in: window)
            self.points = [location, location, location, location]
            self.id = uiTouch.hash

            let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(update(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
        }

        @objc private func update(_ timer: Timer) {
            if self.points.count > 10 {
                self.points.removeFirst(self.points.count / 10)
            } else if self.points.count > 1 {
                self.points.removeFirst()
            } else if self.points.count == 1 && self.ended == true {
                self.points.removeFirst()
                timer.invalidate()
                QuickPathEffect.shared.touches[id] = nil
            }
        }

        static func location(from uiTouch: UITouch, in window: UIWindow) -> CGPoint {
            let o = window._windowInterfaceOrientation()
            let fixedSpace = window.screen.fixedCoordinateSpace.bounds
            let fixedWidth = fixedSpace.width
            let fixedHeight = fixedSpace.height
            var a = uiTouch.location(in: nil)
            let b = a
            switch (o) {
                case .portrait:
                    break
                case .portraitUpsideDown:
                    a.x = fixedWidth - b.x
                    a.y = fixedHeight - b.y
                    break
                case .landscapeLeft:
                    a.x = fixedHeight - b.y
                    a.y = b.x
                    break
                case .landscapeRight:
                    a.x = b.y
                    a.y = fixedWidth - b.x
                    break
                default:
                    break
            }
            return a
        }
    }

    @Published var touches: [Int: Touch] = [:]
    @Published var fillColor: Color = Color.black.opacity(0.4)
    @Published var fillWidth: CGFloat = 10.0
    @Published var animationDuration: TimeInterval = 0.3
}

extension UIWindow {

    @objc
    public func sendQuickPathEvent(_ event: UIEvent) {
        event.allTouches?
        .filter { $0.type == .direct }
        .forEach {
            switch $0.phase {
            case .began: touchBegan($0)
            case .moved, .stationary: touchMoved($0)
            case .cancelled, .ended: touchEnded($0)
            case .regionEntered, .regionMoved, .regionExited: break
            @unknown default: break
            }
        }
    }

    @objc
    public func setQuickPathFillColor(_ color: UIColor) {
        QuickPathEffect.shared.fillColor = Color(color)
    }

    @objc
    public func setQuickPathFillWidth(_ width: CGFloat) {
        QuickPathEffect.shared.fillWidth = width
    }

    @objc
    public func setQuickPathAnimationDuration(_ duration: TimeInterval) {
        QuickPathEffect.shared.animationDuration = duration
    }

    private func touchBegan(_ uiTouch: UITouch) {
        QuickPathEffect.shared.touches[uiTouch.hash] = QuickPathEffect.Touch(from: uiTouch, in: self)
    }

    private func touchMoved(_ uiTouch: UITouch) {
        guard let touch = QuickPathEffect.shared.touches[uiTouch.hash] else { return }
        touch.points.append(QuickPathEffect.Touch.location(from: uiTouch, in: self))
    }

    private func touchEnded(_ uiTouch: UITouch) {
        guard let touch = QuickPathEffect.shared.touches[uiTouch.hash] else { return }
        touch.points.append(QuickPathEffect.Touch.location(from: uiTouch, in: self))
        touch.ended = true
    }

    @objc
    public func endAllQuickPathTouches() {
        QuickPathEffect.shared.touches.values.forEach {
            if !$0.ended {
                $0.ended = true
            }
        }
    }
}

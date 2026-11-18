import Combine
import SwiftUI
import SwiftUIIntrospect
import UIKit

final class TVZRootController: UIHostingController<TVZRootView> {

    private let primaryScrollViewSubject = CurrentValueSubject<UIScrollView?, Never>(nil)
    private var cancellables = Set<AnyCancellable>()

    init() {
        super.init(rootView: TVZRootView(scrollViewSubject: primaryScrollViewSubject))

        primaryScrollViewSubject
            .compactMap { $0 }
            .sink { scrollView in
                NSLog("[Touch-Viz] Primary scroll view: \(scrollView)")
            }
            .store(in: &cancellables)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc var contentScrollView: UIScrollView? {
        primaryScrollViewSubject.value
    }
}

@objc(TVZRootListController)
final class TVZRootListController: PSListController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // integrated entry uses the requested Chinese title

        navigationItem.title = "录屏轨迹"
        navigationItem.largeTitleDisplayMode = .never

        let controller = TVZRootController()
        addChild(controller)

        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(controller.view)

        controller.didMove(toParent: self)
    }

    // 3.1.9: 若本页被旧注册项当成「漂流岛」根页直接打开(导航栈里没有 DriftIslandPrefs
    // 的 DIPrefsController / DIRecordingTrailPage), 把栈顶换成完整设置根页。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let nav = navigationController, !nav.viewControllers.isEmpty else { return }
        let names = nav.viewControllers.map { NSStringFromClass(type(of: $0)) }
        if names.contains("DIPrefsController") || names.contains("DIRecordingTrailPage") { return }
        if nav.viewControllers.count == 1 && nav.presentingViewController != nil { return }
        var cls = NSClassFromString("DIPrefsController") as? NSObject.Type
        if cls == nil {
            let dir = (Bundle(for: type(of: self)).bundlePath as NSString).deletingLastPathComponent
            if let b = Bundle(path: dir + "/DriftIslandPrefs.bundle") { b.load() }
            cls = NSClassFromString("DIPrefsController") as? NSObject.Type
        }
        guard let t = cls, let vc = t.init() as? UIViewController else { return }
        var vcs = nav.viewControllers
        vcs[vcs.count - 1] = vc
        nav.setViewControllers(vcs, animated: false)
    }

    private func addNavigationBarImage() {
        guard let image = UIImage(named: "icon", in: Bundle.tvz_support, with: nil) else {
            return
        }
        let imageView = UIImageView(image: image)
        let bannerWidth: CGFloat = 32
        let bannerHeight: CGFloat = 32
        let bannerX = bannerWidth / 2 - image.size.width / 2
        let bannerY = bannerHeight / 2 - image.size.height / 2
        imageView.frame = CGRect(x: bannerX, y: bannerY, width: bannerWidth, height: bannerHeight)
        imageView.contentMode = .scaleAspectFit
        navigationItem.titleView = imageView
    }

    @objc var contentScrollView: UIScrollView? {
        (children.first as? TVZRootController)?.contentScrollView
    }
}

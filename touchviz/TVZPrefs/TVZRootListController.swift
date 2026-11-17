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

import UIKit

extension String {
	static let nativeEmojiSize: CGFloat = 160

	// Different classes and methods for rendering emoji, and slightly differing fudging offsets!!!
	func render(size: CGFloat) -> UIImage {
		let font = UIFont.systemFont(ofSize: size)
		let cgSize = CGSize(width: size, height: size)
		return UIGraphicsImageRenderer(size: cgSize).image { context in
			self.draw(at: CGPoint(x: -5.5 * (size/Self.nativeEmojiSize), y: -16 * (size/Self.nativeEmojiSize)),
					  withAttributes: [.font: font])
		}
	}
}

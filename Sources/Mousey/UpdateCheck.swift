import Foundation

enum UpdateCheck {
	static let repository = "IMsumitkumar/mousey"
	static let releasePage = URL(string: "https://github.com/\(repository)/releases/latest")!
	private static let api = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

	private static let secondsToWaitForNetwork: TimeInterval = 300

	private static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.waitsForConnectivity = true
		configuration.timeoutIntervalForResource = secondsToWaitForNetwork
		// Only what GitHub needs. The defaults would also tell it this Mac's system version and languages.
		configuration.httpAdditionalHeaders = ["Accept": "application/vnd.github+json", "User-Agent": "mousey", "Accept-Language": "en"]
		return URLSession(configuration: configuration)
	}()

	static func latestTag(from url: URL = api, completion: @escaping (String?) -> Void) {
		struct Release: Decodable { var tag_name: String }
		session.dataTask(with: url) { data, response, _ in
			let isRelease = (response as? HTTPURLResponse)?.statusCode == 200
			let tag = isRelease ? data.flatMap { try? JSONDecoder().decode(Release.self, from: $0).tag_name } : nil
			DispatchQueue.main.async { completion(tag) }
		}.resume()
	}
}

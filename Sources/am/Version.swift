/// The released version.
///
/// It lives here rather than beside `main` so that a test can read it, and so
/// the release workflow has one unambiguous line to compare against the tag it
/// is building — publishing stops when the two disagree.
enum Build {
    static let version = "0.1.2"
}

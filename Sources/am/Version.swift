enum Build {
    /// The git tag is the only place a version number is decided. The release
    /// workflow substitutes the tag it is building into this line before it
    /// compiles, so a published binary cannot disagree with the tag it was
    /// published under — there is nothing to keep in sync.
    ///
    /// A binary you built yourself is not a release, and says so.
    static let version = "dev"
}

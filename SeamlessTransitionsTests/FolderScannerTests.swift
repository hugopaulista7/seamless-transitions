import Foundation
import Testing
@testable import SeamlessTransitions

@Suite struct FolderScannerTests {
    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: url)
    }

    @Test func recursesNestedTreeAndReportsRelativePaths() throws {
        let d = TempDir(name: "scan")
        try touch(d.file("a.mp3"))
        try touch(d.file("sub/b.wav"))
        try touch(d.file("sub/deeper/still/c.flac"))
        try touch(d.file("sub/deeper/d.m4a"))
        let tracks = try FolderScanner.scan(d.url)
        #expect(tracks.map(\.relativePath) == ["a.mp3", "sub/b.wav", "sub/deeper/d.m4a", "sub/deeper/still/c.flac"])
        #expect(tracks.map(\.fileName) == ["a", "b", "d", "c"])
        #expect(Set(tracks.map(\.id)).count == 4)
    }

    @Test func skipsHiddenFilesAndFolders() throws {
        let d = TempDir(name: "scan")
        try touch(d.file("visible.mp3"))
        try touch(d.file(".hidden.mp3"))
        try touch(d.file(".cache/inside.mp3"))
        let tracks = try FolderScanner.scan(d.url)
        #expect(tracks.map(\.relativePath) == ["visible.mp3"])
    }

    @Test func skipsNonAudioAndPlaylists() throws {
        let d = TempDir(name: "scan")
        try touch(d.file("song.mp3"))
        try touch(d.file("notes.txt"))
        try touch(d.file("list.m3u"))
        try touch(d.file("list.m3u8"))
        try touch(d.file("album.cue"))
        try touch(d.file("cover.jpg"))
        let tracks = try FolderScanner.scan(d.url)
        #expect(tracks.map(\.relativePath) == ["song.mp3"])
    }

    @Test func skipsPackageContents() throws {
        let d = TempDir(name: "scan")
        try touch(d.file("keep.mp3"))
        try touch(d.file("Thing.bundle/sample.wav"))
        try touch(d.file("Doc.rtfd/sample.wav"))
        try touch(d.file("Thing.app/Contents/Resources/sound.caf"))
        let tracks = try FolderScanner.scan(d.url)
        #expect(tracks.map(\.relativePath) == ["keep.mp3"])
    }

    @Test func acceptsMixedCaseExtensions() throws {
        let d = TempDir(name: "scan")
        for n in ["a.MP3", "b.Wav", "c.FLAC", "d.M4A", "e.AiFf", "f.caf"] { try touch(d.file(n)) }
        let tracks = try FolderScanner.scan(d.url)
        #expect(tracks.count == 6)
    }

    @Test func naturalSortOrdersNumbersNumerically() throws {
        let d = TempDir(name: "scan")
        for n in ["Track 10.mp3", "Track 2.mp3", "Track 1.mp3", "Track 20.mp3", "track 3.mp3"] { try touch(d.file(n)) }
        try touch(d.file("Album 2/x.mp3"))
        try touch(d.file("Album 10/x.mp3"))
        let tracks = try FolderScanner.scan(d.url)
        #expect(tracks.map(\.relativePath) == [
            "Album 2/x.mp3", "Album 10/x.mp3",
            "Track 1.mp3", "Track 2.mp3", "track 3.mp3", "Track 10.mp3", "Track 20.mp3",
        ])
    }

    @Test func emptyFolderGivesNoTracks() throws {
        let d = TempDir(name: "scan")
        #expect(try FolderScanner.scan(d.url).isEmpty)
    }

    @Test func trackIdentityIsStandardizedPath() throws {
        let d = TempDir(name: "scan")
        try touch(d.file("x/../y.mp3"))
        let t = Track(url: d.file("x/../y.mp3"), root: d.url)
        #expect(t.relativePath == "y.mp3")
        #expect(t.id == t.url.path)
    }
}

import Foundation

public struct ImportedSong: Sendable {
    public let title: String
    public let artist: String?
    public let year: Int?
    public let fileName: String
    public let audioData: Data
    public let cdgData: Data

    public init(title: String, artist: String?, year: Int?, fileName: String, audioData: Data, cdgData: Data) {
        self.title = title
        self.artist = artist
        self.year = year
        self.fileName = fileName
        self.audioData = audioData
        self.cdgData = cdgData
    }
}

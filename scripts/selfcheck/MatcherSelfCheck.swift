import Foundation

// ponytail: @main wrapper required because swiftc multi-file compilation only allows top-level code in main.swift
@main struct MatcherSelfCheck {
    static func main() {
        func song(_ t:String,_ a:String,_ d:Int,_ album:String?=nil)->YTMCandidate{YTMCandidate(videoId:UUID().uuidString,title:t,artists:[a],album:album,durationMs:d,resultType:.song,videoType:nil)}
        func vid(_ t:String,_ a:String,_ d:Int)->YTMCandidate{YTMCandidate(videoId:UUID().uuidString,title:t,artists:[a],album:nil,durationMs:d,resultType:.video,videoType:"MUSIC_VIDEO_TYPE_UGC")}
        let base = SpotifyTrack(id:"1",title:"Chaise Longue",artists:["Wet Leg"],album:"Wet Leg",durationMs:197000,isrc:nil)
        // exact -> high
        assert(Matcher.match(base, candidates:[song("Chaise Longue","Wet Leg",197500,"Wet Leg")]).confidence == .high)
        // remastered suffix, album missing -> still high
        assert(Matcher.match(base, candidates:[song("Chaise Longue (Remastered 2022)","Wet Leg",197000,nil)]).confidence == .high)
        // wrong duration (live) -> low
        assert(Matcher.match(base, candidates:[song("Chaise Longue (Live)","Wet Leg",260000,nil)]).confidence == .low)
        // video-only -> low, never high
        assert(Matcher.match(base, candidates:[vid("Chaise Longue","Wet Leg",197000)]).confidence == .low)
        // not found -> none, chosen nil
        let none = Matcher.match(base, candidates:[]); assert(none.confidence == .none && none.chosen == nil)
        // Radio Edit is a real version marker -> must NOT match base track at .high (regression: fix for over-stripping)
        assert(Matcher.match(base, candidates:[song("Chaise Longue (Radio Edit)","Wet Leg",197500,nil)]).confidence == .low)
        // duration ABSENT (YTM search omits it) -> title+artist+song still qualifies as high
        assert(Matcher.match(base, candidates:[YTMCandidate(videoId:"x",title:"Chaise Longue",artists:["Wet Leg"],album:nil,durationMs:nil,resultType:.song,videoType:nil)]).confidence == .high)
        // ISRC-confirmed: a VIDEO result with matching title+artist is high (ISRC pins the exact recording)
        assert(Matcher.match(base, candidates:[vid("Chaise Longue","Wet Leg",197000)], isrcConfirmed:true).confidence == .high)
        // same video WITHOUT ISRC confirmation -> low (video never auto-accepts on text match)
        assert(Matcher.match(base, candidates:[vid("Chaise Longue","Wet Leg",197000)]).confidence == .low)
        // ISRC-confirmed but title mismatch -> still NOT high (guards against an un-indexed ISRC returning junk)
        assert(Matcher.match(base, candidates:[song("Totally Different Song","Wet Leg",197000)], isrcConfirmed:true).confidence == .low)
        print("Matcher self-check PASS")
    }
}

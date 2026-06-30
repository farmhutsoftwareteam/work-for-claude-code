// Signposts for profiling the streaming hot path in Instruments.
//
// View in Instruments with the "os_signpost" instrument (filter subsystem
// "com.munyamakosa.work", category "stream") or the Points of Interest track.
// Near-zero cost when Instruments isn't attached, so it's left in for Release
// profiling — which is the only honest way to measure (Debug carries the
// InjectionIII / -interposable overhead). See PERFORMANCE.md.
//
// What's instrumented:
//   • handle.<eventType>  — interval per stream event processed (which event
//     types cost time; watch handle.streamEvent during a long reply).
//   • turn-start / turn-end / flush / transcript-render — Point-of-Interest
//     events, so you can line render frequency up against the stream timeline.

import os

enum V2Signpost {
    static let signposter = OSSignposter(subsystem: "com.munyamakosa.work", category: "stream")
}

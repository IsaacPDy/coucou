import Foundation

@main
enum DictationTranscriptTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {

        print("\nTranscript kept whole")
        do {
            typealias P = DictationTranscript.Piece
            func words(_ list: [(Double, String)]) -> [P] { list.map { P(start: $0.0, end: $0.0 + 0.3, text: $0.1) } }

            var t = DictationTranscript()
            t.absorb("Ok mais", pieces: words([(0, "Ok"), (0.4, "mais")]))
            t.absorb("Ok mais c'est au top", pieces: words([(0, "Ok"), (0.4, "mais"), (0.8, "c'est"), (1.2, "au"), (1.6, "top")]))
            check("a growing result is taken as is", t.text == "Ok mais c'est au top")
            t.absorb("Ok mais c'est au top.", pieces: words([(0, "Ok"), (0.4, "mais"), (0.8, "c'est"), (1.2, "au"), (1.6, "top.")]))
            check("the recognizer's own formatting wins", t.text == "Ok mais c'est au top.")

            // The recognizer drops the middle stretch from a later result.
            var m = DictationTranscript()
            m.absorb("un deux trois quatre cinq", pieces: words([(0, "un"), (1, "deux"), (2, "trois"), (3, "quatre"), (4, "cinq")]))
            m.absorb("un deux cinq six", pieces: words([(0, "un"), (1, "deux"), (4, "cinq"), (5, "six")]))
            check("a dropped middle stretch is put back", m.text == "un deux trois quatre cinq six")

            // A correction of the last words replaces them, nothing is doubled.
            var c = DictationTranscript()
            c.absorb("je vais à la plage", pieces: words([(0, "je"), (0.5, "vais"), (1, "à"), (1.3, "la"), (1.6, "plage")]))
            c.absorb("je vais à Laplace", pieces: words([(0, "je"), (0.5, "vais"), (1, "à"), (1.35, "Laplace")]))
            check("a correction replaces the old words", c.text == "je vais à Laplace")

            // Times that shift a little between results do not double a word.
            var s = DictationTranscript()
            s.absorb("bonjour à tous", pieces: words([(1.0, "bonjour"), (1.4, "à"), (1.7, "tous")]))
            s.absorb("Bonjour à tous", pieces: words([(1.15, "Bonjour"), (1.5, "à"), (1.8, "tous")]))
            check("shifted times replace, not double", s.text == "Bonjour à tous")

            // The recognizer starts over after a pause, times from zero again.
            var r = DictationTranscript()
            r.absorb("la première phrase est assez longue", pieces: words([(0, "la"), (0.4, "première"), (0.9, "phrase"), (1.3, "est"), (1.6, "assez"), (2.0, "longue")]))
            r.absorb("ensuite", pieces: words([(0, "ensuite")]))
            r.absorb("ensuite la suite", pieces: words([(0, "ensuite"), (0.5, "la"), (0.8, "suite")]))
            check("a fresh start keeps what came before", r.text == "la première phrase est assez longue ensuite la suite")

            // No times at all: plain replace, fresh starts still kept.
            var u = DictationTranscript()
            u.absorb("hello there my friend")
            u.absorb("hello there my friend how are you")
            check("untimed growth", u.text == "hello there my friend how are you")
            u.absorb("great")
            check("untimed fresh start", u.text == "hello there my friend how are you great")
            // Partial results without times, then a final result with times: nothing doubled.
            var f = DictationTranscript()
            f.absorb("Salut coucou", pieces: [P(start: 0, end: 0, text: "Salut"), P(start: 0, end: 0, text: "coucou")])
            f.absorb("Salut coucou comment tu vas", pieces: ["Salut", "coucou", "comment", "tu", "vas"].map { P(start: 0, end: 0, text: $0) })
            f.absorb("Salut coucou comment tu vas", pieces: words([(0.6, "Salut"), (1.0, "coucou"), (1.5, "comment"), (1.9, "tu"), (2.1, "vas")]))
            check("untimed partials then a timed final: said once", f.text == "Salut coucou comment tu vas")

            // Times that move a lot between results, same words: said once.
            var g = DictationTranscript()
            g.absorb("Salut coucou comment tu vas", pieces: words([(0.0, "Salut"), (0.4, "coucou"), (0.8, "comment"), (1.1, "tu"), (1.3, "vas")]))
            g.absorb("Salut, coucou, comment tu vas ?", pieces: words([(2.0, "Salut,"), (2.4, "coucou,"), (2.8, "comment"), (3.1, "tu"), (3.3, "vas ?")]))
            check("same words at other times: said once", g.text == "Salut, coucou, comment tu vas ?")
            check("normalized", DictationTranscript.normalized("Salut, Coucou !") == "salut coucou")

            check("a short correction is not a fresh start", !DictationTranscript.isRestart(previous: "one two three four", new: "one two"))
            check("too little text to call it a fresh start", !DictationTranscript.isRestart(previous: "one two", new: "three"))
        }

        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}

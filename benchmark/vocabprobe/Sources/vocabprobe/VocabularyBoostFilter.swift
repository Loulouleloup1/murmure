import CoreML
import WhisperKit

// A logits filter that boosts specific vocabulary terms directly at the sampling step,
// entirely separate from `DecodingOptions.promptTokens` and therefore not subject to
// WhisperKit's 111-token prompt budget (`TextDecoder.swift:199`, silent `.suffix` from the
// front). Built to answer one question for
// `docs/benchmarks/2026-09-vocabulary-logits-bias.md`: does a logits bias repair mis-heard
// vocabulary terms, and does it let a personal vocabulary grow past the prompt's ~20-term
// ceiling.
//
// Every term is tokenized WITH a leading space (` Trucost`), because that is how words
// arrive in transcribed speech -- every word is preceded by a space -- the single most
// valuable finding of the prior campaign (`docs/benchmarks/2026-09-vocabulary-prompt.md`,
// "une espace, pas une liste").
//
// At each decode step this filter looks at the tail of the token history so far, for every
// term independently:
//   - a term whose first token has not been emitted (no partial match currently in
//     progress) gets `firstTokenBonus` added to that first token's logit -- a nudge to
//     START the term;
//   - a term whose first `k` tokens (`k >= 1`) match the tail of the history gets
//     `continuationBonus` added to token `k`'s logit (the next one needed) -- stronger
//     than the first-token bonus, because once ` Tru` has been emitted, `cost` is nearly
//     certain, whereas starting a term is a genuine choice.
//
// This is unconditional and contextual only in the sense that it reads the token history:
// it does NOT look at the audio or the encoder output, so a naive strength setting can
// still inject a term that was never spoken -- that risk is measured, not avoided, by the
// `boost-absent` control arm in the campaign above.
final class VocabularyBoostFilter: LogitsFiltering {
    private let termTokens: [[Int]]
    private let firstTokenBonus: Float
    private let continuationBonus: Float

    /// - Parameter termTokens: one token sequence per term, already encoded with a leading
    ///   space and with special tokens filtered out (`main.swift` does both, exactly as it
    ///   already does for `promptTokens`). Empty sequences are dropped -- they cannot match
    ///   anything and would crash the `term[0]`/`term[matched]` lookups below.
    init(termTokens: [[Int]], firstTokenBonus: Float, continuationBonus: Float) {
        self.termTokens = termTokens.filter { !$0.isEmpty }
        self.firstTokenBonus = firstTokenBonus
        self.continuationBonus = continuationBonus
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard let vocabSize = logits.shape.last?.intValue else { return logits }

        // Collect bonuses per token id first, in case two terms want to boost the same
        // token this step (e.g. two terms sharing a first token) -- bonuses add, they do
        // not overwrite each other, same rule as the read-modify-write below.
        var bonusByToken: [Int: Float] = [:]
        for term in termTokens {
            // Longest k (1..<term.count) such that the last k tokens of the history equal
            // the first k tokens of the term -- i.e. how far into this term we already are.
            var matched = 0
            var k = min(term.count - 1, tokens.count)
            while k > 0 {
                if Array(tokens.suffix(k)) == Array(term.prefix(k)) {
                    matched = k
                    break
                }
                k -= 1
            }
            let bonus = matched > 0 ? continuationBonus : firstTokenBonus
            bonusByToken[term[matched], default: 0] += bonus
        }

        // Built-in filters index the logits as [0, 0, tokenId] (`LogitsFilter.swift`) --
        // follow that, and bounds-check against the array's last dimension before writing.
        // Read-modify-write, never `fill(indexes:with:)`: that helper assigns and would
        // erase whatever the built-in filters already did to this token.
        let pointer = UnsafeMutablePointer<FloatType>(OpaquePointer(logits.dataPointer))
        for (tokenId, bonus) in bonusByToken {
            guard tokenId >= 0, tokenId < vocabSize else { continue }
            let offset = logits.linearOffset(for: [0, 0, tokenId])
            pointer[offset] = FloatType(Float(pointer[offset]) + bonus)
        }
        return logits
    }
}

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
//
// Round 2 (`docs/benchmarks/2026-09-vocabulary-logits-bias.md`, this round's section):
// bonuses are now PER TERM rather than one global pair for the whole filter. This is the
// minimum change needed to test a "bridling rule" -- a term whose tokenization is a single
// token (e.g. ` PR`) can NEVER reach the continuation branch below (`term.count - 1 == 0`,
// so `matched` is always 0): it draws `firstTokenBonus` unconditionally, at every decode
// step, for the entire file. A per-filter global bonus cannot express "give this term less,
// or none" without also changing every other term; a per-term bonus can.
final class VocabularyBoostFilter: LogitsFiltering {
    /// One boosted term: its token sequence (leading space, special tokens already
    /// filtered by the caller) and its own first-token / continuation bonuses. A term
    /// bridled to zero strength is still carried here rather than dropped by the caller,
    /// so the job file stays a plain list of "terms in the vocabulary pane" independent of
    /// whatever rule decided its strength.
    struct Term {
        let tokens: [Int]
        let firstTokenBonus: Float
        let continuationBonus: Float
    }

    private let terms: [Term]

    /// - Parameter terms: one entry per boosted term. Entries with an empty token
    ///   sequence are dropped -- they cannot match anything and would crash the
    ///   `tokens[0]`/`tokens[matched]` lookups below.
    init(terms: [Term]) {
        self.terms = terms.filter { !$0.tokens.isEmpty }
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard let vocabSize = logits.shape.last?.intValue else { return logits }

        // Collect bonuses per token id first, in case two terms want to boost the same
        // token this step (e.g. two terms sharing a first token) -- bonuses add, they do
        // not overwrite each other, same rule as the read-modify-write below.
        var bonusByToken: [Int: Float] = [:]
        for term in terms {
            // Longest k (1..<term.tokens.count) such that the last k tokens of the history
            // equal the first k tokens of the term -- i.e. how far into this term we
            // already are. For a single-token term this loop never runs (`term.tokens.count
            // - 1 == 0`), so `matched` stays 0 forever: there is no continuation branch to
            // reach, only the first-token one, every single step.
            var matched = 0
            var k = min(term.tokens.count - 1, tokens.count)
            while k > 0 {
                if Array(tokens.suffix(k)) == Array(term.tokens.prefix(k)) {
                    matched = k
                    break
                }
                k -= 1
            }
            let bonus = matched > 0 ? term.continuationBonus : term.firstTokenBonus
            bonusByToken[term.tokens[matched], default: 0] += bonus
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

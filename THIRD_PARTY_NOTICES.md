# Third-party notices

Checkmate original code and owner-authored course materials: GPL-3.0-or-later;
see LICENSE and the bundled Checkmate-COPYING.txt.

Stockfish 19: GPL-3.0-or-later (its source files grant GPL version 3 "or (at your
option) any later version"). Exact upstream source archive and reproducible recipe:
[ThirdParty/Stockfish](ThirdParty/Stockfish/). Binary and official
external NNUE network hashes are in the bundled stockfish-build.json. Signed
release manifests also retain the unsigned binary hash. Full engine license:
Sources/CheckmateCore/Resources/Stockfish-COPYING.txt.

Stockfish NNUE network `nn-1a298aa575a0.nnue`: the official sf_19 default network,
shipped unmodified. The sf_19 README in the source archive lists the `.nnue` file as part
of the Stockfish distribution, which it licenses under the GNU GPL version 3; the network
is distributed under those terms. The same README states that Stockfish's networks are
trained on Leela Chess Zero data made available under the
[Open Database License](https://opendatacommons.org/licenses/odbl/odbl-10.txt) (ODbL).

chess.js 1.4.0: BSD-2-Clause, copyright Jeff Hlywa. JavaScriptCore executes these
chess rules; the application has no web UI. The full rules license is bundled.

Dock and lesson knight: CC0-1.0 artwork from
https://www.svgrepo.com/svg/201803/horse-chess . Original artwork and recorded
provenance are in Artwork/Upstream. Adaptations: grayscale palette,
scaling, positioning and an Icon Composer graphite background.

Cedar lesson recordings: AI-generated OpenAI speech. The bundled
course-narration.json records the model, voice, input and final asset hashes.

The bundled native MCP companion uses the official Swift MCP SDK 0.12.1 (MIT)
and its Swift dependencies: EventSource (MIT), SwiftNIO, Swift System, Swift Log,
Swift Atomics and Swift Collections (Apache-2.0 with Swift runtime exception).
Exact resolved revisions are in Package.resolved. Full license texts
are bundled under Sources/CheckmateCore/Resources/Licenses/.

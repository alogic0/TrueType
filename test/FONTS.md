# Font and reference provenance

The library source license does not replace the licenses of test assets. These
fonts, license notices, and the C reference are development fixtures excluded
from the library package manifest.

| Asset | Provenance and terms | SHA-256 |
| --- | --- | --- |
| `GoNotoCurrent-Regular.ttf` | Embedded name table identifies [Go Noto Universal at 0f4be64](https://github.com/satbyy/go-noto-universal/tree/0f4be64616e29390e3063970ed7f6afe77356d39), Copyright 2022 The Noto Project Authors, and SIL OFL 1.1. Upstream distinguishes generated fonts (OFL) from build scripts (Unlicense). [OFL text](licenses/Noto-OFL.txt). | `882afbab965608c2d2bc627fd8016b962aa5a6be2d358f9de24a7b5967c5632e` |
| `StandardSymbolsPS.otf` | Byte-for-byte match with [Artifex URW Base35 at 3c0ba3b](https://github.com/ArtifexSoftware/urw-base35-fonts/blob/3c0ba3b5687632dfc66526544a4e811fe0ec0cd9/fonts/StandardSymbolsPS.otf). Embedded copyright: URW Software, Copyright 2015 by URW. Upstream supplies [AGPLv3](licenses/URW-COPYING.txt) with a [font embedding exception](licenses/URW-LICENSE.txt). | `df570efda2df425dbfc004e4e5f77c55ca1b47f8ff28ad60dfad0fccf422b0bd` |

The Noto license text was copied from its named upstream project at
[023d7b7](https://github.com/notofonts/latin-greek-cyrillic/blob/023d7b73d5c1a5ed6489bd04a120244c1f2bff3f/OFL.txt).
The exact Noto binary's upstream download hash has not independently been
reconstructed; its embedded source/license metadata and this checkout's hash are
recorded separately. Preserve notices when distributing test assets; do not
represent the fonts as MIT-licensed library code.

`stb_truetype.h` includes its dual public-domain/MIT license at the end of the
file. Its only local production-code adaptation is extension-positioning
traversal added in commit `0ffe7d9`. The Zig test fixture also normalizes supported
pair records for scalar advance comparisons. These adaptations do not make stb
an oracle for unsupported features or malformed data.

Synthetic fixtures are authored source arrays under this repository's source
license. They cover branches without requiring additional font downloads.

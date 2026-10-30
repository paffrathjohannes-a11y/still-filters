# still-filters

Safari content blocker lists for the **Still** app (iPhone, iPad, Mac), built every day from free filter lists.

1. All sources in [`lists.json`](lists.json) are downloaded and their licence notice is checked.
2. `still-check` converts them into Safari content blocker JSON and validates every rule with WebKit.
3. The result is tested with real WebKit: known ad and tracker scripts must be blocked, common libraries
   must keep working, ad slots must be hidden, and real sites are loaded with and without the blocker.
4. Only if every hard check passes is the new version published to GitHub Pages
   (`https://paffrathjohannes-a11y.github.io/still-filters/v1/manifest.json`). Otherwise the last good version
   stays online and an issue is opened.

## Filter list licences

The published lists are adaptations of the sources below and are distributed under the same terms
(CC BY-SA 3.0 where a source requires share-alike). Thanks to all list maintainers.

EasyList, EasyPrivacy and the EasyList language lists (CC BY-SA 3.0), Fanboy's lists (CC BY 3.0),
Liste FR and Liste AR (CC BY-SA 3.0), RU AdList (CC BY 3.0), EasyList Czech and Slovak (CC BY-SA 4.0),
malware-filter by curbengh (CC0), NoCoin (MIT). Full list with links: `v1/manifest.json` → `attribution`.

## Code

The converter and the checker in `Sources/` are © Johannes Paffrath. All rights reserved.

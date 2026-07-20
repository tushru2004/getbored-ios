# Research result: store selling distraction-free phones and configured iPhones

Checked 3 July 2026.

## 1. Best match: BSD Phones

**Store:** https://bsdphones.com/

**Configured iPhone product:** https://bsdphones.com/products/iphone-se-second-gen-unlocked-all-carriers

BSD Phones is the strongest match. It is a multi-model retailer, not an iPhone-only service. Its catalog/navigation includes CAT, FIG, Kyocera, LG, MegaLife, Qin, Sonim, TCL, Wonder and talk-only phones, plus an **“IPHONE”** entry under GPS Navigation. Its About page describes the inventory as “a curated selection of flip phones, bar phones, kosher phones, and filtered phones.”

The live iPhone listing is titled **“iPhone SE UNLOCKED ALL CARRIERS Filtered Waze Only”** and sells an iPhone SE (second generation), 64 GB, for $200. Direct evidence from the product page:

> “Filtered for navigation purposes only.”

> “This model is used primarily for navigation purposes and can come preinstalled with Waze, Google Maps, Weather, and CarPlay. For added assurance the browser is fully removed as well.”

The page offers selectable configurations: Waze, Google Maps, Waze/Weather, or Google Maps/Weather. The item was in stock when checked.

Important qualification: this particular iPhone is a dedicated navigation device, not a full minimalist phone; the listing explicitly says **“Does NOT include Talk and Text.”** It nevertheless fits the remembered store unusually well because the same retailer sells many flip, bar, filtered, and “kosher” phones alongside a ready-configured iPhone.

Additional evidence that BSD markets its wider range around reduced distraction:

> “A basic phone is a mobile phone designed primarily for calling and texting, without extra features like internet browsing, apps, or other complex options. They are ideal for users who need simple communication tools and don't want the distractions that smartphones can cause.”

Source: https://bsdphones.com/pages/faq

## 2. How BSD's iPhone is configured

The product page only states the observable configuration; it does **not** disclose whether the restriction is enforced through Apple supervision, MDM, a configuration profile, Screen Time, or another mechanism.

What BSD explicitly promises:

- It is “Filtered for navigation purposes only.”
- Waze or Google Maps is preinstalled; Weather may be included, and CarPlay is available.
- “The browser is fully removed.”
- Talk and text are absent.
- It arrives as a configured product ready to order online.

Therefore it is safe to describe this as a **preconfigured, browser-removed, navigation-only iPhone**, but not as a confirmed supervised/MDM iPhone. The enforcement technology should be confirmed with BSD before purchase.

## 3. Other candidate sites found

- **GuardianLock** — https://guardianlock.org/self-advocates.html — Supplies preconfigured refurbished-to-premium iPhones with custom app/content controls, DNS filtering, blocked profile removal/sideloading, Focus modes, and enterprise-grade controls. Strong match for configured distraction-managed iPhones, but it does not appear to sell the remembered broad dumbphone/flip-phone catalog.
- **Kosher Mobile** — https://koshermobile.com/about-us/ — Says it sells filtered basic phones, kosher smartphones, and Waze-only devices, customized with only needed apps while “completely remov[ing] the unsafe/distracting apps.” No indexed iPhone product was found, and the store's TLS/edge configuration prevented reliable direct catalog enumeration.
- **The Phone Gesheft** — https://thephonegesheft.com/ — Sells multiple browser-free flip and filtered Android phones “pre-configured and ready to use.” Its own technical explanation says all phones it sells use a custom kosher OS rather than MDM, and its smartphone page explicitly says Android; no iPhone listing was found.
- **Kosher Phone Store** — https://kosherphonestore.com/ — Multi-model WooCommerce store selling filtered/kosher phones such as Qin, Fig, CAT, Kyocera, and Samsung. Its WordPress product API returned no results for `iphone`.
- **The Kosher iPhone** — https://thekosheriphone.com/ — Offers supervised iPhone filtering and distinguishes basic filtered iPhones from supervised iPhones. Already known and lacks the broad multi-model store profile.
- **US Mobile kosher-friendly phones** — https://www.usmobile.com/blog/best-kosher-phones/ — Informational/carrier content about kosher-friendly phones rather than evidence of preconfigured locked iPhones sold alongside a broad minimalist catalog.

## 4. Dead ends checked

- **koshermobile.com:** Browser-UA requests and `/robots.txt`, `/sitemap.xml`, and `/sitemap_index.xml` were attempted. The bare-domain TLS certificate did not match, and bypassing certificate verification produced Akamai/EdgeSuite “Invalid URL” responses. Search indexing exposes its About page but no iPhone product.
- **kosherphonestore.com:** Site/catalog search and the WooCommerce/WordPress product API produced no iPhone products.
- **thephonegesheft.com:** Catalog and indexed pages describe custom-OS Android smartphones and flip phones; no iPhone product found.
- **thephonegesheft.com technical claim:** “All phones we sell use a Custom Kosher OS,” ruling it out as the mixed catalog with configured iPhones.
- **usmobile.com:** No evidence found that US Mobile sells ready-configured or supervised iPhones as kosher/distraction-free products.
- **thephonegesheft.com, kosherphonestore.com, and Kosher Mobile** remain useful adjacent stores, but none matched BSD's direct combination of a wide filtered/flip-phone catalog and a purchasable configured iPhone listing.
- Previously ruled-out sites were not reconsidered as answers: dumbwireless.com, koshercell.org, kosheros.com/SafeTelecom, growelectronics.ca, thebalancephone.com, Techless/Wisephone, kphone.org, kolbo.life, and thekosheriphone.com.

## Conclusion

**BSD Phones is the best-supported identification.** The decisive evidence is its broad catalog of basic, flip, bar, kosher, and filtered phones plus a live, purchasable iPhone SE listing that says the phone is filtered for navigation, comes with selected apps preinstalled, and has its browser fully removed. The only mismatch worth emphasizing is that BSD's listed iPhone has no calling or texting; it is a locked-down GPS/CarPlay device rather than a normal phone with a reduced app set.

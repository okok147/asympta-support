from pathlib import Path

root = Path(__file__).resolve().parents[1]


def replace_one(rel: str, old: str, new: str) -> None:
    path = root / rel
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{rel}: expected one match, found {count}: {old[:100]!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


# Public support page — English canonical copy plus Traditional Chinese mirror.
replace_one(
    "index.html",
    "Asympta is a local-first handwriting canvas. All creative tools are free. A one-time Lifetime purchase permanently unlocks dual iCloud + Google Drive backup and includes two one-time App Store discount invitations.",
    "Asympta is a local-first handwriting canvas. All creative tools and iCloud backup are free. A one-time Lifetime purchase unlocks Google Drive backup, iCloud + Google Drive cross-provider merge/recovery, and two one-time App Store discount invitations.",
)
replace_one(
    "index.html",
    "Asympta 是一張以本機儲存為先的手寫畫布。所有創作功能免費；Lifetime 一次購買會永久解鎖 iCloud + Google Drive 雙重備份，並提供兩個一次性 App Store 折扣邀請。",
    "Asympta 是一張以本機儲存為先的手寫畫布。所有創作功能與 iCloud 備份免費；Lifetime 一次購買會解鎖 Google Drive 備份、iCloud + Google 雙端合併／故障復原，以及兩個一次性 App Store 折扣邀請。",
)
replace_one("index.html", "<h2>Lifetime dual backup</h2>", "<h2>iCloud backup &amp; Lifetime</h2>")
replace_one(
    "index.html",
    "Handwriting, text, worlds, wind sound, haptics, lighting, and all other creative tools are free and remain local when Lifetime is not purchased. In Hong Kong, Lifetime is a one-time HK$188 purchase that permanently unlocks iCloud + Google Drive dual backup. Each backup reads both services, merges the latest content, then writes the same archive back to both. Purchasers can also share two one-time App Store discount invitations, shown in the app as 10% and 20%; the App Store displays the actual local price and eligibility when redeemed. Before deleting the app, confirm that both services show a completed backup.",
    "Handwriting, text, worlds, wind sound, haptics, lighting, and all other creative tools are free. iCloud backup is also free when iCloud is available on the device. In Hong Kong, Lifetime is a one-time HK$188 purchase that unlocks Google Drive backup, iCloud + Google Drive cross-provider merge/recovery, and two one-time App Store discount invitations. When Lifetime and both providers are active, Asympta reads both services, merges the latest content, then writes the same archive back to both. The invitations are shown as 10% and 20%; the App Store displays the actual local price and eligibility when redeemed. Before deleting the app, confirm that the backup services you use show a completed backup.",
)
replace_one("index.html", "<h2>雙重備份永久解鎖</h2>", "<h2>免費 iCloud 備份與 Lifetime</h2>")
replace_one(
    "index.html",
    "筆跡、文字、世界、風聲、觸感、光照及其他創作功能全部免費，未購買時只作本機保存。在香港，Lifetime 一次性價格為 HK$188，會永久解鎖 iCloud + Google Drive 雙重備份：每次先讀取兩邊及合併最新內容，再把同一份封存檔寫回兩個服務。購買者另可分享兩個一次性 App Store 折扣邀請，介面標示 10% 及 20% 折扣；兌換時由 App Store 顯示適用地區的實際當地價格及資格。刪除 App 前請先確認兩邊都顯示已備份。",
    "筆跡、文字、世界、風聲、觸感、光照及其他創作功能全部免費；裝置可使用 iCloud 時，iCloud 備份亦免費。在香港，Lifetime 一次性價格為 HK$188，會解鎖 Google Drive 備份、iCloud + Google Drive 雙端合併／故障復原，以及兩個一次性 App Store 折扣邀請。Lifetime 已啟用且兩個 provider 都可用時，Asympta 會先讀取兩邊、合併最新內容，再把同一份封存檔寫回兩個服務。邀請介面標示 10% 及 20% 折扣；兌換時由 App Store 顯示適用地區的實際當地價格及資格。刪除 App 前請先確認你正在使用的備份服務顯示已備份。",
)

# Privacy page — match the shipping data flow after free iCloud backup.
replace_one(
    "privacy/index.html",
    "Asympta Privacy Policy: local-first by default, optional iCloud + Google Drive dual backup, and no ads or tracking.",
    "Asympta Privacy Policy: local-first by default, free iCloud backup, optional Lifetime Google Drive backup, and no ads or tracking.",
)
replace_one(
    "privacy/index.html",
    "Asympta is designed around local-first storage and data minimization. All creative features can be used locally for free, without an account or network connection. Apple, Google, or EverFormLab services are used only when you intentionally connect iCloud or Google, enable paid dual backup, claim purchaser discount invitations, or email support.",
    "Asympta is designed around local-first storage and data minimization. All creative features can be used locally for free, without an app account. Apple, Google, or EverFormLab services are used only when you intentionally use iCloud backup, connect Google Drive, enable Lifetime cross-provider backup, claim purchaser discount invitations, or email support.",
)
replace_one(
    "privacy/index.html",
    "Unless you enable the paid dual backup described below, the app does not transmit canvas content off your device.",
    "If you use free iCloud backup, the canvas archive is transmitted to your private CloudKit database through Apple. Google Drive receives canvas archives only when Lifetime is active and you choose to connect Google Drive.",
)
replace_one(
    "privacy/index.html",
    "When Lifetime dual backup is enabled, the canvas archive is stored in the private CloudKit database associated with your Apple Account, with transfer and storage handled by Apple.",
    "When iCloud backup is available and used, the canvas archive is stored in the private CloudKit database associated with your Apple Account, with transfer and storage handled by Apple. iCloud backup is free and is not part of the paid Lifetime entitlement.",
)
replace_one(
    "privacy/index.html",
    "Lifetime unlocks and offer redemptions are processed by Apple StoreKit and the App Store. EverFormLab does not receive credit-card details or complete payment information.",
    "Lifetime unlocks Google Drive backup, cross-provider merge/recovery, and purchaser invitations. Purchases and offer redemptions are processed by Apple StoreKit and the App Store. EverFormLab does not receive credit-card details or complete payment information.",
)
replace_one(
    "privacy/index.html",
    "Asympta starts Google's authorization flow only when you choose to connect Google. The app requests only access to the hidden Google Drive App Data folder (<code>drive.appdata</code>); it does not request your name, email address, general Drive files, or contacts. When Lifetime dual backup is enabled, the canvas archive is stored both in that hidden folder and in your private CloudKit database, subject to Google's and Apple's terms and privacy policies.",
    "Asympta starts Google's authorization flow only when you choose to connect Google. The app requests only access to the hidden Google Drive App Data folder (<code>drive.appdata</code>); it does not request your name, email address, general Drive files, or contacts. When Lifetime is active, Google Drive can participate in backup and cross-provider reconciliation. If iCloud is also available, the converged archive may be stored both in the hidden Google Drive folder and in your private CloudKit database, subject to Google's and Apple's terms and privacy policies.",
)
replace_one(
    "privacy/index.html",
    "Asympta 以本機優先及資料最少化為設計原則。所有創作功能均可免費在本機使用，毋須帳戶或網絡；只有使用者主動連接 iCloud／Google、啟用付費雙重備份、領取購買者折扣邀請或電郵支援時，才會使用相應的 Apple、Google 或 EverFormLab 服務。",
    "Asympta 以本機優先及資料最少化為設計原則。所有創作功能均可免費在本機使用，毋須 App 帳戶；只有使用者主動使用 iCloud 備份、連接 Google Drive、啟用 Lifetime 雙端備份、領取購買者折扣邀請或電郵支援時，才會使用相應的 Apple、Google 或 EverFormLab 服務。",
)
replace_one(
    "privacy/index.html",
    "除非使用者自行啟用下述付費雙重備份，App 不會把畫布內容傳離裝置。",
    "如使用免費 iCloud 備份，畫布封存檔會經 Apple 傳送至使用者的私人 CloudKit 資料庫；只有 Lifetime 已啟用且使用者主動連接 Google Drive 時，Google Drive 才會收到畫布封存檔。",
)
replace_one(
    "privacy/index.html",
    "啟用 Lifetime 雙重備份時，畫布封存檔會存入使用者 Apple Account 對應的私人 CloudKit 資料庫，並由 Apple 處理傳輸及儲存。",
    "裝置可使用並啟用 iCloud 備份時，畫布封存檔會存入使用者 Apple Account 對應的私人 CloudKit 資料庫，並由 Apple 處理傳輸及儲存。iCloud 備份免費，並不屬於付費 Lifetime entitlement。",
)
replace_one(
    "privacy/index.html",
    "永久解鎖及優惠兌換由 Apple StoreKit 與 App Store 處理。EverFormLab 不會收到信用卡或完整付款資料。",
    "Lifetime 解鎖 Google Drive 備份、雙端合併／故障復原及購買者邀請；購買及優惠兌換由 Apple StoreKit 與 App Store 處理。EverFormLab 不會收到信用卡或完整付款資料。",
)
replace_one(
    "privacy/index.html",
    "只有使用者選擇連接 Google 時，Asympta 才會開啟 Google 的授權流程。App 只要求 Google Drive 隱藏 App 資料夾（<code>drive.appdata</code>）權限，不要求姓名、電郵、一般 Drive 檔案或聯絡人。啟用 Lifetime 雙重備份時，畫布封存檔會同時存入該隱藏資料夾及使用者的私人 CloudKit 資料庫，並按 Google 及 Apple 的條款與私隱政策處理。",
    "只有使用者選擇連接 Google 時，Asympta 才會開啟 Google 的授權流程。App 只要求 Google Drive 隱藏 App 資料夾（<code>drive.appdata</code>）權限，不要求姓名、電郵、一般 Drive 檔案或聯絡人。Lifetime 已啟用時，Google Drive 可加入備份與雙端合併；如 iCloud 同時可用，合併後的封存檔可同時存入該隱藏資料夾及使用者的私人 CloudKit 資料庫，並按 Google 及 Apple 的條款與私隱政策處理。",
)

for rel in ["Tools/apply_free_icloud_copy.py", ".github/workflows/apply-free-icloud-support.yml"]:
    path = root / rel
    if path.exists():
        path.unlink()

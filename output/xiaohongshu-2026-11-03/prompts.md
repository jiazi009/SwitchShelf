# SwitchShelf 宣传图生成提示词

使用内置 image_gen（非 CLI）。原始截图与图标作为参考；开源信息追加到封面和最后一页。最终 PNG 为 1086 × 1448，3:4。

## 01-cover

参考：Docs/Screenshots/01-library-grid.jpg、Assets/AppIcon.png

```text
Use case: ads-marketing.
Asset type: finished Xiaohongshu carousel poster, portrait 3:4, aim for 1440x1920 or higher. Chinese design audience, independent native Mac software.
Create a beautiful publication-ready graphic, precise simplified Chinese typography, premium editorial layout with large crisp near-black type, ample negative space, warm off-white and very pale lavender background, subtle cobalt accents, delicate translucent glass details and soft shadows. Refined Apple-like visual language, quietly playful. Flat straight-on graphic, no photography, no laptop or phone mockup, no hand, no desk.
Input image 1 is the ACTUAL application screenshot: insert it faithfully as product evidence. Maintain its real UI, text, artwork, controls, counts, and disconnected state. Do not redesign, redraw, invent or add UI elements or turn disabled controls active. Use the screenshot as a single raster object. Image 2 is the actual app icon; preserve its design. Screenshots may be deliberately cropped as specified but retain correct proportions.
Uniform carousel system: small icon + SwitchShelf brand at top left, small page number at top right, large left aligned headline in upper third, screenshot-led visual in middle/lower portion, calm bottom margin. Keep all important text at least 90px from edges. Chinese fonts should be elegant modern sans serif, very legible on mobile. Use the EXACT copy below with no extra copy.
Page 01 / 04.
Composition: confident opening cover. Huge headline over two lines; the first line near-black, a subtle cobalt underline below the second line. Under headline a short subtitle. In the center an oversized full true app screenshot spanning 90% width, shown level, rounded corners, soft floating shadow. Below the screenshot a compact elegant trio of typographic benefit labels, not a grid of cards.
Text (verbatim, hierarchy as stated):
Top brand: "SwitchShelf"
Top right: "01 / 04"
Main headline line 1: "给 Mac 做了个"
Main headline line 2: "好看的游戏库"
Subtitle: "把 Switch 游戏，收进一个漂亮窗口。"
Bottom benefit labels: "SwiftUI 原生"   "轻巧方便"   "清爽好看"
Footer small: "macOS 26+ · Apple Silicon"
Constraints: screenshot must remain real. No additional claims, Apple logo, Nintendo logo, download link, QR code, watermark, fake install success, or fake review.
```

## 02-native

参考：Docs/Screenshots/03-game-details.jpg、Assets/AppIcon.png

```text
Use case: ads-marketing.
Asset type: finished Xiaohongshu carousel poster, portrait 3:4, aim for 1440x1920 or higher. Chinese design audience, independent native Mac software.
Create a beautiful publication-ready graphic, precise simplified Chinese typography, premium editorial layout with large crisp near-black type, ample negative space, warm off-white and very pale lavender background, subtle cobalt accents, delicate translucent glass details and soft shadows. Refined Apple-like visual language, quietly playful. Flat straight-on graphic, no photography, no laptop or phone mockup, no hand, no desk.
Input image 1 is the ACTUAL application screenshot: insert it faithfully as product evidence. Maintain its real UI, text, artwork, controls, counts, and disconnected state. Do not redesign, redraw, invent or add UI elements or turn disabled controls active. Use the screenshot as a single raster object. Image 2 is the actual app icon; preserve its design. Screenshots may be deliberately cropped as specified but retain correct proportions.
Uniform carousel system: small icon + SwitchShelf brand at top left, small page number at top right, large left aligned headline in upper third, screenshot-led visual in middle/lower portion, calm bottom margin. Keep all important text at least 90px from edges. Chinese fonts should be elegant modern sans serif, very legible on mobile. Use the EXACT copy below with no extra copy.
Page 02 / 04.
Composition: same carousel style, very typographic, subtle lavender. Large headline. The main visual is a large carefully cropped close-up of the ACTUAL screenshot focusing on its left navigation/sidebar and the floating game details panel, retaining enough of the cover grid to understand it. This screenshot sits on a pale lavender panel with soft shadow. It should occupy at least half the poster height. Two concise text labels below, with elegant simple rules instead of cards. The actual screenshot must not be redesigned.
Text (verbatim):
Top brand: "SwitchShelf"
Top right: "02 / 04"
Main headline line 1: "原生开发"
Main headline line 2: "就很 Mac"
Subtitle: "用 SwiftUI，认真做好每一个窗口。"
Bottom labels: "通透侧栏 · 清爽布局"
Second bottom label: "封面网格 · 独立详情"
Footer small: "真实应用界面"
Constraints: only show provided actual screenshot; do not invent dark mode screenshot, graphics, UI states or capabilities. No extra text, watermark, download link or QR code.
```

## 03-lightweight

参考：Docs/Screenshots/01-library-grid.jpg、Assets/AppIcon.png

```text
Use case: ads-marketing.
Asset type: finished Xiaohongshu carousel poster, portrait 3:4, aim for 1440x1920 or higher. Chinese design audience, independent native Mac software.
Create a beautiful publication-ready graphic, precise simplified Chinese typography, premium editorial layout with large crisp near-black type, ample negative space, warm off-white and very pale lavender background, subtle cobalt accents, delicate translucent glass details and soft shadows. Refined Apple-like visual language, quietly playful. Flat straight-on graphic, no photography, no laptop or phone mockup, no hand, no desk.
Input image 1 is the ACTUAL application screenshot: insert it faithfully as product evidence. Maintain its real UI, text, artwork, controls, counts, and disconnected state. Do not redesign, redraw, invent or add UI elements or turn disabled controls active. Use the screenshot as a single raster object. Image 2 is the actual app icon; preserve its design. Screenshots may be deliberately cropped as specified but retain correct proportions.
Uniform carousel system: small icon + SwitchShelf brand at top left, small page number at top right, large left aligned headline in upper third, screenshot-led visual in middle/lower portion, calm bottom margin. Keep all important text at least 90px from edges. Chinese fonts should be elegant modern sans serif, very legible on mobile. Use the EXACT copy below with no extra copy.
Page 03 / 04.
Composition: premium typographic poster focused on small size. A huge tasteful "14 MB" in a modern sans serif occupying upper-middle of poster, small "约" preceding it. The real app icon floats near the right side of the number, glass-like lighting but its front face is the supplied icon, not a redesigned icon. A smaller true full screenshot sits below the main statistic, rounded corners, no perspective, preserving all UI. Clear main headline and short subtitle. Very simple airy layout, no infographic clutter.
Text (verbatim):
Top brand: "SwitchShelf"
Top right: "03 / 04"
Main headline: "轻巧，也顺手"
Large number: "约 14 MB"
Subtitle: "一个小工具，装下游戏库的日常。"
Bottom text: "浏览 · 搜索 · 筛选 · 整理"
Footnote small but readable: "当前本地 0.3.6 构建的 .app 体积，随版本变化。"
Footer small: "macOS 26+ · Apple Silicon"
Constraints: size refers ONLY to this measured local .app bundle. Never add RAM, zero CPU, battery or speed claims. No installer/download-size claim. No extra copy, watermark, download link or QR code.
```

## 04-workflow

参考：Docs/Screenshots/04-installation-staging.jpg、Assets/AppIcon.png

```text
Use case: ads-marketing.
Asset type: finished Xiaohongshu carousel poster, portrait 3:4, aim for 1440x1920 or higher. Chinese design audience, independent native Mac software.
Create a beautiful publication-ready graphic, precise simplified Chinese typography, premium editorial layout with large crisp near-black type, ample negative space, warm off-white and very pale lavender background, subtle cobalt accents, delicate translucent glass details and soft shadows. Refined Apple-like visual language, quietly playful. Flat straight-on graphic, no photography, no laptop or phone mockup, no hand, no desk.
Input image 1 is the ACTUAL application screenshot: insert it faithfully as product evidence. Maintain its real UI, text, artwork, controls, counts, and disconnected state. Do not redesign, redraw, invent or add UI elements or turn disabled controls active. Use the screenshot as a single raster object. Image 2 is the actual app icon; preserve its design. Screenshots may be deliberately cropped as specified but retain correct proportions.
Uniform carousel system: small icon + SwitchShelf brand at top left, small page number at top right, large left aligned headline in upper third, screenshot-led visual in middle/lower portion, calm bottom margin. Keep all important text at least 90px from edges. Chinese fonts should be elegant modern sans serif, very legible on mobile. Use the EXACT copy below with no extra copy.
Page 04 / 04.
Composition: same premium carousel style. Upper-third big headline over two lines, subtitle beneath. Main visual uses the ACTUAL screenshot: show full list-view screenshot level and large, then below it show a clearly connected magnified crop of the right-hand staging panel from this SAME screenshot. Keep the staging panel and checkboxes EXACTLY as in source. The original disabled start-install control remains disabled. The crop should have a small cobalt rule linking it visually to the overview. Lower area includes a succinct inline three-step sequence, plus a warm engagement question. No dense cards.
Text (verbatim):
Top brand: "SwitchShelf"
Top right: "04 / 04"
Main headline line 1: "从找到游戏"
Main headline line 2: "到选好内容"
Subtitle: "本体、更新、DLC，按需选择。"
Steps, in order: "浏览游戏库"   "搜索与筛选"   "加入待选区"
Bottom question: "这样的 Mac 小工具，你想试试吗？"
Footer small: "截图为设备未连接状态，安装需连接并确认。"
Constraints: exact screenshot, no fabricated device connection, installation progress, installed badge or successful install. No extra text, download link, QR code or watermark.
```

## 封面开源信息定向修改

```text
Use case: text-localization.
Edit target: supplied finished SwitchShelf Xiaohongshu carousel page 01 cover. Keep the poster's 3:4 portrait aspect ratio, all original pixels of screenshot, header, brand icon, page number, main headline, subtitle, color palette, background, layout, margins, screenshot size, footer and all other elements unchanged.
Change ONLY the three benefit labels at bottom, preserving the three-column layout and large bold typography:
Left exact text: "SwiftUI 原生", keep the code icon.
Middle exact text: "代码开源", replace its lightning icon with a simple matching cobalt open code bracket glyph.
Right exact text: "轻巧方便", replace its sparkle icon with a simple matching cobalt feather/leaf glyph.
Everything else remains the same. Main headline must remain exactly "给 Mac 做了个" / "好看的游戏库". The screenshot is a protected image; preserve it faithfully, especially the disabled install button and disconnected device state. Do not add or remove any UI, embellishment, QR code, download claim, license badge or text. These labels are the key campaign message: native, open source, lightweight.
```

## 流程图开源信息定向修改

```text
Use case: text-localization / precise poster edit.
Edit target: the supplied completed Xiaohongshu portrait 3:4 SwitchShelf carousel poster page 04. Keep the entire composition, all screenshot pixels, icon, title, subtitle, page number, colors, strokes, step graphics, typography style and scale unchanged.
Change ONLY the bottom engagement question area "这样的 Mac 小工具，你想试试吗？" into an elegant two-line open-source call to action, using the same large black sans serif style but adjusted to fit cleanly without colliding with the staging crop:
Line 1 exact: "已在 GitHub 开源"
Line 2 exact, slightly smaller: "搜索 jiazi009/SwitchShelf"
Keep the bottom small disconnected-device footnote exactly unchanged. Keep the screenshot controls disabled and all interface states unchanged. Do not add stars/counts, GitHub logo, QR code, license badges, download claims, decorations or any other text. Preserve portrait 3:4 and high resolution. This is a surgical text replacement only; every other region must remain identical.
```

# Page notes for KOReader (Aka stickers)

I wanted to add stickers on my books. Little doodles in the margin, a sticker next to a line that made me laugh, a "no. absolutely not." under a bad decision, or just funny doodles. Kindles don't let you do that, so I made this.

It's a KOReader plugin that lets you put text notes and stickers anywhere on the page. The clever bit: they stick to the words, not the page. Change your font size and the notes move with the text instead of ending up in the middle of some random sentence.

I built it on a Kindle Paperwhite 6 (12th gen) with the Vera jailbreak. It should work on anything running KOReader, but that's the only device I've tried. 

As a disclaimer, I'm not a developer, im actually a game designer, so I made this with claude fable \+ lots of bug testing and adjusting. The stickers also are majority not mine (i think i made like 10 of them total, hand drawn expressions), i just edited and cleaned them up for the plugin , but are mostly from popular whatsapp stuff. So be patient with any issues you may find , just let me know and ill fix them as soon as i can 🙂  
(if your a dev and would like to work with this on me please let me know\!) 

Version 1.0, September 2026\.

---

## Included Stickers

\!\[Full sticker sheet\](Stickers-FULL.png)

## Installing it

1. Download the zip and unzip it. You'll get a folder called `pagenotes.koplugin`.  
2. Drop that folder into `koreader/plugins/` on your device. I use LocalSend, USB works too.  
3. Restart KOReader.

Sticker packs can go in either of these folders:

\`\`\`  
koreader/plugins/pagenotes.koplugin/packs  
\`\`\`

or

\`\`\`  
koreader/pagenotes/packs  
\`\`\`

Two locations to add the packs. Each folder becomes its own category/folder in the sticker popup  
---

## Opening it

There are three ways in. Pick whichever you like.

**The easy one: highlight a few words.** Hold a couples word or a sentence like you normally would. In the popup, tap **Note / sticker**. The note lands right under the words you picked.

One catch: KOReader skips the highlight menu when you hold a *single* word and goes straight to the dictionary. If you want the menu for single words too, go to the gear icon (Settings) → **Taps and gestures** → **Long-press on text** and pick the option that isn't dictionary. I did this and never looked back.

**Bind it to a gesture.** Gear icon → **Taps and gestures** → **Gesture manager** → pick a gesture → **General** → **Page notes: add note or sticker**.

You get three actions to play with:

- **Page notes: add note or sticker** opens the popup  
- **Page notes: edit notes** jumps into edit mode  
- **Page notes: show / hide notes** hides everything so you can read clean, tap again to bring it all back

**Or go through the menu.** Top menu → wrench icon → **More tools** → **Page notes**.

Add note or sticker option is my preferred, as you can edit within that popup also.  
---

## The popup

This is where you add/edit things.

- **Text note** lets you type something, then tap **Place**.  
- **Edit notes** goes into edit mode without adding anything new.  
- **Close** closes it. Tapping anywhere outside the box does the same.  
- **◀ pack name ▶** flips between your sticker packs.  
- If a pack has more than 18 stickers, a **◀ 1 / 3 ▶** row shows up under the grid.  
- Tap a sticker to place it.  
- If the box is in your way, press and drag it somewhere else.

The moment you place something, you're in edit mode with it selected.

---

## Edit mode

This is where you fiddle with things. A toolbar shows up at the bottom of the screen. If the popup is covering the spot you need, press on its edge and drag it anywhere (like koreader standard popups)

- **Tap** a note to select it. You'll see a black frame around it.  
- **Drag** a note to move it. Tiny stickers have a bigger invisible grab area so you don't have to be precise.

Here's what the buttons do:

**Top row**

- **Add** opens the popup again. The new note lands just under whatever you have selected, so you can build up little clusters.  
- **Done** takes you back to reading.  
- **Delete** removes the selected note. It asks first.

**Text row** (these only do something on text notes)

- **Text** changes the words.  
- **Font** lets you pick any font installed on your device.  
- **Align** is left, middle, or right.  
- **Box** turns the white box behind the text on or off.

**Size row**

- **↺ ↻** turns the note 15° at a time.  
- **Smaller / Bigger** changes text size on a text note, or sticker size on a sticker.  
- **Narrower / Wider** changes how wide a text box is. The text wraps and the height sorts itself out.

**Arrow row**

- **← ↑ ↓ →** nudges the selected note 4 pixels at a time. E-ink dragging is a bit jumpy, so I use these for the last little bit to nudge it into the perfect spot. 


Once you tap Done, notes are just drawn on the page. Tapping and holding go to the book like normal, so you won't accidentally move a sticker while reading. If you need to edit a sticker you have to go back into edit mode (this is to prevent the stickers from moving while reading and interacting like normal)

---

## Adding your own stickers

This is the fun part. Make a folder for each pack here:

\# koreader/pagenotes/packs/your pack name/   
Or   
\# koreader/plugins/pagenotes/packs/your pack name/ 

Drop PNG, JPG, or SVG files in it. One folder is one pack, and the folder name is what shows up in the popup.

A few things I learned about stickers on e-ink:

- Use PNGs with a see-through background.  
- 256 to 512 pixels wide is plenty. Bigger just takes longer to draw.Most of the time mine are sized down to under 50x50 px so less is more  
- Black lines and flat greys look great. Soft shading and gradients turn into speckles.

To help with that, the plugin cleans every sticker before drawing it. How solid each pixel is gets snapped to full, half, or a third, and anything fainter than that is dropped. That's why faint background noise you can't even see in Photoshop won't show up on your Kindle. Then the grey value snaps to black, one of three greys, or white. If you want different cut-offs, they're in the `STICKER_ALPHA` and `STICKER_TONES` tables near the top of `main.lua`.

To turn a pack on or off: **Page notes** menu → **Sticker packs** → tick or untick.

The plugin comes with a `basic` pack of placeholder shapes. That one lives inside the plugin folder and gets replaced when you update,

 `Sticker packs can go in either of these folders:`

```` ``` ````  
`koreader/plugins/pagenotes.koplugin/packs`  
```` ``` ````

`or`

```` ``` ````  
`koreader/pagenotes/packs`  
```` ``` ````

Also includes my own sticker pack under **Emojis**  
---

## Defaults for new text notes

**Page notes** menu → **New text notes**. Set the font, size, alignment, and whether the white box starts on. Every new text note uses these. You can still change each note on its own afterwards. You can change the font of each one as well.   
**Narrower** and **Wider** are for the text box itself, smaller and bigger are for the size

---

## Where everything lives

- **Your placed notes and stickers** are saved in the book's own `.sdr` folder, in `metadata.lua`, right next to your highlights. Anything that backs up your highlights backs up your notes too. The Calibre "KOReader Sync" plugin can keep a copy of that file.  
- **Your sticker packs** are in `koreader/pagenotes/packs/`.  
- **Plugin settings** (the text defaults and which packs are off) are in `koreader/settings/pagenotes.lua`.

If you ever want a clean slate for one book: **Page notes** menu → **Delete all notes in this book**.

---

## How the sticking works (if you're curious)

In EPUBs, every note is tied to a word using the same system KOReader uses for highlights. The gap between that word and the note is saved in line-heights, not pixels. So when the font gets bigger, the word moves, the gap grows with it, and the note stays next to the same spot. If a font change would shove a note off the edge of the screen, it gets pulled back in.

PDFs don't reflow, so there the note just remembers the page number and where it is on that page.

---

## Issues

- Two-page landscape mode: notes on the second page might not show.  
- Big stickers at odd angles take a second to draw. Straight angles (0°, 90°, 180°, 270°) are instant.  
- Dragging on e-ink jumps rather than glides. Use the arrows to finish.  
- No favorites or categories yet. They're on my list.  
- Ive only tested on a kindle PW 6, and because of that, only greyscale. I expect there may be issues on other devices, if there are please let me know ill do my best to fix them.

---

## What's in the folder

- `_meta.lua` is the plugin name and description  
- `main.lua` is all the code  
- `packs/basic/` is the 12 placeholder stickers  
- `packs/Emoji/` is my own 80+ stickers, a mix of Hand drawn expressions, Emojis, Quby, and two meme stickers   
- `README.md` is this  
- `LICENSE` is MIT, do what you like with it


# 📲 TagDrop

Send a `.bin` file from your Mac to an Android phone over **Bluetooth** or a **USB cable**, and the phone writes it straight to an NFC tag.

```bash
bananapeel install blockblock2/tagdrop
bananapeel run tagdrop
```

1. Drag your `.bin` file into the window. TagDrop shows a code like `ABC123`.
2. On the phone, open **https://tagdrop-5kv.pages.dev** in Chrome and type the code.
3. Tap **Bluetooth** (or **USB cable**), then hold an NFC tag to the back of the phone.

## What you need

- **Mac** with Swift (comes with Xcode Command Line Tools: `xcode-select --install`). The first time, macOS asks to let Terminal use Bluetooth. Click Allow.
- **Android phone:** Chrome, with NFC on. Writes the tag right on the page.
- **iPhone:** open the page in **Bluefy** (free App Store browser with Bluetooth). Apple doesn't let websites write NFC, so you save the file and finish in **NFC Tools** → *Write Dump (.bin)*.
- **amiibo:** TagDrop spots amiibo files and hands them to **TagMo** (Android) or **Tagmiibo** (iPhone), which re-encrypt them for your blank NTAG215.
- **Cable mode only:** `brew install android-platform-tools`, and USB debugging turned on in the phone's Developer options. TagDrop runs `adb reverse` for you, so the phone reaches the Mac through the cable.

## How it works

- **Code:** the 6-letter code is built into the Bluetooth service ID, so the phone only sees *your* computer.
- **Bluetooth:** the Mac acts as a Bluetooth LE device; the page pulls the file in 512-byte pieces.
- **Cable:** a tiny server on the Mac (localhost only, needs the code) is tunnelled to the phone over USB.
- **NFC:** the page writes the file as one NDEF record (`application/octet-stream`) with Web NFC.

Tag dumps (NTAG/Ultralight `.bin`): on Android, TagDrop reads what was stored on the old tag and writes that to the new one. The new tag keeps its own serial number.

Limits: files up to 64 KB (tags are much smaller: NTAG213 ≈ 137 B, NTAG215 ≈ 496 B, NTAG216 ≈ 868 B). Other `.bin` files are written as one data record.

## The website

The phone page is `site/index.html`, on Cloudflare Pages at https://tagdrop-5kv.pages.dev:

```bash
git clone https://github.com/blockblock2/tagdrop ~/sites/tagdrop && cd ~/sites/tagdrop && wrangler pages deploy site --project-name tagdrop
```

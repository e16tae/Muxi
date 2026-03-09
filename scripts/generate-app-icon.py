#!/usr/bin/env python3
"""
Muxi App Icon Generator
Single-pane terminal with "> _" prompt and lavender status bar.
"""

from PIL import Image, ImageDraw, ImageFont
import os

# === Design Tokens ===
COLORS = {
    "background": (18, 14, 24),       # #120E18 — deep purple-black
    "pane": (36, 30, 44),             # #241E2C — terminal pane
    "text": (181, 168, 213),          # #B5A8D5 — lavender (prompt)
    "cursor": (181, 168, 213),        # #B5A8D5 — lavender block cursor
    "status_bar": (181, 168, 213),    # #B5A8D5 — lavender accent
}

# === Icon Dimensions ===
SIZE = 1024

# === Layout Constants ===
STATUS_BAR_HEIGHT = 80            # ~8% of icon
PROMPT_TEXT = "$"                  # Prompt character
CURSOR_WIDTH_RATIO = 0.08         # Bar cursor width relative to font size
CURSOR_GAP_RATIO = 0.15           # Gap between prompt and cursor


def generate_icon(size=SIZE):
    """Generate the Muxi app icon at the given size.

    Outputs an opaque RGB square — iOS applies its own superellipse mask.
    No alpha channel (App Store rejects icons with transparency).
    """
    img = Image.new("RGB", (size, size), COLORS["background"])
    draw = ImageDraw.Draw(img)

    # --- Terminal pane (full area) ---
    draw.rectangle([(0, 0), (size, size)], fill=COLORS["pane"])

    # --- Terminal text: "> █" ---
    # Use monospace system font, fall back to default
    font_size = int(size * 0.28)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", font_size)
    except (OSError, IOError):
        try:
            font = ImageFont.truetype("/System/Library/Fonts/SFMono-Regular.otf", font_size)
        except (OSError, IOError):
            font = ImageFont.load_default()

    # Measure prompt ">"
    prompt_bbox = draw.textbbox((0, 0), PROMPT_TEXT, font=font)
    prompt_w = prompt_bbox[2] - prompt_bbox[0]
    prompt_h = prompt_bbox[3] - prompt_bbox[1]

    # Center vertically in the pane area, offset left for terminal feel
    text_x = int(size * 0.18)
    text_y = int((size - prompt_h) / 2) - prompt_bbox[1] - int(size * 0.12)

    # Draw prompt ">"
    draw.text((text_x, text_y), PROMPT_TEXT, fill=COLORS["text"], font=font)


    return img


def generate_all_sizes(output_dir):
    """Generate icons for all required iOS sizes."""
    sizes = {
        "icon-1024.png": 1024,
        "icon-180.png": 180,
        "icon-120.png": 120,
        "icon-167.png": 167,
        "icon-152.png": 152,
        "icon-87.png": 87,
        "icon-80.png": 80,
        "icon-60.png": 60,
        "icon-40.png": 40,
        "icon-29.png": 29,
        "icon-20.png": 20,
    }

    os.makedirs(output_dir, exist_ok=True)

    master = generate_icon(1024)

    for filename, size in sizes.items():
        if size == 1024:
            icon = master
        else:
            icon = master.resize((size, size), Image.LANCZOS)

        filepath = os.path.join(output_dir, filename)
        icon.save(filepath, "PNG")
        print(f"  {filename} ({size}x{size})")

    print(f"\nAll icons saved to: {output_dir}")
    return master


if __name__ == "__main__":
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    xcassets_dir = os.path.join(
        project_root,
        "ios", "Muxi", "Resources", "Assets.xcassets", "AppIcon.appiconset"
    )
    loose_dir = os.path.join(
        project_root,
        "ios", "Muxi", "Resources", "AppIcon"
    )

    print("Generating Muxi app icons...\n")
    master = generate_all_sizes(loose_dir)

    os.makedirs(xcassets_dir, exist_ok=True)
    xcassets_path = os.path.join(xcassets_dir, "icon-1024.png")
    master.save(xcassets_path, "PNG")
    print(f"\n  Copied to xcassets: {xcassets_path}")

    preview_size = 1200
    preview = Image.new("RGB", (preview_size, preview_size), COLORS["background"])
    offset = (preview_size - 1024) // 2
    preview.paste(master, (offset, offset))
    preview_path = os.path.join(loose_dir, "preview.png")
    preview.save(preview_path, "PNG")
    print(f"  preview.png ({preview_size}x{preview_size} with padding)")

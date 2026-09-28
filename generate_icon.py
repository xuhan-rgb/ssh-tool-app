#!/usr/bin/env python3
"""Generate SSH terminal app icon — bold, high-contrast, visible at small sizes."""

import os
import math
from PIL import Image, ImageDraw, ImageFont


def create_icon(size=1024):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    margin = int(size * 0.02)
    radius = int(size * 0.22)

    # === Vibrant gradient-like background (deep blue → teal) ===
    # Simulate gradient with horizontal bands
    for y in range(margin, size - margin):
        t = (y - margin) / (size - 2 * margin)
        r = int(15 + t * 10)
        g = int(80 + t * 50)
        b = int(180 - t * 40)
        draw.line([(margin, y), (size - margin, y)], fill=(r, g, b))

    # Apply rounded corners by masking
    mask = Image.new('L', (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        [margin, margin, size - margin, size - margin],
        radius=radius, fill=255,
    )
    img.putalpha(mask)

    # Redraw on fresh canvas with mask applied
    final = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    final.paste(img, mask=mask)
    img = final
    draw = ImageDraw.Draw(img)

    # === Large ">" prompt symbol — the hero element ===
    bold_font_size = int(size * 0.42)
    bold_font = None
    for fp in [
        '/System/Library/Fonts/SFMono-Bold.otf',
        '/System/Library/Fonts/Menlo.ttc',
        '/System/Library/Fonts/Monaco.dfont',
        '/System/Library/Fonts/Courier.dfont',
    ]:
        if os.path.exists(fp):
            try:
                bold_font = ImageFont.truetype(fp, bold_font_size)
                break
            except Exception:
                continue
    if bold_font is None:
        bold_font = ImageFont.load_default()

    # Draw ">" with slight shadow for depth
    prompt_x = int(size * 0.13)
    prompt_y = int(size * 0.12)
    # Shadow
    draw.text((prompt_x + 4, prompt_y + 4), ">_", fill=(0, 0, 0, 100), font=bold_font)
    # Main text — bright white/green
    draw.text((prompt_x, prompt_y), ">", fill=(255, 255, 255), font=bold_font)
    caret_x = prompt_x + draw.textlength(">", font=bold_font)
    draw.text((caret_x, prompt_y), "_", fill=(80, 255, 160), font=bold_font)

    # === "SSH" text below — large and bold ===
    ssh_font_size = int(size * 0.22)
    ssh_font = None
    for fp in [
        '/System/Library/Fonts/SFMono-Bold.otf',
        '/System/Library/Fonts/Menlo.ttc',
    ]:
        if os.path.exists(fp):
            try:
                ssh_font = ImageFont.truetype(fp, ssh_font_size)
                break
            except Exception:
                continue
    if ssh_font is None:
        ssh_font = bold_font

    ssh_text = "SSH"
    ssh_w = draw.textlength(ssh_text, font=ssh_font)
    ssh_x = (size - ssh_w) / 2
    ssh_y = int(size * 0.52)
    # Shadow
    draw.text((ssh_x + 3, ssh_y + 3), ssh_text, fill=(0, 0, 0, 80), font=ssh_font)
    draw.text((ssh_x, ssh_y), ssh_text, fill=(255, 255, 255, 240), font=ssh_font)

    # === Connection arrow: two nodes with a line ===
    arrow_y = int(size * 0.82)
    node_r = int(size * 0.028)
    left_x = int(size * 0.28)
    right_x = int(size * 0.72)
    line_w = max(4, size // 150)

    # Dashed-style line between nodes
    draw.line([(left_x, arrow_y), (right_x, arrow_y)],
              fill=(80, 255, 160, 200), width=line_w)

    # Arrow head
    arrow_sz = int(size * 0.03)
    draw.polygon([
        (right_x, arrow_y),
        (right_x - arrow_sz * 2, arrow_y - arrow_sz),
        (right_x - arrow_sz * 2, arrow_y + arrow_sz),
    ], fill=(80, 255, 160, 200))

    # Left node (local)
    draw.ellipse([left_x - node_r, arrow_y - node_r, left_x + node_r, arrow_y + node_r],
                 fill=(255, 255, 255))

    # Right node (remote) — with glow
    glow_r = int(node_r * 1.8)
    draw.ellipse([right_x - glow_r, arrow_y - glow_r, right_x + glow_r, arrow_y + glow_r],
                 fill=(80, 255, 160, 60))
    draw.ellipse([right_x - node_r, arrow_y - node_r, right_x + node_r, arrow_y + node_r],
                 fill=(80, 255, 160))

    # === Lock symbol (tiny, near SSH text) to hint at security ===
    lock_x = int(ssh_x + ssh_w + size * 0.03)
    lock_y = int(ssh_y + size * 0.06)
    lock_sz = int(size * 0.045)
    # Lock body
    draw.rounded_rectangle(
        [lock_x, lock_y, lock_x + lock_sz, lock_y + int(lock_sz * 0.8)],
        radius=int(lock_sz * 0.15),
        fill=(255, 220, 80),
    )
    # Lock shackle (arc)
    shackle_w = max(2, size // 300)
    draw.arc(
        [lock_x + int(lock_sz * 0.15), lock_y - int(lock_sz * 0.5),
         lock_x + int(lock_sz * 0.85), lock_y + int(lock_sz * 0.1)],
        start=180, end=0,
        fill=(255, 220, 80), width=shackle_w,
    )

    return img


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    icon = create_icon(1024)

    # === macOS ===
    macos_dir = os.path.join(base_dir, 'macos/Runner/Assets.xcassets/AppIcon.appiconset')
    for name, sz in {
        'app_icon_16.png': 16, 'app_icon_32.png': 32, 'app_icon_64.png': 64,
        'app_icon_128.png': 128, 'app_icon_256.png': 256,
        'app_icon_512.png': 512, 'app_icon_1024.png': 1024,
    }.items():
        icon.resize((sz, sz), Image.LANCZOS).save(os.path.join(macos_dir, name), 'PNG')
        print(f'  macOS: {name}')

    # === Android ===
    android_base = os.path.join(base_dir, 'android/app/src/main/res')
    for folder, sz in {
        'mipmap-mdpi': 48, 'mipmap-hdpi': 72, 'mipmap-xhdpi': 96,
        'mipmap-xxhdpi': 144, 'mipmap-xxxhdpi': 192,
    }.items():
        icon.resize((sz, sz), Image.LANCZOS).convert('RGBA').save(
            os.path.join(android_base, folder, 'ic_launcher.png'), 'PNG')
        print(f'  Android: {folder}')

    # === iOS ===
    ios_dir = os.path.join(base_dir, 'ios/Runner/Assets.xcassets/AppIcon.appiconset')
    for name, sz in {
        'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40,
        'Icon-App-20x20@3x.png': 60, 'Icon-App-29x29@1x.png': 29,
        'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80,
        'Icon-App-40x40@3x.png': 120, 'Icon-App-60x60@2x.png': 120,
        'Icon-App-60x60@3x.png': 180, 'Icon-App-76x76@1x.png': 76,
        'Icon-App-76x76@2x.png': 152, 'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
    }.items():
        icon.resize((sz, sz), Image.LANCZOS).save(os.path.join(ios_dir, name), 'PNG')
        print(f'  iOS: {name}')

    preview = os.path.join(base_dir, 'app_icon_preview.png')
    icon.save(preview, 'PNG')
    print(f'\nPreview: {preview}')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3.7
import os
import subprocess
from PIL import Image, ImageDraw, ImageFilter

def draw_rounded_rect(draw, bounds, radius, fill=None, outline=None, width=1):
    x1, y1, x2, y2 = bounds
    r = radius
    d = 2 * r
    # 填充中心与上下左右十字区域
    if fill:
        draw.rectangle([x1 + r, y1, x2 - r, y2], fill=fill)
        draw.rectangle([x1, y1 + r, x2, y2 - r], fill=fill)
        draw.pieslice([x1, y1, x1 + d, y1 + d], 180, 270, fill=fill)
        draw.pieslice([x2 - d, y1, x2, y1 + d], 270, 360, fill=fill)
        draw.pieslice([x1, y2 - d, x1 + d, y2], 90, 180, fill=fill)
        draw.pieslice([x2 - d, y2 - d, x2, y2], 0, 90, fill=fill)
    if outline:
        draw.arc([x1, y1, x1 + d, y1 + d], 180, 270, fill=outline, width=width)
        draw.arc([x2 - d, y1, x2, y1 + d], 270, 360, fill=outline, width=width)
        draw.arc([x1, y2 - d, x1 + d, y2], 90, 180, fill=outline, width=width)
        draw.arc([x2 - d, y2 - d, x2, y2], 0, 90, fill=outline, width=width)
        draw.line([x1 + r, y1, x2 - r, y1], fill=outline, width=width)
        draw.line([x1 + r, y2, x2 - r, y2], fill=outline, width=width)
        draw.line([x1, y1 + r, x1, y2 - r], fill=outline, width=width)
        draw.line([x2, y1 + r, x2, y2 - r], fill=outline, width=width)

def create_master_icon(size=1024):
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))

    # 1. 绘制带有圆角的渐变背景 (深蓝紫到亮青色渐变)
    corner_radius = int(size * 0.22)
    
    bg = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)
    for y in range(size):
        ratio = y / float(size)
        if ratio < 0.6:
            r1 = ratio / 0.6
            r = int(24 + (37 - 24) * r1)
            g = int(24 + (99 - 24) * r1)
            b = int(60 + (235 - 60) * r1)
        else:
            r2 = (ratio - 0.6) / 0.4
            r = int(37 + (6 - 37) * r2)
            g = int(99 + (182 - 99) * r2)
            b = int(235 + (212 - 235) * r2)
        bg_draw.line([(0, y), (size, y)], fill=(r, g, b, 255))

    # 圆角蒙版
    mask = Image.new('L', (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    margin = int(size * 0.04)
    draw_rounded_rect(mask_draw, [margin, margin, size - margin, size - margin], corner_radius, fill=255)

    im.paste(bg, (0, 0), mask)

    # 2. 绘制大屏外框 (Monitor / TV screen)
    draw = ImageDraw.Draw(im)
    tv_left = int(size * 0.18)
    tv_top = int(size * 0.20)
    tv_right = int(size * 0.82)
    tv_bottom = int(size * 0.65)
    tv_radius = int(size * 0.04)
    line_w = int(size * 0.028)

    draw_rounded_rect(draw, [tv_left, tv_top, tv_right, tv_bottom], tv_radius, outline=(255, 255, 255, 240), width=line_w)

    # 屏幕底座支架
    stand_top = tv_bottom
    stand_bottom = int(size * 0.74)
    stand_left = int(size * 0.44)
    stand_right = int(size * 0.56)
    draw.rectangle([stand_left, stand_top, stand_right, stand_bottom], fill=(255, 255, 255, 230))
    
    base_left = int(size * 0.36)
    base_right = int(size * 0.64)
    base_h = int(size * 0.026)
    draw_rounded_rect(draw, [base_left, stand_bottom, base_right, stand_bottom + base_h], int(base_h/2), fill=(255, 255, 255, 230))

    # 3. 绘制投屏传播无线声波 (Wireless Casting Waves)
    wave_center_x = int(size * 0.35)
    wave_center_y = int(size * 0.42)
    for i, r_step in enumerate([int(size * 0.08), int(size * 0.14), int(size * 0.20)]):
        alpha = int(255 - i * 40)
        bbox = [wave_center_x - r_step, wave_center_y - r_step, wave_center_x + r_step, wave_center_y + r_step]
        draw.arc(bbox, start=-50, end=50, fill=(255, 255, 255, alpha), width=int(size * 0.022))

    # 4. 绘制前置移动手机设备 (Phone screen on foreground)
    p_left = int(size * 0.52)
    p_top = int(size * 0.38)
    p_right = int(size * 0.84)
    p_bottom = int(size * 0.85)
    p_radius = int(size * 0.045)
    
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    s_draw = ImageDraw.Draw(shadow)
    draw_rounded_rect(s_draw, [p_left - 4, p_top + 8, p_right + 4, p_bottom + 12], p_radius, fill=(0, 0, 0, 140))
    shadow = shadow.filter(ImageFilter.GaussianBlur(16))
    im = Image.alpha_composite(im, shadow)

    draw = ImageDraw.Draw(im)
    draw_rounded_rect(draw, [p_left, p_top, p_right, p_bottom], p_radius, fill=(15, 23, 42, 255), outline=(56, 189, 248, 255), width=int(size * 0.022))
    
    # 手机听筒/摄像头
    cam_w = int((p_right - p_left) * 0.28)
    cam_h = int(size * 0.012)
    cam_left = int((p_left + p_right) / 2 - cam_w / 2)
    cam_top = p_top + int(size * 0.02)
    draw_rounded_rect(draw, [cam_left, cam_top, cam_left + cam_w, cam_top + cam_h], int(cam_h/2), fill=(100, 116, 139, 255))

    # 手机内屏
    screen_m = int(size * 0.026)
    scr_l = p_left + screen_m
    scr_t = cam_top + cam_h + int(size * 0.015)
    scr_r = p_right - screen_m
    scr_b = p_bottom - int(size * 0.035)
    draw_rounded_rect(draw, [scr_l, scr_t, scr_r, scr_b], int(p_radius * 0.6), fill=(30, 41, 59, 255))

    # 手机屏幕内的投屏图标 (Cast 标志)
    c_x = int((scr_l + scr_r) / 2)
    c_y = int((scr_t + scr_b) / 2)
    cast_s = int(size * 0.06)
    
    draw.ellipse([c_x - cast_s/3, c_y + cast_s/3, c_x - cast_s/3 + int(size * 0.02), c_y + cast_s/3 + int(size * 0.02)], fill=(56, 189, 248, 255))
    draw.arc([c_x - cast_s, c_y - cast_s/3, c_x + cast_s/3, c_y + cast_s], start=270, end=360, fill=(56, 189, 248, 255), width=int(size*0.015))
    draw.arc([c_x - int(cast_s*1.4), c_y - int(cast_s*0.7), c_x + int(cast_s*0.6), c_y + int(cast_s*1.3)], start=270, end=360, fill=(56, 189, 248, 255), width=int(size*0.015))

    return im

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res_dir = os.path.join(root, "app-desktop", "resources")
    android_res = os.path.join(root, "app-android", "app", "src", "main", "res")
    ios_res = os.path.join(root, "app-ios", "ScreenSender")

    os.makedirs(res_dir, exist_ok=True)
    os.makedirs(ios_res, exist_ok=True)

    print("正在生成 1024x1024 主图标...")
    master = create_master_icon(1024)
    master_png = os.path.join(res_dir, "master_icon.png")
    master.save(master_png, "PNG")

    # 1. 生成 Windows .ico (包含 16, 32, 48, 64, 128, 256)
    print("正在生成 Windows acast.ico ...")
    ico_path = os.path.join(res_dir, "acast.ico")
    master.save(ico_path, format="ICO", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

    # 2. 生成 macOS .icns (使用 macOS iconutil)
    iconset_dir = os.path.join(res_dir, "acast.iconset")
    os.makedirs(iconset_dir, exist_ok=True)
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png")
    ]
    for s, name in sizes:
        resized = master.resize((s, s), Image.LANCZOS)
        resized.save(os.path.join(iconset_dir, name))

    icns_path = os.path.join(res_dir, "acast.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", icns_path], check=True)
    subprocess.run(["rm", "-rf", iconset_dir])
    print("已生成 macOS acast.icns！")

    # 3. 生成 Android 各分辨率 mipmap
    android_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192
    }
    for folder, s in android_sizes.items():
        out_folder = os.path.join(android_res, folder)
        os.makedirs(out_folder, exist_ok=True)
        out_file = os.path.join(out_folder, "ic_launcher.png")
        resized = master.resize((s, s), Image.LANCZOS)
        resized.save(out_file, "PNG")
    print("已生成 Android 多分辨率启动图标！")

    # 4. 生成 iOS 1024x1024 AppIcon
    ios_icon = os.path.join(ios_res, "AppIcon.png")
    master.save(ios_icon, "PNG")
    print("已生成 iOS AppIcon.png！")

if __name__ == "__main__":
    main()
